# learn/ — 導讀用的實機實驗

每個腳本都是**可以自己重跑、改參數玩**的小實驗，對應導讀主線的一個概念。

## 慣例

- 每支腳本開頭寫清楚：**測什麼、預期看到什麼、怎麼重跑**
- 一個指令只做一件事，複雜的資料處理放 `lib/`
- 不改動專案任何狀態（除了需要容器的實驗會起/停容器，會標註）

## 索引（依教學順序）

| 腳本 | 主題 | 對應階段 |
|---|---|---|
| *(待補)* | 容器共用核心、PID namespace | 系統層基礎 |
| *(待補)* | capabilities：CapEff vs CapBnd | S2 |
| *(待補)* | no_new_privs、read-only、noexec | S2 |
| *(待補)* | cgroup 記憶體與行程數上限 | S2 |
| *(待補)* | `/proc/1/environ` 洩漏 | S2（已知未解） |
| *(待補)* | 網路閘門與白名單繞道 | S3 |
| *(待補)* | token broker 取票 | S4 |
| `05-context-growth.sh` | context 每輪重送、成本怎麼累積 | context 層 |
| `06-message-path-to-pi.sh` | 訊息怎麼從 Discord 送到 pi（ACP / stdio） | 架構 |
| `07-context-truncation.sh` | `sed` 截斷切掉了什麼、為何比提示詞可靠 | context 層 |
| `08-tool-boundary.sh` | 宣稱的權限 vs 實際的工具（約定 vs 邊界） | context 層 |
| `09-session-dir.sh` | `--session-dir` 是否真的改變寫入位置 | 開發 ① |
| `10-cost-script-fix.sh` | session 搬家後 `pi_cost.py` 的兩種情境驗收 | 開發 ① |
| `06-message-path-to-pi.sh` | Discord → openab → pi-acp → pi 的訊息路徑 | context 層 |
| `07-context-truncation.sh` | 截斷 vs 自制力：`sed` 讓內容根本不進 context | context 層 |
| `08-tool-boundary.sh` | 工具實際粒度 vs AGENTS.md 宣稱的寫入邊界 | context 層 |
| `09-session-dir.sh` | session 檔位置與爆炸半徑 | context 層 |
| `10-model-compliance-eval.sh` | 遵守度是可測的產品屬性（可重跑的 eval） | context 層 |

> 「待補」的實驗都已經在導讀過程中實際跑過，只是還沒整理成腳本。
> 需要哪一支就說一聲。

## 支線：Vertex 認證呼叫鏈（`docs/呼叫鏈導讀.md`）

| 腳本 | 主題 | 對應步驟 |
|---|---|---|
| `chain-01-command-vs-args.sh` | 程式名與參數是分開的兩格 → 為什麼需要 `config/pi-coach` | 步驟 3 |
