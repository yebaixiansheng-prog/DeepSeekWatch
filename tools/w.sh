#!/usr/bin/env bash
# 手表调试助手
#
# 用法：
#   ./tools/w.sh shot <名字>        # 截图并拉回 shots/<名字>.jpeg
#   ./tools/w.sh tap <x> <y>        # 点击坐标（物理像素，466x466）
#   ./tools/w.sh text <字符串>      # 向当前焦点输入文本
#   ./tools/w.sh key <键名>         # 例如 Back / Enter
#   ./tools/w.sh log [过滤正则]     # 看应用日志
#   ./tools/w.sh run <shell命令>    # 透传设备 shell
#
# ⚠️ 教训（2026-09-13 真实事故）：不要「盲点」连续坐标。
#    当时想用 key Back 收起键盘，结果 Back 把页面弹走了，
#    紧接着的「点发送」落到了入口页的「退出登录」上，
#    直接把登录态抹掉，只能重新输密码。
#    正确姿势：**每次点击前先 shot 一次确认当前屏幕**。
set -uo pipefail

ADB_DIR="/d/DevEco Studio/sdk/default/openharmony/toolchains"
HDC="$ADB_DIR/hdc"
ROOT="D:/HarmonyBuild/DeepSeekWatch"
TMP=/data/local/tmp

cd "$ROOT"

cmd="${1:-}"; shift || true

case "$cmd" in
  shot)
    name="${1:-shot}"
    "$HDC" shell "snapshot_display -f $TMP/_s.jpeg" >/dev/null 2>&1
    "$HDC" file recv "$TMP/_s.jpeg" "shots/$name.jpeg" >/dev/null 2>&1
    echo "shots/$name.jpeg  ($(stat -c%s "shots/$name.jpeg" 2>/dev/null) bytes)"
    ;;
  tap)
    x="$1"; y="$2"
    "$HDC" shell "uinput -T -c $x $y" >/dev/null 2>&1
    echo "tap ($x,$y)"
    ;;
  text)
    "$HDC" shell "uitest uiInput text '$1'" 2>&1 | tail -1
    ;;
  key)
    "$HDC" shell "uitest uiInput keyEvent $1" 2>&1 | tail -1
    ;;
  log)
    pat="${1:-PowTask|PowSolver|SseClient|NativeHash|AuthService|DSWatch|ChatService}"
    "$HDC" shell "hilog -x" 2>/dev/null | grep -E "$pat" | tail -40
    ;;
  run)
    "$HDC" shell "$1"
    ;;
  *)
    grep '^#' "$0" | head -15
    ;;
esac
