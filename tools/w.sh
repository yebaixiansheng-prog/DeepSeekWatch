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
#   ./tools/w.sh tree               # ★ 打印界面布局树（精确坐标，别靠肉眼估）
#   ./tools/w.sh kb                 # 判断键盘当前是否在屏上
#
# ⚠️ 教训（2026-09-13 真实事故）：不要「盲点」连续坐标。
#    当时想用 key Back 收起键盘，结果 Back 把页面弹走了，
#    紧接着的「点发送」落到了入口页的「退出登录」上，
#    直接把登录态抹掉，只能重新输密码。
#    正确姿势：**每次点击前先 shot 一次确认当前屏幕**。
#
# ⚠️ 教训（2026-09-19）：别用「截图文件字节数」判断界面变没变。
#    那个自带的深色输入法字形近乎纯黑压在纯黑背景上，JPEG 压完
#    键盘态和登录页只差 ~700 字节，完全淹没在压缩噪声里，
#    害得我误判「点击没生效」并去改本来正常的代码。
#    要判断界面状态：① 用 `tree` 看布局；② 用 `kb` 看键盘事件；
#    ③ 真要比较图像就比**像素**（Pillow）而不是比**文件大小**。
#    （顺带说明：抓帧偶发全黑是设备侧 framebuffer 陈旧，
#      `aa force-stop` + `aa start` 重启 App 即可恢复，不是 App 的问题。）
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
    # ⚠️ 用 -c（touch click）而不是 -m（move/drag）：
    #    -m 是「按下→平滑移动到目标」，在部分控件上会被判成拖拽而非点击。
    #    -c 才是真正的瞬时点击。
    "$HDC" shell "uinput -T -c $x $y" >/dev/null 2>&1
    echo "tap ($x,$y)"
    ;;
  # ★ 用布局树拿「精确坐标」，别再靠肉眼看截图估坐标。
  #   设备端：uitest dumpLayout -p /data/local/tmp/l.json
  #   本命令把它拉回来并只打印有文字/可点击/可滚动的节点。
  #   得到的 bounds 是物理像素，可直接喂给 tap。
  tree)
    "$HDC" shell "uitest dumpLayout -p $TMP/l.json" >/dev/null 2>&1
    "$HDC" file recv "$TMP/l.json" "tmp/l.json" >/dev/null 2>&1
    PY="C:/Users/何金菊/.workbuddy-ai/binaries/python/envs/default/Scripts/python.exe"
    "$PY" - <<'PYEOF'
import json
d=json.load(open('tmp/l.json',encoding='utf-8'))
rows=[]
def walk(n,depth=0):
    a=n.get('attributes',{})
    t=a.get('type','');txt=a.get('text','');b=a.get('bounds','')
    cl=a.get('clickable','');sc=a.get('scrollable','')
    if txt or cl=='true' or sc=='true' or t in ('Button','TextInput','Toggle'):
        rows.append((depth,t,txt,b,'CLICK' if cl=='true' else '','SCROLL' if sc=='true' else ''))
    for c in n.get('children',[]) or []:
        walk(c,depth+1)
walk(d)
for depth,t,txt,b,cl,sc in rows:
    print(f"{'  '*depth}{t:<12}| {txt[:36]:<36}| {b:<18}| {cl} {sc}")
PYEOF
    ;;
  # 判断键盘是否在屏上（比肉眼看截图可靠）
  kb)
    n=$("$HDC" shell "hilog -x 2>/dev/null | grep -c 'HMKeyboard_KeyboardController: onKeyboardShow'" 2>/dev/null | tr -d '\r')
    h=$("$HDC" shell "hilog -x 2>/dev/null | grep -c 'BaseIMEAbilityEventD: onKeyboardHide'" 2>/dev/null | tr -d '\r')
    echo "onKeyboardShow=$n  onKeyboardHide=$h  (show>hide => 键盘在屏上)"
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
