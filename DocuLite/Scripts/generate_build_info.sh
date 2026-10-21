#!/bin/sh
# 每次构建前由 Xcode Run Script 调用：写入当前构建时间戳。
OUT="$1"
if [ -z "$OUT" ]; then
    OUT="$(pwd)/DocuLite/GeneratedBuildInfo.swift"
fi
STAMP="$(date '+%Y-%m-%d %H:%M:%S')"
{
    printf '// 由 Xcode Run Script 自动生成，请勿手动编辑。\n'
    printf 'let kBuildTime: String = "%s"\n' "$STAMP"
} > "$OUT"
echo "[DocuLite] build time $STAMP -> $OUT"
