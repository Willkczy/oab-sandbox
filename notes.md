# 沙箱練習實作筆記

> 計劃：`~/.claude/plans/glistening-stirring-bubble.md`
> 主機：Apple M4 / arm64 / 24GB / macOS 26.3，Docker Desktop 28.5.1
> Docker VM：linux/aarch64，10 CPU，8.2 GB RAM

---

## S0 — 準備

| 項目 | 狀態 |
|---|---|
| `~/Projects/oab-sandbox/{config,proxy,broker,vault}` | ✅ 建好 |
| vault clone | ✅ 5.4 MB，秒殺。**無任何憑證檔**（`find` 過 `*key*.json` / `auth.json` / `.env`） |
| Docker daemon | ✅ 手動 `open -a Docker` 後起來（AutoStart 是關的） |
| image pull | ✅ `ghcr.io/openabdev/openab:stable-pi`，linux/arm64，204 MB |
| 第二個 Discord bot | ⏳ **等使用者建立** ← 目前唯一阻塞項 |

### ⚠️ clone 少了 `Review/`

`Review/` 在來源 repo 是 untracked（`?? Review/`），所以 clone 沒帶到。
`教練規則/REVIEWS.md` 的弱點分析流程會讀它。不影響沙箱驗證，但要記得：
**沙箱裡的 agent 看不到回顧紀錄。**

### 磁碟現況（沒有動它）

```
Images 19.9GB / Containers 2.4GB / Build Cache 6.4GB，可回收約 23GB
host 剩 21GB
```
拉預建 image 只吃 0.2GB，不需要 prune。若之後要本機 build，先清 build cache。

---

## image 實測內容（4 個發現）

```
pi-acp       /usr/local/bin/pi-acp     ✅ 在（計劃裡唯一未驗證的假設，成立）
pi           /usr/local/bin/pi          0.79.9
openab       /usr/local/bin/openab      0.9.0
openab-agent MISSING                    ⚠️
python3      MISSING                    ⚠️
```

### ⚠️ 1. `openab-agent` 根本不在 image 裡

image 的 `OPENAB_AGENT_COMMAND=openab-agent`，但那支 binary 不存在。
所以 config 的 `[agent].command = "pi-acp"` **不是選配，是必要的**。
不寫就直接 spawn 失敗。

### ⚠️ 2. 沒有 `python3` — AGENTS.md 有三條路由會斷

`AGENTS.md` 任務路由裡這些都跑不了：

- `python3 scripts/build_index.py`（題庫索引過期時要重跑）
- `python3 scripts/pi_cost.py --current`（問「這次花多少錢」）

三個選項：(a) 疊一層 image 裝 python3；(b) 把這些工作留在主機做，沙箱只做教練互動；
(c) 把腳本改寫成 node。**尚未決定。**

### ⚠️ 3. image 的 pi 是 0.79.9，模型清單沒有 `gemini-3.6-flash`

`@earendil-works/pi-ai` 的清單裡最新的 flash 只到 `gemini-3.5-flash`：

```
gemini-3-flash / gemini-3-flash-preview / gemini-3.1-flash-lite
gemini-3.1-pro / gemini-3.1-pro-preview / gemini-3.5-flash
```

而遵守度實測結論是：`3.6-flash` ✅、`3.1-pro-preview` ✅、`3.5-flash-lite` ❌。
`3.5-flash`（非 lite）**從沒測過**。

→ 目前 `pi-coach` 先用 `google-vertex/gemini-3.1-pro-preview`（清單內唯一實測守規則的）。
代價是貴約 1.25 倍（$0.0080 vs $0.0064 每則）。

### 4. openab 是 0.9.0，不是主力機的 0.10.0

但 **config 完全相容**，見下。

---

## S1 — 跑起來

### ✅ openab 0.9.0 吃我們的 config

```
INFO openab: config loaded agent_cmd=pi-acp pool_max=3 discord=true reactions=true
INFO openab: starting discord adapter allow_all_channels=true allow_all_users=false
             users=1 allow_user_messages=MultibotMentions allow_dm=true
ERROR openab: Discord rejected bot token.   ← 用假 token 測的，預期內
```

`inherit_env`、`max_sessions`、`[markdown] tables`、`[reactions]` 全部沒有 unknown-key 錯誤。

### 🔴 新發現：openab 還要寫 `/home/node/.openab`

計劃只列了 `~/.pi`，實際 log 顯示還有：

```
/home/node/.openab/cache/threads.json    ← multibot cache
/home/node/.openab/reminders.json        ← reminders
/tmp/openab.sock                          ← 控制 socket（tmpfs /tmp 已涵蓋）
```

**S2 的可寫集合要多一個 `/home/node/.openab` volume。**

### ✅ Vertex 在容器內通

```bash
docker run --rm --entrypoint sh \
  -e GOOGLE_APPLICATION_CREDENTIALS=/run/secrets/sa-key.json \
  -e GOOGLE_CLOUD_PROJECT=your-gcp-project-id -e GOOGLE_CLOUD_LOCATION=global \
  -v ~/.config/openab/sa-key.json:/run/secrets/sa-key.json:ro \
  -v ~/Projects/oab-sandbox/vault:/workspace \
  ghcr.io/openabdev/openab:stable-pi \
  -c 'cd /workspace && pi -p --model google-vertex/gemini-3.1-pro-preview "只回兩個字：通了"'
# → 通了
```

SA 金鑰路徑走 `/run/secrets/`，區域 `global`。與主力機同一把金鑰。

---

## S2 — Docker 硬化（pi 單獨測，尚未含 openab）

### 測 1：read-only 但不給可寫 volume → 如預期壞掉

```
Error: ENOENT: no such file or directory, mkdir '/home/node/.pi/agent/sessions/--workspace--'
```

session 目錄名是工作目錄轉出來的（`/workspace` → `--workspace--`）。

### 測 2：加上 `-v oab-pi-home:/home/node/.pi` → 全通

```
通了
touch: cannot touch '/usr/bin/x': Read-only file system     ← rootfs 唯讀生效
vault 可寫: YES                                             ← 教練要寫復盤區，必須可寫
CapEff: 0000000000000000                                    ← capability 全清空
```

目前確認可用的硬化旗標組合：

```
--read-only
--tmpfs /tmp:rw,noexec,nosuid,size=64m
-v oab-pi-home:/home/node/.pi
-v oab-openab-home:/home/node/.openab      ← 新增（跑 openab 時才需要）
--cap-drop ALL
--security-opt no-new-privileges
--user 1000:1000
--pids-limit 256
--memory 2g --memory-swap 2g
```

### 🔴 `/proc/1/environ` 確實洩漏 PID 1 的環境變數

用假變數實測（`--cap-drop ALL --user 1000:1000 --read-only` 全開的情況下）：

```
$ docker exec oab-probe sh -c 'tr "\0" "\n" < /proc/1/environ | grep FAKE_DISCORD_TOKEN'
FAKE_DISCORD_TOKEN=MTUzMDk1_this_is_the_secret
```

同 uid、同 PID namespace，`/proc/1/environ` 就是可讀的。
**`env_clear` + `inherit_env` 是「沒把 token 放進 agent 的 env」，不是「agent 拿不到 token」。**
這條在舊機的 host 模式下同樣成立——容器沒有讓它變糟，但也完全沒有解決它。

真正要解得靠：把 secret 從環境變數換成檔案 + 掛載權限，或走 openab 的
`[secrets.refs]`（宣稱「只在記憶體、不進環境變數」，未驗證）。
記為 S4 之後的延伸題。

> ⚠️ 尚未驗證的那半：「agent 自己的 env 是乾淨的」需要 openab 真的跑起來才測得準
> （`docker exec` 會繼承容器 env，不是 openab spawn 子行程的路徑）。

### 待驗（需要 Discord token）

- 叫 bot 讀 `/run/secrets/sa-key.json`（預期：能，S4 才解）
- agent 子行程的 env 是否真的只有 `HOME/PATH/USER` + `inherit_env` 那幾個

---

## 疊層 image：`oab-sandbox:pi`

`Dockerfile` 只做兩件事，**不碰 Rust**：

| 疊什麼 | 為什麼 |
|---|---|
| `apt install python3` | 基底沒有，`build_index.py` / `pi_cost.py` 兩條路由會斷 |
| `npm i -g @earendil-works/pi-coding-agent@0.82.1` | 基底釘 0.79.9，模型清單沒有 `gemini-3.6-flash` |

build 約 25 秒。大小 911MB → **1.22GB**（+310MB，比預估的 +150MB 多一倍，
主要是 pi 0.82.1 的 node_modules）。

### ✅ 驗證通過

```
pi:       0.82.1          python3:  Python 3.13.5
pi-acp:   /usr/local/bin/pi-acp     openab:   0.9.0
模型清單: gemini-3.5-flash / gemini-3.5-flash-lite / gemini-3.6-flash  ← 3.6 進來了
```

在**全套硬化旗標下**（read-only + cap-drop ALL + user 1000 + pids/memory limit）：

```
=== pi-coach wrapper（3.6-flash）走 Vertex ===
沙箱通

=== python3 scripts/build_index.py ===
寫入 _系統文件/題庫索引.md
  總題數 150｜已開始 16｜進行中 9
  逾期 12｜今日到期 0｜未排程 4
```

索引寫進的是 clone 那份，主機 vault 沒被碰到——隔離如預期。

`pi-acp` 維持基底的 0.0.31 不動；0.82.1 + 0.0.31 的握手主力機實測過（211ms），
所以升版沒有引入新風險。

---

## S3 — 網路限縮

### 拓樸

```
oab-int（--internal，Internal=true，172.20.0.0/16）
  └─ agent 容器      ← 沒有對外路由，唯一出口是 proxy
  └─ oab-proxy ──┐
                 │
oab-ext（一般 bridge，172.21.0.0/16）
  └─ oab-proxy ──┘   ← 同一個容器接兩張網卡，等於唯一一道閘門
```

### 🔴 squid 不能把 log 導到 /dev/stdout

```
FATAL: Cannot open '/dev/stdout' for writing.
ERROR: Cannot open cache_log (/dev/stderr): (13) Permission denied
```

`ubuntu/squid` 會降權跑在 `proxy` 使用者，而那兩個裝置節點屬 root。
改用預設檔案路徑，看 log 走 `docker exec oab-proxy tail -f /var/log/squid/access.log`。

### ✅ 三項驗證全部如預期

| 測試 | 結果 |
|---|---|
| 不走 proxy 直接打 google.com | `000`（internal 網路沒有對外路由） |
| 走 proxy 打 `r.jina.ai` | `000`，squid log：**`TCP_DENIED/403 CONNECT r.jina.ai:443`** |
| 走 proxy 打 `oauth2.googleapis.com` | `404`（打得到，是對方回的），`TCP_TUNNEL/200` |

### ✅ 真實工作負載仍然通

`pi-coach`（gemini-3.6-flash）在**全套硬化 + 只有 internal 網路**下：

```
閘門通了

squid access.log:
  TCP_TUNNEL/200 CONNECT oauth2.googleapis.com:443     ← 換 access token
  TCP_TUNNEL/200 CONNECT aiplatform.googleapis.com:443 ← Vertex 模型請求
```

計劃裡「pi 吃 `HTTPS_PROXY`」那個前提（`http-dispatcher.js` 的
`undici.EnvHttpProxyAgent`）**實測成立**。

### ⏳ 未驗：Discord gateway 過不過得了 proxy

需要真的 bot token。預期不過——serenity 的 gateway 走 `async-tungstenite`，
不讀 proxy 環境變數（openab 的 Rust 端 `grep -rn proxy src/ crates/` 無結果）。
若真的不過，S3 的結論不受影響（上面全是 pi-only 驗的，就是計劃裡的 fallback B）。

---

## S4 — 金鑰不進容器

### 決定：r.jina.ai 放行但收窄（承 S3）

`squid.conf` 加了獨立的 `acl jina dstdomain r.jina.ai`（**只開這一個主機名，
不是 `.jina.ai` 整個網域**）與一組 `delay_pools`。

🔴 **但要誠實講 squid 在這裡做不到什麼**：HTTPS 走 CONNECT 隧道，squid 只看得到
目的主機名，**看不到 HTTP method 也看不到 reply body 大小**。所以
「只允許 GET」與 `reply_body_max_size` 對這條路徑無效——要成立得做 SSL-bump
（自簽 CA 攔 TLS），而那等於在容器裡放一把 CA 私鑰，本身又是新攻擊面。**沒做。**

隧道裡真正擋得住的只有頻寬（`delay_pools`：突發 512KB，之後 64KB/s）。
那擋的是「大量搬運」，**不是 injection**——一百個位元組的注入照樣過得去。

實際換到的是另外兩樣，而且都是主機模式沒有的：
1. **目的地釘死** — 被拿下的 agent 沒辦法把 vault 內容送去 attacker.com
2. **稽核軌跡** — 每次抓題都留在 `access.log`，在 agent 控制範圍外

### broker 實作

`broker/server.js`，約 100 行，`node:22-trixie-slim` + `google-auth-library`，
image 378MB。刻意不裝 shell 工具、curl、git——被打進來時手上能用的越少越好。

跑起來的樣子：`--read-only --cap-drop ALL --user 1000 --memory 256m`，
接 `oab-int`，**自己的出口也走 squid**（維持「只有一道閘門」的性質）。

### 🔴 障礙一：pi 有一道 `fileExists` 閘門，擋在 ADC 鏈之前

第一次測直接失敗，而且 broker 的 log 是空的——**根本沒被呼叫到**：

```
No API key found for "google-vertex".
```

原因在 `pi-ai/dist/providers/google-vertex.js` 的 `resolve()`：

```js
const adcPath = credential?.env?.GOOGLE_APPLICATION_CREDENTIALS ?? (await ctx.env("GOOGLE_APPLICATION_CREDENTIALS"));
const hasCredentials = await ctx.fileExists(adcPath ?? "~/.config/gcloud/application_default_credentials.json");
if (hasCredentials && project && location) { ... }
return undefined;   // ← 檔案不存在就到這裡，ADC 鏈完全不會走
```

**這是純粹的存在性檢查，它不讀那個檔案。** 而真正換 token 的那層
（`api/google-vertex.js`）是：

```js
function buildGoogleAuthOptions(env) {
    const keyFilename = getProviderEnvValue("GOOGLE_APPLICATION_CREDENTIALS", env);
    return keyFilename ? { keyFilename } : undefined;   // ← 沒設就走完整 ADC 鏈 → metadata server
}
```

兩層對憑證的要求不一致，這個縫隙就是解法。

### 解法：利用 HOME 的不對稱

| 誰 | 怎麼找 well-known 檔 |
|---|---|
| pi | `~` 展開 → `os.homedir()` → **HOME 沒設時回退到 passwd** → `/home/node` |
| google-auth-library 10.6.2 | **直接讀 `process.env['HOME']`**，沒設就 `location = null`，跳過 well-known → 落到 metadata server |

所以：

1. 掛一個**不是憑證**的標記檔到 `~/.config/gcloud/application_default_credentials.json`
   → 滿足 pi 的 `fileExists`
2. `pi-coach` 裡 `exec env -u HOME pi ...`
   → 讓 google-auth-library 跳過那個檔案，落到 broker
3. **不設** `GOOGLE_APPLICATION_CREDENTIALS`
   → `buildGoogleAuthOptions` 回 `undefined`，走完整 ADC 鏈

> ⚠️ 這很脆。依賴兩個實作細節：`os.homedir()` 的 passwd 回退，以及
> google-auth-library 直接讀 `process.env['HOME']`。升級 pi 或 google-auth-library
> 後要重驗。壞掉的徵兆是 `No API key found` 或 `Could not load the default credentials`。

### 🔴 障礙二：偵測路徑 `/computeMetadata/v1/instance`

修好閘門後，broker 終於被打到了，但仍失敗：

```
Could not load the default credentials.
broker log: ALLOW GET /computeMetadata/v1/instance      ← 我回 404
```

`gcp-metadata` 的 `isAvailable()` 打的是 `/computeMetadata/v1/instance`
（沒有 property 的 `instance()`）。回 404 就判定「不在 GCE 上」，整條鏈放棄，
而錯誤訊息完全看不出真正原因。補上該路徑回 200 後通過。

### ✅ 最終驗證

```
$ ls /run/secrets/
ls: cannot access '/run/secrets/': No such file or directory     ← 容器裡沒有金鑰
$ echo $GOOGLE_APPLICATION_CREDENTIALS
(未設定)

$ pi --model google-vertex/gemini-3.6-flash -p "只回五個字：金鑰不在我這"
金鑰不在我這                                                      ← Vertex 正常回應

broker 稽核 log:
  ALLOW GET /computeMetadata/v1/instance
  ALLOW GET /computeMetadata/v1/instance/service-accounts/default/token
```

**這件事要看懂**：agent 仍然拿得到 token——本來就必須拿得到，否則不能工作。
換掉的是**爆炸半徑**：從「一把永不過期的 SA 私鑰」降成「一小時期效的 access token」，
而且每一次取用都留下紀錄。這是沙箱的真實效果，不是「完全拿不到」。

---

## 開發 ①：session 檔搬進 tmpfs（2026-08-27）

### 動機

`AGENTS.md` 有一條「不要直接讀 `.jsonl`，一次 $0.18」的規則。用「如果模型不聽話會
發生什麼」去問——**什麼都不會發生**。agent 有 `bash` 也有 `read`，讀得到。
那是約定，不是邊界。

而且做不到邊界：pi 自己要寫 session，`bash` 工具是 pi 的子行程，同 uid、同 mount
namespace。工具層的粒度是「工具」，要的粒度是「路徑」，對不上。

所以改成降低爆炸半徑（與 S4 同思路）：`pi-coach` 加 `--session-dir /tmp/sessions`。
tmpfs 只留當次容器生命週期的檔，讀下去從 32K token 降到通常 < 2K。

### 動手前驗掉的四個假設

| 假設 | 結果 |
|---|---|
| pi 有改變 session 位置的功能 | ✅ `--session-dir` |
| 那個選項真的有效 | ✅ 實測；且檔案**直接**落在該目錄，不再套 `--workspace--` 子層 |
| 沒有別的元件寫死舊路徑 | ⚠️ **有**，`pi_cost.py` 第 22 行 |
| `pi-acp` 的索引失效會怎樣 | ✅ 索引在 `~/.pi/pi-acp`（持久），指向已清空的 tmpfs 時 pi 會自建新檔、不報錯 |

### 🔴 改完之後的靜默錯誤

`pi_cost.py --current` 用「掃 `SESSIONS` 目錄、挑 mtime 最新」推測本次 session。
目錄改了而它不知道，於是把**一週前**的 session 當成「本次」回報——
沒有錯誤訊息，數字與格式都正常。**這比崩潰危險。**

修法兩件事：

1. `resolve_sessions_dir()`：`PI_SESSION_DIR` → `/tmp/sessions` 存在 → 主機預設
2. **讓選擇可見**：`本次 session` 改印完整路徑，總表標題帶上實際掃描的目錄

`PI_SESSION_DIR` 由 `pi-coach` 用 `env` 往下傳，**不寫進 `config.toml`**——
`env_clear` 只發生在 openab → pi-acp 那一段，之後正常繼承。
好處是「決定位置」與「告知位置」留在同一處，沒有兩地同步的問題。

### 已知代價

- 容器停掉，session 歷史就沒了 → `--days N` 在沙箱裡失去意義
- 重啟後舊 Discord thread 接不回去（`session_ttl_hours = 6` 本來就會過期）

驗收：`./learn/dev/02-cost-script-fix.sh`（兩種情境都測）

> ⏳ **主機那份真正的 vault 還沒同步。** 這裡改的是 clone。

---

## 開發 ②：停機前把 session 封存到主機（2026-08-27）

開發 ① 用 tmpfs 換到了小爆炸半徑，代價就寫在上一節：容器一停，紀錄就沒了。
但這兩件事其實不必二選一。

關鍵是「保存」與「可達」是兩回事。tmpfs 真正要的性質是
**agent 只看得到本次 session**，它並不要求那份紀錄從此消失。
只要在容器收掉之前把檔案搬到 agent 到不了的地方，兩個目標同時成立：

```
容器內 /tmp/sessions (tmpfs)   ← agent 讀得到，但只有本次
        │ stop.sh 停機前搬出
        ▼
主機 learn/out/archive/         ← 完整紀錄，agent 看不到
```

成立的條件是 **`learn/` 不在 `run.sh` 的掛載清單裡**。哪天為了方便掛進去，
累積的歷史就一次還給 agent，tmpfs 那層等於白做。

### 🔴 `docker cp` 讀不到 tmpfs

第一版想用 `docker cp`，直接失敗：

```
$ docker cp oab-sandbox:/tmp/sessions ./out
Error response from daemon: Could not find the file /tmp/sessions in container oab-sandbox
```

而同一時間 `docker exec oab-sandbox ls /tmp/sessions` 看得到那些檔案。
原因是 `docker cp` 讀的是容器的**檔案系統層**（image layers + 可寫層），
tmpfs 則是核心另外掛上去的獨立掛載點，不屬於那些層。

改成把 tar 從 `docker exec` 的 stdout 串出來就通：

```sh
docker exec oab-sandbox tar -cf - -C /tmp sessions | tar -xf - -C "$DEST"
```

在 `--read-only --cap-drop ALL --user 1000:1000` 全開下實測成功。

### 已知代價

- **自己死掉的容器救不到。** `run.sh` 用 `--rm`，OOM 或 crash 的話，容器連同
  紀錄在 `stop.sh` 跑到之前就消失了——而那正是最需要那份紀錄的時候。

驗收：起一個同樣硬化旗標的測試容器、在 `/tmp/sessions` 寫入兩個 `.jsonl`，
跑 `./stop.sh` 確認封存內容與寫入一致（含 UTF-8）；另測「容器沒在跑」與
「容器在跑但沒寫過 session」兩種情況，都不應留下空目錄。

---

## 目前狀態

| 階段 | 狀態 |
|---|---|
| S0 準備 | ✅ 除了第二個 Discord bot |
| S1 跑起來 | ✅ 後端全通，端到端等 bot token |
| S2 Docker 硬化 | ✅ 已驗（pi 路徑） |
| S3 網路限縮 | ✅ 已驗（pi-only，即計劃的 fallback B） |
| S4 金鑰不進容器 | ✅ 已驗 |
| Discord 端到端 | ⏳ 等 bot token |

`./run.sh` 把三個容器整組拉起來，`./stop.sh` 收掉。

### 仍未驗的一件事

**Discord gateway 過不過得了 squid。** serenity 走 `async-tungstenite`，
預期不吃 proxy 環境變數。若不過，agent 容器得同時接 `oab-ext`
（等於放棄「唯一閘門」，Discord 直連），或維持現在的 pi-only 驗證方式。
**這是唯一還可能要改架構的地方。**
