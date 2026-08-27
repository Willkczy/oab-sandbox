#!/usr/bin/env python3
"""把一個字串當成「要執行的程式」去啟動，而且不經過 shell。

這正是 pi-acp 啟動 pi 時做的事：
    pi-acp/dist/index.js:137  →  spawn(cmd, args, {...})
第一格 cmd 是「程式名」，第二格 args 是「參數陣列」，兩格是分開的。

用法：
    python3 spawn_demo.py "<要執行的東西>" [參數...]
"""
import subprocess
import sys

command_string = sys.argv[1]   # 第一格：程式名
args = sys.argv[2:]            # 第二格：參數

print(f'    程式名那一格收到 : "{command_string}"')
print(f'    參數那一格收到   : {args}')

try:
    # shell=False（Python 的預設值）＝ 沒有人幫忙切開字串。
    # command_string 整串就是要去磁碟上找的「檔名」。
    subprocess.run([command_string] + args, check=True)
except FileNotFoundError:
    print(f'    ✗ 啟動失敗：磁碟上找不到一個名字叫 "{command_string}" 的檔案')
