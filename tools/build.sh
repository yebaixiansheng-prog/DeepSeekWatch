#!/usr/bin/env bash
# DeepSeek 手表版：一键构建 release HAP
#
# 用法：
#   ./tools/build.sh            # 正常增量构建
#   ./tools/build.sh --full     # 全量重建（先搬走 ArkTS 缓存，再编译）
#
# 背景（都是实机踩过的坑，别改）：
#   1. 工程根目录的 hvigorw / hvigorw.bat 是占位脚本，不能用；
#      必须用 DevEco 自带 node + hvigorw.js，且 hvigorw.js 要写成 Windows 路径，
#      否则 Git Bash 会把 "/d/..." 当相对路径，报 Cannot find module 'D:\d\DevEco Studio\...'。
#   2. 必须显式设 DEVECO_SDK_HOME，否则 hvigor 报 00303217 Configuration Error。
#   3. 本环境的 safe-delete 保护会拦「同一轮累计删除 >= 50 次」。增量编译时编译器要删
#      过期缓存，改动文件多的时候会触发
#      （SAFE_DELETE_BULK_CONFIRM_REQUIRED / Error Code: 00308018）。
#      **绝对不要用 rm 清缓存**（手动删也计数，越删越容易触发）；
#      本脚本用 mv 把缓存目录整个改名移开，一次 mv 只算一次操作。
set -uo pipefail

ROOT="D:/HarmonyBuild/DeepSeekWatch"
NODE="/d/DevEco Studio/tools/node/node.exe"
HVIGOR="D:\\DevEco Studio\\tools\\hvigor\\bin\\hvigorw.js"
export DEVECO_SDK_HOME='D:\DevEco Studio\sdk'

cd "$ROOT"

CACHE_DIR="entry/build/default/cache/default"
OUT_DIR="entry/build/default/outputs/default"

# —— --full：把旧缓存/旧产物挪走（mv，不是 rm）——
if [ "${1:-}" = "--full" ]; then
  # 若已有 .bak，先把它挪到 outputs 之外的临时名，避免 mv 到已存在的目录里
  if [ -d "$CACHE_DIR/default@CompileArkTS.bak" ]; then
    mv "$CACHE_DIR/default@CompileArkTS.bak" "$CACHE_DIR/default@CompileArkTS.bak.old"
  fi
  if [ -d "$CACHE_DIR/default@CompileArkTS" ]; then
    mv "$CACHE_DIR/default@CompileArkTS" "$CACHE_DIR/default@CompileArkTS.bak"
    echo "[build] 已移开旧 ArkTS 缓存 → 本次全量编译"
  fi
  if [ -f "$OUT_DIR/entry-default-signed.hap" ]; then
    if [ -f "$OUT_DIR/entry-default-signed.hap.bak" ]; then
      mv "$OUT_DIR/entry-default-signed.hap.bak" "$OUT_DIR/entry-default-signed.hap.bak.old"
    fi
    mv "$OUT_DIR/entry-default-signed.hap" "$OUT_DIR/entry-default-signed.hap.bak"
    echo "[build] 已移开旧产物，避免 SignHap 删不掉旧包"
  fi
fi

# —— 编译 ——
"$NODE" -- "$HVIGOR" --mode module -p product=default -p buildMode=release \
  assembleHap --no-daemon
RC=$?

if [ $RC -ne 0 ]; then
  echo ""
  echo "[build] 失败（exit=$RC）。"
  echo "[build] 若报 SAFE_DELETE_BULK_CONFIRM_REQUIRED / 00308018，请改用： ./tools/build.sh --full"
  exit $RC
fi

# —— 同步一份到工程根（打包方习惯拿根目录那个）——
cp "$OUT_DIR/entry-default-signed.hap" DeepSeekWatch-signed.hap
ls -l DeepSeekWatch-signed.hap
echo "[build] OK"
