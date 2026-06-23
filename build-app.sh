#!/bin/bash
# 编译 VideoGrab，下载并打包 yt-dlp + ffmpeg 内核，组装成纯菜单栏 .app（LSUIElement）
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="VideoGrab"
CONFIG="release"
BUILD_DIR=".build/${CONFIG}"
APP_BUNDLE="${APP_NAME}.app"
BIN_DIR="Resources/bin"

YTDLP_URL="https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos"
# 单文件静态 ffmpeg（Apple Silicon），来自 ffmpeg-static 发布页
FFMPEG_URL="https://github.com/eugeneware/ffmpeg-static/releases/download/b6.0/ffmpeg-darwin-arm64"

echo "==> 准备下载内核到 ${BIN_DIR}"
mkdir -p "${BIN_DIR}"

if [ ! -f "${BIN_DIR}/yt-dlp" ]; then
    echo "    下载 yt-dlp…"
    curl -fL --retry 3 -o "${BIN_DIR}/yt-dlp" "${YTDLP_URL}"
    chmod +x "${BIN_DIR}/yt-dlp"
else
    echo "    yt-dlp 已存在，跳过（如需升级用 App 内「更新内核」）"
fi

if [ ! -f "${BIN_DIR}/ffmpeg" ]; then
    echo "    下载 ffmpeg…"
    curl -fL --retry 3 -o "${BIN_DIR}/ffmpeg" "${FFMPEG_URL}"
    chmod +x "${BIN_DIR}/ffmpeg"
else
    echo "    ffmpeg 已存在，跳过"
fi

# 去除可能的隔离属性
xattr -dr com.apple.quarantine "${BIN_DIR}" 2>/dev/null || true

echo "==> 编译（${CONFIG}）"
swift build -c "${CONFIG}"

echo "==> 组装 ${APP_BUNDLE}"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources/bin"

cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "${BIN_DIR}/yt-dlp"  "${APP_BUNDLE}/Contents/Resources/bin/yt-dlp"
cp "${BIN_DIR}/ffmpeg"  "${APP_BUNDLE}/Contents/Resources/bin/ffmpeg"
chmod +x "${APP_BUNDLE}/Contents/Resources/bin/"*

# 可选图标
ICON_SRC="Assets/AppIcon.png"
if [ -f "${ICON_SRC}" ]; then
    echo "==> 生成应用图标"
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "${ICONSET}"
    for size in 16 32 64 128 256 512; do
        sips -z "${size}" "${size}"         "${ICON_SRC}" --out "${ICONSET}/icon_${size}x${size}.png"   >/dev/null
        sips -z "$((size*2))" "$((size*2))" "${ICON_SRC}" --out "${ICONSET}/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "${ICONSET}" -o "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
    rm -rf "$(dirname "${ICONSET}")"
fi

cat > "${APP_BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.${APP_NAME}</string>
    <key>CFBundleVersion</key>
    <string>2.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>2.0.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> 本地签名（ad-hoc）"
codesign --force --deep --sign - "${APP_BUNDLE}" 2>/dev/null || echo "   跳过签名（不影响本机运行）"

echo "==> 完成：${PWD}/${APP_BUNDLE}"
echo "   运行： open ${APP_BUNDLE}"
echo "   安装： cp -r ${APP_BUNDLE} /Applications/"
