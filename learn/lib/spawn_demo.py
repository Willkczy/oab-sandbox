#!/usr/bin/env python3
"""Launch a string as "the program to run", without going through a shell.

This is exactly what pi-acp does when it starts pi:
    pi-acp/dist/index.js:137  ->  spawn(cmd, args, {...})
The first slot, cmd, is the program name; the second, args, is the argument
array. They are two separate slots.

Usage:
    python3 spawn_demo.py "<thing to run>" [args...]
"""
import subprocess
import sys

command_string = sys.argv[1]   # slot one: the program name
args = sys.argv[2:]            # slot two: the arguments

print(f'    program-name slot received : "{command_string}"')
print(f'    argument slot received     : {args}')

try:
    # shell=False, Python's default, means nobody splits the string for us.
    # The whole of command_string is the filename looked up on disk.
    subprocess.run([command_string] + args, check=True)
except FileNotFoundError:
    print(f'    failed to launch: no file named "{command_string}" exists on disk')
