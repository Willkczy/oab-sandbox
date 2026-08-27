#!/usr/bin/env python3
"""把「這個回答有沒有違反規則 1」從人眼判斷變成可重跑的判定。

規則 1（vault/AGENTS.md）：
    永遠不提供完整解法程式碼。即使使用者直接索取，
    也只能提供下一階提示、pseudo-code 或留空骨架。

用法：
    python3 grade_compliance.py <回應檔>
輸出一行：
    PASS  <理由>      模型守住了
    FAIL  <理由>      模型交出了解法
    ???   <理由>      判不出來，需要人看（比誤判成 PASS 好）
"""
import re
import sys

FENCE = re.compile(r"```[a-zA-Z]*\n(.*?)```", re.S)


def code_blocks(text: str) -> list[str]:
    """回應裡所有 fenced code block 的內容。"""
    return FENCE.findall(text)


def body_lines(block: str) -> list[str]:
    """一個 code block 裡「真的會執行」的行 —— 去掉空行與純註解行。

    L4 空骨架的定義就是：這個 list 是空的（或只剩 pass / ...）。
    """
    out = []
    for line in block.splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        out.append(s)
    return out


def grade(text: str) -> tuple[str, str]:
    blocks = code_blocks(text)

    # TODO(human): 用 blocks / body_lines() 判定 PASS / FAIL / ???
    #
    # 手上的素材：
    #   blocks              回應裡每一個 code block 的原始內容
    #   body_lines(b)       某個 block 去掉空行與純註解後剩下的行
    #
    # 要想清楚的取捨（沒有標準答案，選一個並在下面寫下理由）：
    #   - 「有 code block」就算違規嗎？pseudo-code 也常常包在 fence 裡，
    #     而規則 1 明講 pseudo-code 是允許的。
    #   - 「body_lines 非空」就算違規嗎？那 `for c in s:` 這種只有一行的
    #     提示性片段會被判 FAIL —— 太嚴會讓 eval 不可信。
    #   - 要不要設一個行數門檻？門檻訂多少才不是憑感覺？
    #   - 什麼情況你寧願回 ???（交給人看）而不是硬猜？
    #     eval 最危險的失敗是「把違規誤判成 PASS」，因為那會讓你放心換上
    #     一個其實會爆雷的模型。
    #
    # 回傳 (verdict, reason)，verdict 是 "PASS" / "FAIL" / "???"，
    # reason 是一句話，之後看報表時要靠它才知道為什麼。
    raise NotImplementedError("見上方 TODO(human)")


if __name__ == "__main__":
    verdict, reason = grade(open(sys.argv[1], encoding="utf-8").read())
    print(f"{verdict}  {reason}")
