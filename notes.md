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
| Discord 端到端 | ✅ 真 token 對話跑通（2026-09-15）；resume 未量 |

`./run.sh` 把三個容器整組拉起來，`./stop.sh` 收掉。

---

## Discord gateway：從「預期不過」到量測完成（2026-09-04 / 09-06）

原本這裡寫的是「仍未驗的一件事：Discord gateway 過不過得了 squid，預期不過」。
現在兩件事都做完了——**真的跑過，而且量出斷在哪一層**。

### 🔴 2026-09-04：真的失敗了，但沒有人把它寫下來

那天用真的第二支 bot token 跑 `./run.sh`。openab 印出：

```
INFO openab: config loaded agent_cmd=pi-acp pool_max=3 discord=true
INFO openab: starting discord adapter ... users=1 allow_dm=true
INFO openab: discord bot running          ← 這行是騙人的
```

**一個錯誤都沒有**，但 bot 在 Discord 上是灰色離線，訊息完全沒反應。

當場查到三項證據：openab 自己的環境變數只有 `DISCORD_BOT_TOKEN`（沒有任何
proxy）、容器內解析 `discord.com` 得到 `EAI_AGAIN`、squid 本身可達。

那次的主線任務是換模型，這個發現被正確判定「不是本分支造成的」，於是沒進 PR #10
——**然後就沒有回寫到這裡**。AGENTS.md 明明有規則（「something surprising… goes
into notes.md **as it happens, with the date**」），規則沒被執行。結果是 `notes.md`
和 `docs/findings.md` 又掛了兩天的「⏳ 等 bot token」，而 token 早就有了、也早就
測過了。這是這次要補的第一件事。

### 為什麼那次只證到一半

失敗有兩層疊在一起，而 `EAI_AGAIN` 只證明了第一層：

| 層 | 內容 |
|---|---|
| 1 | `HTTPS_PROXY` 寫在 `config.toml` 的 `[agent] env`，那是 openab 給 **pi 子行程**的環境變數，openab 自己沒有。在 `--internal` 網路上連 DNS 都做不到。 |
| 2 | 就算補上，serenity 是**分成兩半**的：REST 走 `reqwest`（讀 proxy 環境變數），gateway 走 `tokio-tungstenite`（**完全不支援 proxy**）。 |

第一層把第二層整個遮住了，所以那天測不出來第二層。

### ✅ 2026-09-06：`learn/13-discord-gateway-proxy.sh`，兩層都量掉

同一個容器跑兩次，唯一差別是有沒有給 openab proxy 環境變數。關鍵是
`RUST_LOG=debug`——**預設等級下整個失敗是隱形的**，因為 serenity 把 shard 錯誤記在
retry 迴圈裡的 WARN，而 openab 自己那行 INFO 兩種情況都照印 `discord bot running`。

arm B（有 proxy 變數）的 log：

```
reqwest::connect: proxy(http://oab-t13-proxy:3128/) intercepts 'https://discord.com/'
hyper_util: connected to 172.22.0.2:3128
hyper_util::pool: pooling idle connection for ("https", discord.com)   ← REST 穿過 squid 了
...
serenity::gateway::bridge::shard_queuer: Err starting shard 0:
    Tungstenite(Io(Custom { error: "failed to lookup address information:
    Temporary failure in name resolution" }))                          ← gateway 沒有
```

結論：**第一層成立且一個環境變數就能修；第二層成立**——tungstenite 自己去做 DNS，
代表它根本沒看 proxy 設定。serenity 的錯誤訊息裡直接指名 `Tungstenite`。

而且**這個實驗不需要有效 token**。serenity 拿 gateway URL 用的是**不需認證的**
`GET /gateway`，所以 REST 那一跳跟 token 有沒有效無關；接在後面的 gateway 嘗試
就是第二層要測的東西。腳本用一個「格式正確但無效」的假 token 就跑得完。

### 🔴 兩個踩到的量測陷阱

**(a) squid 的 access.log 對長連線是空的。** squid 是在 CONNECT 隧道**關閉**時才寫
log，而 reqwest 會把連線 pool 起來保持開啟。所以第一版腳本數 access.log 行數，對一
個明明成功的請求報出「什麼都沒發生」。改用 openab 自己的 debug log 才量得準。

**(b) 假 token 的「格式」會改變測到的東西。** serenity 會先在本地驗證 token 形狀
（三段、用 `.` 分隔），不合格就**連 socket 都不開**。第一版用了自由文字當
placeholder，結果測到的是「serenity 本地擋掉」而不是「網路不通」——而 log 長得
一模一樣，照樣印 `discord bot running`。

這兩個都是同一類：**看起來完成了、其實什麼都沒測到**，跟 `pi_cost.py` 那次靜默報
舊數字是同一種病。

### 現在的選項

第二層確認之後，`oab-ext` 直連不再是唯一解。上游 `openabdev/openab` 的
`docs/openshell.md` 自己承認了這個限制（「Unless OAB's networking layer is
refactored to be fully HTTP/HTTPS proxy-aware (tunneling WSS through the L7
proxy), the integration cannot function.」），所以這不是設定錯誤，是已知架構限制。

可行的四條路寫在 `docs/findings.md` 那一則裡。其中最值得試的是用 socat 的 `PROXY`
位址型別做一個 CONNECT 中繼：它只搬 bytes、不拆 TLS，所以憑證照樣端到端驗得過，
流量仍然走 squid，**「唯一閘門」這條性質保得住**。

---

## 🔴 allowlist 少了 `.discord.gg`——而且 `learn/13` 不可能測到它（2026-09-08）

上一節結論說 socat 中繼最值得試。準備動手時重讀 `proxy/squid.conf`，發現一個
會讓那條路直接撞牆的東西：

```
# squid.conf:22
acl allowed_domains dstdomain .googleapis.com .discord.com .discordapp.net .discordapp.com
```

**`.discord.gg` 不在裡面。** 而 gateway 就在那個網域下——直接問 Discord 自己：

```console
$ curl -sS https://discord.com/api/v10/gateway
{"url":"wss://gateway.discord.gg"}
```

（這正是 serenity 用來拿 websocket URL 的那個**不需認證**端點，所以查它不用 token。）

結尾是 `.gg` 不是 `.com`，`.discord.com` 那條規則涵蓋不到，於是會落到
`http_access deny all`（`squid.conf:55`）。

### 為什麼 `learn/13` 測不出來

不是腳本寫得不好。arm B 裡 `tokio-tungstenite` 是在**本機 DNS 解析**那一步就失敗
的，它從來沒有把任何封包送到 squid——**squid 的 allowlist 根本沒有參與那次實驗**。

所以這是「沒被測到」，不是「測過了沒問題」。兩者在證據上完全不同，而它們長得一樣：
都是「沒有出現相關的錯誤」。又一次 finding 5。

### 🔴 真正麻煩的地方：它會偏袒最糟的選項

這不只是「還要多改一行」。在沒補 allowlist 的狀態下逐一去試 finding 8 的四條路：

| 選項 | 會觀察到什麼 |
|---|---|
| A（socat）／B（proxychains）／D（patch 上游） | 流量**真的走進 squid** → 撞上 `deny all` → 看起來像「這個方法沒用」 |
| C（agent 直接接 `oab-ext`） | **完全繞過 squid** → 立刻成功，而且只要一行指令 |

也就是說，環境會**主動製造證據**去支持那個唯一放棄「唯一閘門」的選項，而讓三個
保住它的選項看起來都失敗。

**所以補 allowlist 不是可以延後的細節，它是讓其他三條路有機會被公平評估的前提。**
動 socat 之前先做這件事。

一般化的教訓：要比較幾個方案時，先確認失敗的原因不是來自**所有方案共用的那一段**。
否則比的不是方案本身，是誰比較能繞過那個共用瓶頸——而最能繞過的，往往正是最不該
選的那個。

### 補的時候要注意

照這個檔案自己的先例（`squid.conf:34` 解釋為什麼寫 `r.jina.ai` 而不是 `.jina.ai`）：
**只加 `gateway.discord.gg` 這一個主機名，不要加 `.discord.gg` 整個網域。**

另外，這裡確認的是 Discord 在 `GET /gateway` 上**公告**的主機名。socat 方案要把它
寫死在 `--add-host` 或 network alias 裡，所以對方哪天改主機名那條假 DNS 就會失效
——這個脆弱性沒有因為主機名被確認而消失。

> 尚未動手。`squid.conf` 還沒改，socat 也還沒建。

---

## ✅ socat relay 建好：gateway 過閘門，但差點帶著迴圈上線（2026-09-15）

分支 `feat/discord-gateway-relay`，上一節（PR #12）的紀錄先併進來當起點。

### 1. 先量「改之前」：上一節的判斷成立

relay（當時用 network alias）＋舊的 `squid.conf`：

```
squid: 172.22.0.3 TCP_DENIED/403 CONNECT gateway.discord.gg:443 HIER_NONE/-
relay: socat[13] W CONNECT gateway.discord.gg:443: Forbidden
```

allowlist 補上 `gateway.discord.gg`，只有這一個主機名。

### 🔴 2. 補完 allowlist：squid 和 relay 互相 tunnel 了 31 次

```
squid: 172.22.0.3 TCP_TUNNEL/200 CONNECT gateway.discord.gg:443 HIER_DIRECT/172.22.0.3   ← 31 行
relay: socat[1] E fork(): Resource temporarily unavailable
relay: socat[1] N exit(1)
```

原因：`--network-alias` 是 Docker 內建 DNS 對**整個網路**回答的。squid 也在 oab-int 上，
所以 squid 查 `gateway.discord.gg` 一樣拿到 relay 的 IP（`getent hosts` 直接看得到）。
squid 連 relay，relay 再 CONNECT 回 squid，一路繞下去。

最陰險的是 **31 行全是 `TCP_TUNNEL/200`，主機名也全是對的**。唯一露餡的是 `HIER_DIRECT/`
後面那個 IP 是 relay 自己。它會停也不是有人發現，而是 relay 的 `--pids-limit 32` 讓 fork
失敗、把 listener 整個弄死。又一個 finding 5。

原本的計畫是「用 network alias，不用寫死 IP」。這個計畫是錯的，量了才知道。修法兩層：

- 假解析只給 agent：`--add-host gateway.discord.gg:$RELAY_IP`，IP 每次啟動用
  `docker inspect` 讀。squid 查到的是真的 DNS。
- squid 加 `private_dst`：解析到私有網段的目的地一律拒絕。同樣的 alias 設定重跑，
  31 次迴圈變成一行 `TCP_DENIED/403`。

### ✅ 3. `--add-host` 版：TLS 端到端，squid 只記一條

```
client 解析 : 172.22.0.3（relay）
squid 解析  : 162.159.130.234 等五個（Cloudflare）
node https  : status 404 | cert verified: true | peer CN: discord.gg
squid       : 172.22.0.3 TCP_TUNNEL/200 CONNECT gateway.discord.gg:443 HIER_DIRECT/162.159.130.234
```

404 是對的，普通 GET 沒有 websocket upgrade。重點是憑證驗過了，代表 socat 沒拆 TLS。

### ✅ 4. `learn/13` arm C：無效 token 變成證據

```
gateway sent Ok(Hello(41250))
Received close frame: Some(CloseFrame { code: Library(4004), reason: "Authentication failed." })
openab: Discord rejected bot token.
squid: 172.22.0.3 TCP_TUNNEL/200 CONNECT gateway.discord.gg:443 HIER_DIRECT/162.159.134.234
```

4004 只有 Discord 的 gateway 發得出來，所以不用真 token 就能證明 websocket 穿過閘門。

openab 收到 4004 會**直接結束**，不像 DNS 失敗那樣每 5 秒重試。第一版 arm C 還在用
`docker exec` 查 DNS，結果查的是一個已經停掉的容器。現在改成用同網路設定的兄弟容器問。

前三次跑 arm C 有一次 squid 對 discord.com 和 gateway **都**回 `TCP_TUNNEL/503`，下一次原封
不動就過了。那是閘門外側的問題，跟 relay 無關。判定當時回 UNDECIDABLE，沒有誤判；後來加了
UPSTREAM FAILURE 分支把它講清楚。

### ✅ 5. 真正的 `run.sh` 冷啟動（假 token）

四個容器依序起來，openab 2 秒內走完 REST、gateway、4004，然後結束：

```
squid: 172.20.0.3 TCP_TUNNEL/200 CONNECT gateway.discord.gg:443 HIER_DIRECT/162.159.135.234   ← relay
squid: 172.20.0.5 TCP_TUNNEL/200 CONNECT discord.com:443 HIER_DIRECT/162.159.137.232          ← agent
```

這一次冷啟動沒撞到「squid 還沒 ready」的 race，但只有一個樣本。

`verify-hardening.sh` 加了 relay 的 7 項檢查，全過。其中一項是
`ip_unprivileged_port_start = 0`：uid 1000、零 capability 的 socat 能綁 443，全靠這個
Docker 預設值，哪天升級改掉了 relay 就起不來。

### ⏳ 還沒量的

- **真 token 的完整對話。** 需要第二支 bot 的 token，而且要有人在 Discord 上傳訊息。
- **resume。** READY 裡的 `resume_gateway_url` 是區域主機（例如
  `gateway-us-east1-b.discord.gg`），allowlist 和 `--add-host` 都沒涵蓋。binary 裡有 serenity
  的 `Failed to resume` 路徑，推測會退回重新 identify，但沒量過。量法：真 token 連上之後，
  在 `oab-relay` 裡殺掉那條 socat 子行程，看 serenity 怎麼重連。
- **squid log 的歸屬。** gateway 流量的來源現在記成 relay，不是 agent。

---

## ✅ 真 token 對話跑通，但第一次被一個「還活著的舊 squid」擋住（2026-09-15 晚上）

### 🔴 第一次：bot 一直離線，終端機只有 `discord bot running`

```
squid: 172.20.0.5 TCP_DENIED/403 CONNECT gateway.discord.gg:443 HIER_NONE/-   ← 每 5 秒一行
relay: socat[90] W CONNECT gateway.discord.gg:443: Forbidden
```

relay 和 `--add-host` 都是對的，拒絕的是 squid。squid 在 20:58:08 啟動，那時 checkout 還在
main，allowlist 裡沒有 `gateway.discord.gg`。之後切到分支再跑 `run.sh`，它看到 `oab-proxy`
在跑就直接沿用。

容器裡看到的 `squid.conf` 其實已經是新的，`grep` 找得到 `discord_gateway`。但 squid 只在
啟動時讀一次設定：`cache.log` 裡的 `Processing Configuration File` 只出現在 20:58:08。

又一個 finding 5：檔案是對的、容器是活的、log 說 bot running，閘門卻還是舊的。`run.sh` 對
proxy、relay、broker 都是「沒在跑才啟動」，設定改了不會重建，也不會提醒。

### ✅ `./stop.sh` 再 `./run.sh`：@mention 在 thread 裡得到回覆

```
relay : successfully connected to gateway.discord.gg:443 via proxy oab-proxy:3128   ← 沒有 exit，長連線
openab: discord bot connected user=openab-sandbox
squid : broker  TCP_TUNNEL/200 CONNECT oauth2.googleapis.com:443
squid : agent   TCP_TUNNEL/200 CONNECT discord.com:443
squid : agent   TCP_TUNNEL/200 CONNECT aiplatform.googleapis.com:443
```

gateway 那條不在 squid log 裡，因為隧道還開著，跟 learn/13 header 說的一樣。

bot 在 thread 裡回：`pi v0.84.2`，讀了 `/workspace/AGENTS.md`，然後是「在！今天想練哪一題，或是
要進行復盤、查看複習進度？」

### 🔴 順便看到的兩件事

**pi 會自己往外連，被 squid 擋掉了。**

```
squid: agent TCP_DENIED/403 CONNECT pi.dev:443              ← 3 次
squid: agent TCP_DENIED/403 CONNECT registry.npmjs.org:443  ← 2 次
```

pi 0.84.2 的 `utils/version-check.js` 會查 `https://pi.dev/api/latest-version`，
`core/remote-catalog-provider.js` 的預設 catalog 也在 `https://pi.dev`。npm registry 那兩次是誰發的
沒有追。兩個都不在 allowlist 上，coach 照樣回答。閘門擋下了一個沒人想過要問的請求，而且看得見。

**openab 的狀態 volume 是 root 的。**

```
WARN openab_core::acp::pool: failed to persist thread mapping path=/home/node/.openab/thread_map.json error=Permission denied (os error 13)
```

`oab-openab-home` 在 8/19 建立，根目錄是 uid 0、權限 755，openab 以 uid 1000 執行，寫不進去。
thread 對應、reminders、multibot cache 每次重啟都歸零。`oab-pi-home` 是 uid 1000，所以 pi 沒事。
不是這個分支造成的，先記下來，還沒修。

### ⏳ 還沒量的

- **resume。** 區域 gateway 主機不在 allowlist，也不在 `--add-host` 裡。

---

## 開發 ③：第一次真 Discord 對話暴露的兩個缺陷，外加 pi 往外連的來源（2026-09-15 晚上）

分支 `fix/stale-containers-and-openab-volume`。

### 1. `run.sh` 沿用舊容器 → 改成指紋 label

原本的判斷只有「這個名字的容器在不在跑」。現在改走 `start_service()`：啟動時把 image ID、
所有 `docker run` 參數、掛載的設定檔內容一起做 `cksum`，寫進 `oab.inputs` label。下次跑
`run.sh` 時 label 對不上就重建，並印出原因。

broker 的金鑰檔刻意不算進去。label 誰都能 `docker inspect`，連私鑰的 checksum 都不該放在那裡。

沒有選「每次都重建」：那樣每次重跑 agent 都會把 squid 的 access.log 一起丟掉，而那是閘門唯一的紀錄。

`learn/dev/03` 把 `run.sh` 裡的函式原文抽出來，對一個丟棄式容器跑六個情境。不直接跑 `run.sh`，
因為它寫死 `oab-*` 名字，會把正在跑的 sandbox 換掉。

| 情境 | 結果 |
|---|---|
| 1 沒有容器 | started，新 id，不說話 |
| 2 什麼都沒改再跑 | reused，同一個 id |
| 3 掛載的設定檔改了（9/15 那次） | 重建，印出原因 |
| 4 某個 docker run 旗標改了 | 重建，印出原因 |
| 5 舊 `run.sh` 留下、沒有 label 的容器 | 重建，印出原因 |
| 6 停掉了但 label 相符 | started，不說話 |

六個全過。情境 5 就是目前在跑的那組容器，下次遇到新 `run.sh` 時會發生的事。

### 2. openab 的狀態 volume 是 root 的 → Dockerfile 先建目錄

原因量到了：base image 裡有 `/home/node/.pi`（uid 1000），但沒有 `/home/node/.openab`。
Docker 把 named volume 掛到 image 裡**已存在**的目錄上時，會把那個目錄的擁有者複製到空的
volume；目錄不存在的話，掛載點就由 root 建立。所以 `.pi` 沒事，`.openab` 從 8/19 起就寫不進去。

修法是 Dockerfile 裡一行 `mkdir -p /home/node/.openab && chown node:node /home/node/.openab`。

意外的好消息：**已經是 root 的空 volume，換新 image 掛上去也會被改成 1000。** `learn/dev/04`：

```
ok the image: /home/node/.openab      1000
ok the old state                      0, not writable
ok half 1, new volume                 1000, writable
ok half 2, the root-owned volume      1000, writable
```

所以真正的 `oab-openab-home` 不用刪。它一直是空的，因為 openab 從來沒寫進去過，下次用新 image
啟動就會修好。重建後的 image 跑 `verify-hardening.sh` 全過。

### 3. pi 往外連的那 5 次，來源追到了

**pi.dev × 3 是 pi 的模型目錄刷新。** `main.js` 裡，rpc 模式且非 offline 時，啟動就在背景跑
`modelRuntime.refresh()`。pi-ai 只對有憑證的 provider 走網路，這裡只有 `google-vertex`。請求走
`utils/management-http.js` 的 `fetchWithRetry`，預設 `maxRetries = 2`，失敗立刻重試、不等待。
squid 回 403 讓 fetch 丟錯，於是一次刷新變成 7 ms 內的三行。失敗不會寫入 `checkedAt`，所以每次
pi 啟動都會再來一次。

**registry.npmjs.org × 2 是 pi-acp 的更新提示。** `pi-acp/dist/index.js` 的 `buildUpdateNotice()`
在**每個新 session** 都跑 `npm view @earendil-works/pi-coding-agent version`，timeout 800 ms，
沒有任何開關。為什麼是兩條連線，沒有追進 npm 內部。

**版本檢查不是來源。** `checkForNewPiVersion` 雖然也連 `pi.dev/api/latest-version`，但只在互動模式呼叫。

`PI_OFFLINE=1` 能關掉 pi 那三條，關不掉 pi-acp 那兩條。沒有加，因為兩者被擋都不影響回答。

順帶修正 Dockerfile 的一句舊描述。「pi 的模型目錄是編進 pi-ai 的靜態 JSON」在 0.84.2 已經不完全對：
它啟動時會從 pi.dev 疊一層遠端目錄。sandbox 裡被 squid 擋掉，所以編進去的清單仍是全部；但在
沒有閘門的 production 機器上，**不升級 pi，可用的模型清單也可能改變**。

---

## 開發 ④：vault/ 落後四週，改成有提醒的雙向同步（2026-09-16）

### 🔴 發現

沙箱的 `vault/` 是 8/19 從 iCloud vault clone 出來的，之後沒有人更新過。9/16 比對的結果：
iCloud 有 7 個 commit 沒進來、28 個檔案還沒 commit、57 個檔案內容不同。9/15 那次 Discord
對話，coach 是拿三週多以前的進度在回答，而且沒有任何地方提醒。又一個 finding 5。

先手動同步一次，兩邊都停在 `c9acb6a`，然後寫成 `vault-sync.sh`。

### 設計：兩個方向的風險不同

| 方向 | 指令 | 為什麼 |
|---|---|---|
| main vault → `vault/` | `pull` | 自己的筆記送進沙箱。只要 `vault/` 沒有未 commit 的修改就安全 |
| `vault/` → main vault | `back` | agent 寫的東西進到可信的 vault。讀過被注入網頁的 agent，改 `AGENTS.md` 或 `scripts/` 跟改筆記一樣容易，所以要列出 commit、標出不是筆記的檔案、按 yes 才 fast-forward |

commit 兩邊都留給人。練習的 commit 訊息該自己寫，全自動 commit 會把該標出來的東西一起 commit 掉。

`run.sh` 啟動前跑 `remind-start`，`stop.sh` 結束後跑 `remind-stop`，只提醒、不擋。

### 🔴 測試時抓到的坑

`vault/` 是 `run.sh` 的掛載點。fresh clone 第一次跑時，Docker 會自己建一個**空目錄**。
這時 `git -C vault rev-parse` 會往上找到 oab-sandbox 自己的 repo，把它當成 vault，提醒就會
拿 GitHub 上的 oab-sandbox 去比。改成要求 repo 的 top level 正好是這個目錄，`learn/dev/05`
第 9 個情境專測這件事。

### 沙箱搬到舊機時

iCloud 裡的 `.git` 被兩台同時寫會壞，`手機接入計劃.md` 早就記過這個雷。所以 `status`、`pull`
和提醒在跑沙箱的那台執行，`back` 則在 commit 主 vault 的那台執行，SOURCE 用 ssh 指向另一台的
`vault/`。這樣主 vault 的 `.git` 永遠只有一台在寫。

`learn/dev/05` 九個情境全過，測試 repo 的路徑刻意含空格、筆記刻意用中文檔名，跟真的 vault 一樣。

---

## 🔴 閘門記住失敗的時間，比失敗本身還長（2026-09-17）

### 線索在「失敗有多快」

9/15 那台放著跑 16 小時的沙箱，gateway 斷了 19 次。squid 記了 236 次 `TCP_TUNNEL/503`，其中
215 次是 `HIER_NONE/-`，代表連位址都沒選到，也就是查名字就失敗了。

真正的線索不是失敗次數，是**每次只花 0 到 11 毫秒**。沒有任何查詢會這麼快失敗。那是快取。

### 兩次走錯路，而且都學到東西

**(a) IPv6 是錯的方向。** squid 啟動時開了 `[::]` 的 DNS socket，所以原本懷疑 AAAA 查詢卡住。
探針顯示 AAAA 每次都失敗——但原因是 `gateway.discord.gg` **根本沒有 AAAA 記錄**（`dig` 確認）。
固定發生的事，解釋不了間歇發生的故障。

**(b) 把閘門的網路拔掉，重現的是另一種故障。** 用 `docker network disconnect` 切斷 proxy 對外
網路，squid 記的是 `HIER_DIRECT/<位址>`：它用快取解析出位址、連不上。而且網路一接回來就立刻恢復。
原因是 squid 對**成功**的解析預設記 6 小時，所以短暫的 resolver 中斷它根本感覺不到——實測中斷
30 秒期間有 14 次 CONNECT 照樣成功。

第一次寫的時候還有兩個 bug：取樣容器只接內網（本來就解析不到任何東西），以及計數用
`grep 'A=FAIL'` 連 `AAAA=FAIL` 也數進去。兩個都是「看起來有數據、其實在量別的東西」。

### ✅ 正確的重現方式

讓 squid 用一個我可以隨時關掉的 resolver（socat 轉發 UDP 53），再把正向快取縮短成 5 秒，
讓快取在中斷期間過期。這時才重現出 `HIER_NONE`。關鍵是 resolver 回來之後：

| squid.conf | resolver 回來後多久恢復 |
|---|---|
| 原本的設定 | 40 秒 |
| 加上 `negative_dns_ttl 1 second` | 5 秒 |

預設值是 60 秒。一次真的查詢失敗，就換來一分鐘的「立刻拒絕」，而客戶端每 5 秒重試一次——
這正好就是 log 裡那種一叢一叢的失敗。設定已經加進 `proxy/squid.conf`。

### 還沒解釋的

**為什麼查詢會失敗**還不知道。那台是每天睡醒幾十次的筆電，而沙箱正要搬到一台不睡的機器。
`learn/14` 的 `watch` arm 就是為了在那台機器上量這件事。
