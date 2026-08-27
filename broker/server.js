// GCE metadata server 相容的 token broker。
//
// 目的：讓 agent 容器裡「沒有」service account 私鑰，但仍然拿得到 Vertex 的
// access token。金鑰只存在這支服務的檔案系統裡；agent 那邊只設
// GCE_METADATA_HOST 指過來。
//
// 為什麼這樣行得通：google-auth-library 的 ADC 鏈裡有一環是「在 GCE 上就去問
// metadata server」，而它認的位址來自 GCE_METADATA_HOST 環境變數
// （gcp-metadata 8.1.2 的 getBaseUrl()）。所以只要回應長得像 metadata server，
// 整條鏈就會走過來——不需要改 pi 一行程式碼。
//
// 爆炸半徑的變化才是重點：agent 仍然拿得到 token（本來就必須拿得到，
// 否則不能工作），但拿不到「永不過期的私鑰」。從長期憑證降成 1 小時的短期票據。

import http from "node:http";
import { GoogleAuth } from "google-auth-library";

const KEY_PATH = process.env.SA_KEY_PATH || "/run/secrets/sa-key.json";
const PORT = Number(process.env.PORT || 8080);
const UNIVERSE = "googleapis.com";

const auth = new GoogleAuth({
  keyFile: KEY_PATH,
  scopes: ["https://www.googleapis.com/auth/cloud-platform"],
});

// 這兩個從金鑰檔本身讀，不要另外用環境變數傳——少一個會不一致的來源。
let clientPromise = null;
function getClient() {
  clientPromise ??= auth.getClient();
  return clientPromise;
}

function send(res, code, body, contentType = "application/text") {
  // ⚠️ 這個 header 是偵測的關鍵。gcp-metadata 收到回應會檢查
  // Metadata-Flavor: Google，不符就丟 RangeError 拒絕使用。
  res.writeHead(code, {
    "Metadata-Flavor": "Google",
    "Content-Type": contentType,
    "Server": "Metadata Server for VM",
  });
  res.end(body);
}

async function handleToken(res) {
  const client = await getClient();
  const { token } = await client.getAccessToken();
  const expiryDate = client.credentials?.expiry_date ?? Date.now() + 3600_000;
  const expiresIn = Math.max(0, Math.floor((expiryDate - Date.now()) / 1000));
  send(
    res,
    200,
    JSON.stringify({ access_token: token, expires_in: expiresIn, token_type: "Bearer" }),
    "application/json",
  );
}

const server = http.createServer(async (req, res) => {
  const path = new URL(req.url, "http://localhost").pathname;

  // 真正的 metadata server 也要求這個 header，用途是擋掉瀏覽器與
  // DNS rebinding 那類跨來源存取。照抄，不要因為「反正在內網」就省略。
  if (req.headers["metadata-flavor"] !== "Google") {
    console.log(`DENY  ${req.method} ${path}  (缺 Metadata-Flavor header)`);
    return send(res, 403, "Metadata-Flavor: Google required");
  }

  // 每一次取 token 都留下紀錄。這份 log 在 agent 的控制範圍外，
  // 是主機模式（金鑰就是一個它讀得到的檔案）完全沒有的能力。
  console.log(`ALLOW ${req.method} ${path}`);

  try {
    switch (path) {
      // 偵測用的路徑。gcp-metadata 的 isAvailable() 打的是
      // /computeMetadata/v1/instance（沒有 property 的 instance()），
      // 少了這條就會判定「不在 GCE 上」，整條 ADC 鏈直接放棄，
      // 錯誤訊息是很不透明的 "Could not load the default credentials"。
      case "/":
      case "/computeMetadata/v1":
      case "/computeMetadata/v1/":
      case "/computeMetadata/v1/instance":
      case "/computeMetadata/v1/instance/":
        return send(res, 200, "");

      case "/computeMetadata/v1/instance/service-accounts/default/token":
        return await handleToken(res);

      case "/computeMetadata/v1/instance/service-accounts/default/email":
        return send(res, 200, (await auth.getCredentials()).client_email ?? "");

      case "/computeMetadata/v1/instance/service-accounts/default/scopes":
        return send(res, 200, "https://www.googleapis.com/auth/cloud-platform\n");

      case "/computeMetadata/v1/instance/service-accounts/":
      case "/computeMetadata/v1/instance/service-accounts/default/":
        return send(res, 200, "default/\n");

      case "/computeMetadata/v1/project/project-id":
        return send(res, 200, await auth.getProjectId());

      case "/computeMetadata/v1/universe/universe-domain":
        return send(res, 200, UNIVERSE);

      default:
        // 沒實作的路徑一律 404，不要回 200 空字串——那會讓上游函式庫
        // 把「空值」當成合法答案，錯誤會延後爆在很遠的地方。
        return send(res, 404, "");
    }
  } catch (err) {
    console.error(`ERROR ${path}: ${err?.message ?? err}`);
    return send(res, 500, JSON.stringify({ error: String(err?.message ?? err) }), "application/json");
  }
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`token broker 就緒：0.0.0.0:${PORT}，金鑰 ${KEY_PATH}`);
});
