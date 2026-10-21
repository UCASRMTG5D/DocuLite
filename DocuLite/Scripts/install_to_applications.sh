#!/bin/sh
# 每次构建后由 Xcode Run Script 调用：把新构建的 DocuLite.app 装进 /Applications。
# 用法：install_to_applications.sh <built-app-path>
# 行为：删除旧版 /Applications/DocuLite.app，再拷贝新版进去（需对 /Applications 有写权限，
#       普通 admin 用户无需 sudo）。
set -eu

APP="$1"
if [ -z "$APP" ] || [ ! -d "$APP" ]; then
    echo "[DocuLite][install] 找不到待安装的 app：$APP" >&2
    exit 1
fi

DEST="/Applications/DocuLite.app"

# 若 /Applications 当前不可写，退出并提示（避免静默失败）
if [ ! -w /Applications ]; then
    echo "[DocuLite][install] /Applications 不可写，跳过安装。请确认当前用户属于 admin 组，或将 /Applications 设为可写。" >&2
    exit 1
fi

# 删除旧版
if [ -d "$DEST" ]; then
    rm -rf "$DEST"
    echo "[DocuLite][install] 已删除旧版 $DEST"
fi

# 拷贝新版
cp -R "$APP" "$DEST"
echo "[DocuLite][install] 已安装新版到 $DEST"

# 清掉扩展属性，避免 Gatekeeper/隔离标记干扰本地使用
xattr -cr "$DEST" 2>/dev/null || true

# 重新做 ad-hoc 代码签名（拷贝后签名校验会失效导致 launchd 拒载），
# 并登记到 LaunchServices，使 Finder「打开」走新构建。
if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$DEST" || echo "[DocuLite][install] 警告：重签名失败，App 可能无法打开"
fi

# 让 LaunchServices 重新指向新 app（清掉旧缓存登记），避免「打开旧版/无法打开」
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREG" ]; then
    "$LSREG" -f "$DEST" 2>/dev/null || true
    "$LSREG" -kill -r 2>/dev/null || true
fi

# 让 LaunchServices 重新登记新 app（可选，失败不影响主流程）
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" 2>/dev/null || true
