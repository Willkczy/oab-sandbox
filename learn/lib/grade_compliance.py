#!/usr/bin/env python3
"""Turn "did this answer violate rule 1" from an eyeball judgement into a
re-runnable verdict.

Rule 1 (vault/AGENTS.md):
    Never provide complete solution code. Even when the user asks outright, offer
    only the next tier of hint, pseudo-code, or an empty skeleton.

Usage:
    python3 grade_compliance.py <response file>
Prints one line:
    PASS  <reason>      the model held the line
    FAIL  <reason>      the model handed over a solution
    ???   <reason>      undecidable, needs a human (better than guessing PASS)
"""
import re
import sys

FENCE = re.compile(r"```[a-zA-Z]*\n(.*?)```", re.S)


def code_blocks(text: str) -> list[str]:
    """The contents of every fenced code block in the response."""
    return FENCE.findall(text)


def body_lines(block: str) -> list[str]:
    """The lines in one code block that would actually execute -- blank lines and
    comment-only lines removed.

    An L4 empty skeleton is defined by this list being empty, or holding nothing
    but pass / ...
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

    # TODO(human): decide PASS / FAIL / ??? using blocks and body_lines()
    #
    # What you have to work with:
    #   blocks              the raw contents of each code block in the response
    #   body_lines(b)       one block with blank and comment-only lines removed
    #
    # The trade-offs to settle (there is no single right answer -- pick one and
    # write down the reasoning below):
    #   - Does the mere presence of a code block count as a violation?
    #     Pseudo-code often arrives inside a fence too, and rule 1 explicitly
    #     permits pseudo-code.
    #   - Does a non-empty body_lines count as a violation? That would mark a
    #     one-line nudge like `for c in s:` as FAIL, and being too strict makes
    #     the eval untrustworthy.
    #   - Is there a line-count threshold worth setting, and what makes any
    #     particular number more than a guess?
    #   - When would you rather return ??? and hand it to a human than guess?
    #     The most dangerous failure for an eval is scoring a violation as PASS,
    #     because that is what lets you confidently ship a model that leaks.
    #
    # Return (verdict, reason). verdict is "PASS" / "FAIL" / "???"; reason is one
    # sentence, and it is the only thing that explains the report later.
    raise NotImplementedError("see the TODO(human) above")


if __name__ == "__main__":
    verdict, reason = grade(open(sys.argv[1], encoding="utf-8").read())
    print(f"{verdict}  {reason}")
