#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
开源前脱敏：把文档里的「可直接照抄」的部分泛化成占位符

保留什么：架构、协议形状、错误码语义、工程经验（这些是可复用的技术价值）
拿掉什么：真实域名、请求头前缀、内网 IP —— 也就是「复制即可用」的那层皮

用法：
    python tools/desensitize.py --dry-run   # 只看会改哪些，不落盘
    python tools/desensitize.py             # 实际执行（幂等，可重复运行）
"""
import os
import re
import sys

ROOT = r"D:\HarmonyBuild\DeepSeekWatch"
DOCS_DIR = os.path.join(ROOT, "docs")

# 只处理文档，不碰代码（代码必须保留真实端点才能编译运行）
TARGET_PAT = re.compile(r"\.(md|html)$", re.I)

# 替换规则（顺序有讲究：先长后短）
RULES = [
    ("https://chat.deepseek.com", "https://<API_HOST>"),
    ("http://chat.deepseek.com", "http://<API_HOST>"),
    ("chat.deepseek.com", "<API_HOST>"),
    ("fe-static.deepseek.com", "<STATIC_HOST>"),
    ("static.deepseek.com", "<STATIC_HOST>"),
    ("deepseek.com", "<PROVIDER_DOMAIN>"),
    # 请求头前缀
    ("X-DS-PoW-Response", "X-<PREFIX>-PoW-Response"),
    ("X-DS-Guest-PoW-Response", "X-<PREFIX>-Guest-PoW-Response"),
    ("x-ds-device-id", "x-<prefix>-device-id"),
    ("x-ds-trace-id", "x-<prefix>-trace-id"),
    ("'X-DS-'", "'X-<PREFIX>-'"),
]

# 正则规则：内网 IP 一律泛化（真机调试用的，属于隐私）
RE_RULES = [
    (re.compile(r"\b192\.168\.\d{1,3}\.\d{1,3}\b"), "<DEVICE_IP>"),
]

BANNER = (
    "> ## ⚠️ 本文档已脱敏\n"
    ">\n"
    "> 为降低对上游服务的影响，文档中的**真实域名、请求头前缀、调试设备 IP** 已替换为占位符：\n"
    ">\n"
    "| 占位符 | 含义 |\n"
    "|---|---|\n"
    "| `<API_HOST>` | 对话服务的 API 域名 |\n"
    "| `<STATIC_HOST>` | 前端静态资源域名 |\n"
    "| `<PROVIDER_DOMAIN>` | 服务商主域名 |\n"
    "| `X-<PREFIX>-...` | 私有请求头前缀 |\n"
    "| `<DEVICE_IP>` | 真机调试用的设备内网 IP |\n"
    ">\n"
    "> 接口路径、字段结构、错误码语义、协议帧形态**均保持原样** —— 那是本项目真正的工程价值。\n"
    "> 需要真实端点时，请自行抓包获取，并遵守服务商的使用条款。\n"
    "\n"
)


def process_file(path, dry):
    with open(path, "r", encoding="utf-8") as f:
        src = f.read()
    out = src
    hits = 0
    for a, b in RULES:
        n = out.count(a)
        if n:
            hits += n
            out = out.replace(a, b)
    for pat, rep in RE_RULES:
        out, n = pat.subn(rep, out)
        hits += n
    if hits == 0:
        return 0
    if not dry:
        with open(path, "w", encoding="utf-8") as f:
            f.write(out)
    return hits


def main():
    dry = "--dry-run" in sys.argv
    total = 0
    files = []
    for name in sorted(os.listdir(DOCS_DIR)):
        if TARGET_PAT.search(name):
            files.append(os.path.join(DOCS_DIR, name))

    for p in files:
        n = process_file(p, dry)
        if n:
            total += n
            print(f"{'[试运行] ' if dry else ''}{os.path.basename(p):40s} 替换 {n} 处")

    # API_SPEC.md 顶部加脱敏说明（幂等）
    spec = os.path.join(DOCS_DIR, "API_SPEC.md")
    if os.path.exists(spec):
        with open(spec, "r", encoding="utf-8") as f:
            cur = f.read()
        if "本文档已脱敏" not in cur:
            if not dry:
                with open(spec, "w", encoding="utf-8") as f:
                    f.write(BANNER + cur)
            print(f"{'[试运行] ' if dry else ''}API_SPEC.md 已插入脱敏说明")

    print(f"\n合计 {total} 处{'(未落盘)' if dry else ''}")


if __name__ == "__main__":
    main()
