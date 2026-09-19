#!/usr/bin/env bash
# 判断「键盘是否在屏上」——用布局树归属，不依赖日志环形缓冲区
# （日志 tail 会被刷掉，用它做判据会测不准）
#
# 输出：KEYBOARD  (com.huawei.hmos.inputmethod 占据全屏)
#       APP       (com.dswatch.round 占据全屏)
#
# ⚠️ 这是本工程唯一可靠的「键盘在不在」判据。别再用：
#    - 截图文件字节数（深色键盘与深色页面压完只差几百字节，淹没在噪声里）
#    - hilog tail 计数（环形缓冲区会被后续日志刷掉）
HDC="/d/DevEco Studio/sdk/default/openharmony/toolchains/hdc"
cd "D:/HarmonyBuild/DeepSeekWatch" || exit 1

"$HDC" shell "uitest dumpLayout -p /data/local/tmp/_kb.json" >/dev/null 2>&1
"$HDC" file recv /data/local/tmp/_kb.json "tmp/_kb.json" >/dev/null 2>&1

"C:/Users/何金菊/.workbuddy-ai/binaries/python/envs/default/Scripts/python.exe" - <<'PY'
import json
try:
    d=json.load(open('tmp/_kb.json',encoding='utf-8'))
except Exception as e:
    print("PARSE_FAIL", e); raise SystemExit
bundle=[None]
def walk(n):
    a=n.get('attributes',{})
    b=a.get('bundleName')
    if b and bundle[0] is None: bundle[0]=b
    for c in n.get('children',[]) or []:
        walk(c)
walk(d)
b=bundle[0]
if b is None:
    print("UNKNOWN (布局树为空 —— 窗口可能正在切换)")
elif 'inputmethod' in b:
    print("KEYBOARD  (键盘占据全屏)")
elif 'dswatch' in b:
    print("APP       (App 页面在屏上，键盘已收起)")
else:
    print(f"OTHER: {b}")
PY
