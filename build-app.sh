#!/bin/bash
# 编译 VideoGrab，下载并打包 yt-dlp + ffmpeg 内核，组装成纯菜单栏 .app（LSUIElement）
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="VideoGrab"
APP_VERSION="2.5.1"   # 应用版本：同时写入 Info.plist 的两个版本字段；发版打 tag 时与此保持一致
CONFIG="release"
BUILD_DIR=".build/${CONFIG}"
APP_BUNDLE="${APP_NAME}.app"
BIN_DIR="Resources/bin"

# 内核版本与 sha256 指纹锁定：保证每次构建拿到完全相同、未被篡改的二进制。
# 升级时改版本号；指纹取 GitHub release 页 asset 的 digest 字段（或下载后 shasum -a 256 现算）。
YTDLP_VERSION="2026.08.19"
YTDLP_SHA256="0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202"
FFMPEG_VERSION="b6.0"   # 单文件静态 ffmpeg（Apple Silicon），来自 ffmpeg-static 发布页
FFMPEG_SHA256="a90e3db6a3fd35f6074b013f948b1aa45b31c6375489d39e572bea3f18336584"

YTDLP_URL="https://github.com/yt-dlp/yt-dlp/releases/download/${YTDLP_VERSION}/yt-dlp_macos"
FFMPEG_URL="https://github.com/eugeneware/ffmpeg-static/releases/download/${FFMPEG_VERSION}/ffmpeg-darwin-arm64"

echo "==> 准备下载内核到 ${BIN_DIR}"
mkdir -p "${BIN_DIR}"

# 校验并按需下载：已有文件指纹不符（半截下载/被改动）也会重新拉取
fetch_kernel() {
    local name="$1" url="$2" want="$3" dest="$4"
    if [ -f "${dest}" ]; then
        if echo "${want}  ${dest}" | shasum -a 256 -c - >/dev/null 2>&1; then
            echo "    ${name} 已存在且指纹匹配，跳过"
            return 0
        fi
        echo "    ${name} 已存在但指纹不符，重新下载…"
        rm -f "${dest}"
    fi
    echo "    下载 ${name}…"
    curl -fL --retry 3 -o "${dest}" "${url}"
    echo "${want}  ${dest}" | shasum -a 256 -c -   # 指纹不符会非零退出，set -e 直接终止构建
    chmod +x "${dest}"
}

fetch_kernel "yt-dlp" "${YTDLP_URL}" "${YTDLP_SHA256}" "${BIN_DIR}/yt-dlp"
fetch_kernel "ffmpeg" "${FFMPEG_URL}" "${FFMPEG_SHA256}" "${BIN_DIR}/ffmpeg"

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
    <string>${APP_VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
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
