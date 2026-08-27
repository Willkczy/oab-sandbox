# GCP 專案 ID 的單一來源。
#
# 為什麼需要這支：learn/ 底下有 3 支腳本要把 GOOGLE_CLOUD_PROJECT 傳給
# docker，原本各自寫死同一個字串。而 config/config.toml 早就有這個值，
# 且它已在 .gitignore 裡——真值不會進公開版控，這裡讀它就好。
#
# 用法：呼叫端已經 cd 到 repo 根目錄，所以直接
#         . learn/lib/project-id.sh
#       之後用 $GCP_PROJECT。
#
# config.toml 裡的形式（單行 inline table，注意有空格）：
#   env = { ..., GOOGLE_CLOUD_PROJECT = "your-gcp-project-id", ... }

resolve_project_id() {
    # 環境變數優先：臨時要在別的專案上跑時，export 一下就好，不用改檔案。
    if [ -n "$GOOGLE_CLOUD_PROJECT" ]; then
        echo "$GOOGLE_CLOUD_PROJECT"
        return
    fi

    # 否則從 config.toml 撈。那是單行 inline table，同一行還有
    # GOOGLE_CLOUD_LOCATION 等其他 KEY = "value" 對，所以要連
    # 等號與引號一起比對，只取第一個匹配的引號內容。
    id=$(sed -n 's/.*GOOGLE_CLOUD_PROJECT[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
         config/config.toml 2>/dev/null | head -1)

    # 找不到就停下來。這些腳本每跑一次會真的呼叫 Vertex，
    # 帶著空的專案 ID 只會換來一個看不懂的 API 錯誤。
    if [ -z "$id" ]; then
        echo "找不到 GCP 專案 ID。" >&2
        echo "  請確認 config/config.toml 存在（可從 config/config.toml.example 複製）," >&2
        echo "  或直接 export GOOGLE_CLOUD_PROJECT=<你的專案 ID>" >&2
        return 1
    fi

    echo "$id"
}

GCP_PROJECT="$(resolve_project_id)" || exit 1
