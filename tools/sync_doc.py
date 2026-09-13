#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把仓库里的交接文档同步到「用户指定的那份」

背景：用户最初给的路径是 D:\\软件\\交接文档_下一任AI.md，
但实际落盘时目录名被写成了 UTF-8 双次编码的乱码（显示为「杞欢」），
Git Bash 无法正确传递这个文件名，所以这里用 Python（走 Windows Unicode API）处理。

用法：
    python tools/sync_doc.py            # 同步 docs/交接文档_下一任AI.md
    python tools/sync_doc.py --list     # 只看看目标目录里有什么
"""
import os
import shutil
import sys

SRC = r"D:\HarmonyBuild\DeepSeekWatch\docs\交接文档_下一任AI.md"
# 候选目标目录名（按可能的编码形态都试一遍）
CANDIDATES = ["软件", "杞欢", "\u675e\u6b22", "软 件"]

TARGET_NAME = "交接文档_下一任AI.md"


def find_target_dir():
    """在 D:\\ 下找出含目标文档的目录"""
    found = []
    for name in os.listdir("D:\\"):
        full = os.path.join("D:\\", name)
        if not os.path.isdir(full):
            continue
        try:
            entries = os.listdir(full)
        except OSError:
            continue
        if TARGET_NAME in entries:
            found.append(full)
    return found


def main():
    if not os.path.exists(SRC):
        print(f"[x] 源文件不存在：{SRC}")
        return 1

    dirs = find_target_dir()
    if not dirs:
        print("[x] D:\\ 下没找到含该文档的目录")
        return 1

    print(f"[i] 源文件：{SRC}（{os.path.getsize(SRC)} 字节）")
    print(f"[i] 找到 {len(dirs)} 个候选目录：")
    for d in dirs:
        print(f"    - {d!r}")
        for n in os.listdir(d):
            p = os.path.join(d, n)
            try:
                sz = os.path.getsize(p)
            except OSError:
                sz = -1
            print(f"        {n}  ({sz} 字节)")

    if "--list" in sys.argv:
        return 0

    for d in dirs:
        dst = os.path.join(d, TARGET_NAME)
        old = os.path.getsize(dst) if os.path.exists(dst) else 0
        shutil.copyfile(SRC, dst)
        print(f"[✓] 已同步 → {dst!r}  ({old} → {os.path.getsize(dst)} 字节)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
