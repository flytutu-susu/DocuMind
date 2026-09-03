#!/bin/bash
# 构建 DocuMind.app（无需 Xcode，只需要 Xcode Command Line Tools / Swift 工具链）
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="DocuMind"
BUILD_DIR=".build/release"
APP_DIR="dist/${APP_NAME}.app"

echo "==> swift build -c release"
swift build -c release

echo "==> 组装 ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BUILD_DIR}/${APP_NAME}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp "Info.plist" "${APP_DIR}/Contents/Info.plist"

# 资源（如应用图标）可选
if [ -d "Resources" ]; then
  cp -R Resources/ "${APP_DIR}/Contents/Resources/" 2>/dev/null || true
fi

# 本地 ad-hoc 签名，避免 Gatekeeper 直接拦截本机运行
codesign --force --deep --sign - "${APP_DIR}" || true

echo "==> 完成: ${APP_DIR}"
echo "    双击运行，或执行: open ${APP_DIR}"
