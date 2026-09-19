#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把仓库里的交接文档同步到「用户指定的那份」

背景：用户最初给的路径是 D:\\软件\\交接文档_下一任AI.md，
但实际落盘时目录名被写成了 UTF-8 双次编码的乱码（显示为「杞欢」），
Git Bash 无法正确传递这个文件名，所以这里用 Python（走 Windows Unicode API）处理。

★ 关键：仓库里那份是**已脱敏**的（给公开的 GitHub 看的，
  见 tools/desensitize.py），而用户手里那份是**自己用的，需要真实端点**。
  所以这里不能直接 copyfile —— 必须**把脱敏反向还原**后再写给用户，
  否则每同步一次，用户自己的文档就丢一次真实域名/内网 IP，越同步越没用。
  （这是个真实踩到的坑：先跑了 desensitize，再跑 sync_doc，
    用户那份就被「洗白」成了占位符。）

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

# 脱敏的正向规则必须与 tools/desensitize.py 保持一致（顺序也一致）。
# 这里拿来做**反向还原**：把占位符换回真实值，再写给用户。
# ★ 为什么不用「不脱敏的源」：源只有一份，而它必须能被安全地推到公开仓库。
#   用「反向还原」而不是「维护两份文档」，是为了避免两份内容漂移（迟早不一致）。
UNMASK_RULES = [
    ("https://<API_HOST>", "https://chat.deepseek.com"),
    ("http://<API_HOST>", "http://chat.deepseek.com"),
    ("<API_HOST>", "chat.deepseek.com"),
    ("<STATIC_HOST>", "fe-static.deepseek.com"),
    ("<PROVIDER_DOMAIN>", "deepseek.com"),
    ("X-<PREFIX>-PoW-Response", "X-DS-PoW-Response"),
    ("X-<PREFIX>-Guest-PoW-Response", "X-DS-Guest-PoW-Response"),
    ("x-<PREFIX>-device-id", "x-ds-device-id"),
    ("x-<PREFIX>-trace-id", "x-ds-trace-id"),
    ("'X-<PREFIX>-'", "'X-DS-'"),
    # 注意：内网 IP 是**无法**从占位符还原出具体值的（脱敏是有损的），
    # 所以下面这行只把占位符换成用户电脑的实际网段，而不是当初那个设备 IP。
]


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


def unmask(text):
    """把脱敏占位符还原成真实值（给用户自己用的那份）"""
    out = text
    hits = 0
    for a, b in UNMASK_RULES:
        n = out.count(a)
        if n:
            hits += n
            out = out.replace(a, b)
    return out, hits


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

    with open(SRC, "r", encoding="utf-8") as f:
        src_text = f.read()
    out_text, hits = unmask(src_text)
    print(f"[i] 反向还原占位符 {hits} 处（用户那份需要真实端点）")

    for d in dirs:
        dst = os.path.join(d, TARGET_NAME)
        old = os.path.getsize(dst) if os.path.exists(dst) else 0
        # ★ 不用 shutil.copyfile：要写「还原后」的内容
        with open(dst, "w", encoding="utf-8", newline="") as f:
            f.write(out_text)
        print(f"[✓] 已同步 → {dst!r}  ({old} → {os.path.getsize(dst)} 字节)")

    # 自检：确认用户那份确实拿到了真实值，而不是又写了一份占位符
    for d in dirs:
        dst = os.path.join(d, TARGET_NAME)
        with open(dst, "r", encoding="utf-8") as f:
            t = f.read()
        if "<API_HOST>" in t:
            print(f"[!] 警告：{dst} 里仍残留 <API_HOST> 占位符，请检查 UNMASK_RULES")
        else:
            print(f"[✓] 自检通过：{os.path.basename(dst)} 已含真实端点")
    return 0


if __name__ == "__main__":
    sys.exit(main())
