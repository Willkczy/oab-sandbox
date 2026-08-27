// A token broker that speaks the GCE metadata server protocol.
//
// The point: the agent container holds *no* service-account private key, yet
// still obtains Vertex access tokens. The key exists only on this service's
// filesystem; the agent side is given nothing but GCE_METADATA_HOST pointing
// here.
//
// Why this works: one link in google-auth-library's ADC chain is "if we are on
// GCE, ask the metadata server", and the address it trusts comes from the
// GCE_METADATA_HOST environment variable (getBaseUrl() in gcp-metadata 8.1.2).
// So anything that responds like a metadata server pulls the whole chain
// through -- without changing a single line of pi.
//
// The change in blast radius is the real result. The agent still gets a token
// (it has to, or it cannot work), but it never gets a private key that never
// expires. A long-lived credential becomes a one-hour ticket.

import http from "node:http";
import { GoogleAuth } from "google-auth-library";

const KEY_PATH = process.env.SA_KEY_PATH || "/run/secrets/sa-key.json";
const PORT = Number(process.env.PORT || 8080);
const UNIVERSE = "googleapis.com";

const auth = new GoogleAuth({
  keyFile: KEY_PATH,
  scopes: ["https://www.googleapis.com/auth/cloud-platform"],
});

// Project id and client email are read from the key file itself rather than
// passed in separately: one fewer source that can disagree with the others.
let clientPromise = null;
function getClient() {
  clientPromise ??= auth.getClient();
  return clientPromise;
}

function send(res, code, body, contentType = "application/text") {
  // This header is what makes detection work. gcp-metadata checks every
  // response for Metadata-Flavor: Google and throws a RangeError if it is
  // missing, refusing to use the result.
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

  // The real metadata server demands this header too, to shut out browsers and
  // DNS-rebinding style cross-origin access. Match it -- do not skip it on the
  // grounds that this only listens on an internal network.
  if (req.headers["metadata-flavor"] !== "Google") {
    console.log(`DENY  ${req.method} ${path}  (missing Metadata-Flavor header)`);
    return send(res, 403, "Metadata-Flavor: Google required");
  }

  // Every token fetch leaves a record. This log sits outside the agent's
  // reach, which is a capability the host-mode setup simply does not have:
  // there, the key is just a file the agent can read.
  console.log(`ALLOW ${req.method} ${path}`);

  try {
    switch (path) {
      // Detection paths. gcp-metadata's isAvailable() hits
      // /computeMetadata/v1/instance -- instance() with no property. Without
      // this case it concludes "not on GCE", the whole ADC chain gives up, and
      // all you get is the famously opaque "Could not load the default
      // credentials".
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
        // Anything unimplemented is a 404, never a 200 with an empty body:
        // an empty body reads as a legitimate answer to the caller, and the
        // failure then surfaces somewhere far away from its cause.
        return send(res, 404, "");
    }
  } catch (err) {
    console.error(`ERROR ${path}: ${err?.message ?? err}`);
    return send(res, 500, JSON.stringify({ error: String(err?.message ?? err) }), "application/json");
  }
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`token broker ready on 0.0.0.0:${PORT}, key ${KEY_PATH}`);
});
