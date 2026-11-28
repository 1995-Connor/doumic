#!/usr/bin/env bash
# Build a distributable DMG on macOS after `flutter build macos --release`.
# Bundles BlackHole 2ch .pkg so users get a one-shot virtual-mic install
# (same pattern as many Mac voice apps that ship a HAL driver beside the app).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_NAME="豆麦"
BUILD_DIR="${ROOT}/build/macos/Build/Products/Release"
APP_PATH="${BUILD_DIR}/${APP_NAME}.app"
OUT_DIR="${ROOT}/releases"
STAGE="${ROOT}/build/dmg-stage"
VOL="${APP_NAME}"
DMG_NAME="doumai-macos.dmg"
VERSION="$(grep '^version:' "${ROOT}/pubspec.yaml" | head -1 | awk '{print $2}' | cut -d+ -f1)"

BLACKHOLE_VERSION="${BLACKHOLE_VERSION:-0.7.1}"
BLACKHOLE_PKG_NAME="BlackHole2ch-${BLACKHOLE_VERSION}.pkg"
BLACKHOLE_URL="${BLACKHOLE_URL:-https://existential.audio/downloads/${BLACKHOLE_PKG_NAME}}"
BLACKHOLE_CACHE="${ROOT}/build/vendor/${BLACKHOLE_PKG_NAME}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: create_dmg.sh must run on macOS" >&2
  exit 1
fi

if [[ ! -d "${APP_PATH}" ]]; then
  echo "error: missing ${APP_PATH}" >&2
  echo "run: flutter build macos --release" >&2
  exit 1
fi

mkdir -p "${ROOT}/build/vendor" "${OUT_DIR}"
if [[ ! -f "${BLACKHOLE_CACHE}" ]]; then
  echo "Downloading ${BLACKHOLE_PKG_NAME} …"
  curl -fL --retry 3 --retry-delay 2 -o "${BLACKHOLE_CACHE}.partial" "${BLACKHOLE_URL}"
  mv "${BLACKHOLE_CACHE}.partial" "${BLACKHOLE_CACHE}"
fi
ls -lh "${BLACKHOLE_CACHE}"

# Ad-hoc sign so Gatekeeper is slightly less angry on fresh machines.
codesign --force --deep --sign - "${APP_PATH}" || true

rm -rf "${STAGE}"
mkdir -p "${STAGE}"
cp -R "${APP_PATH}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"
cp "${BLACKHOLE_CACHE}" "${STAGE}/${BLACKHOLE_PKG_NAME}"

# GPL-3.0 notice for redistributed BlackHole binary package.
cat > "${STAGE}/BlackHole-LICENSE.txt" <<EOF
BlackHole 2ch (virtual audio driver) is © Existential Audio Inc.
License: GNU GPL v3 — https://github.com/ExistentialAudio/BlackHole
Source code: https://github.com/ExistentialAudio/BlackHole
This DMG redistributes the official BlackHole2ch installer package so 豆麦
can appear as a system microphone. BlackHole is a separate program from 豆麦.
EOF

cat > "${STAGE}/使用说明.txt" <<EOF
豆麦 macOS ${VERSION}
====================

把安克 AI 录音豆变成系统麦克风（供 Typeless / Zoom 等选用）。

推荐：双击「一键安装.command」
--------------------------------
会依次：
1. 安装 BlackHole 2ch 虚拟声卡（需输入一次 Mac 密码）
2. 把「豆麦.app」拷到「应用程序」

装完后打开豆麦 → 连接录音豆 → 打开虚拟麦 →
在 Typeless 里把麦克风选成「BlackHole 2ch」。

手动安装
--------
1. 双击 ${BLACKHOLE_PKG_NAME} 安装虚拟声卡
2. 把「豆麦.app」拖到 Applications
3. 首次打开：右键 → 打开（未签名会提示一次）→ 允许蓝牙

注意
----
- 系统「设置 → 声音 → 输出」不要选 BlackHole，否则喇叭没声
- 只在 Typeless 等 App 的「输入/麦克风」里选 BlackHole
- BlackHole 许可见 BlackHole-LICENSE.txt（GPL-3.0）
EOF

cat > "${STAGE}/一键安装.command" <<'EOF'
#!/bin/bash
set -e
cd "$(dirname "$0")"
APP_SRC="豆麦.app"
PKG="$(ls -1 BlackHole2ch-*.pkg 2>/dev/null | head -1 || true)"

echo "========================================"
echo " 豆麦一键安装"
echo "========================================"
echo
echo "将安装："
echo "  1) BlackHole 2ch 虚拟声卡（系统麦克风）"
echo "  2) 豆麦.app → /Applications"
echo
echo "安装驱动需要管理员密码（系统会弹窗）。"
echo

if [[ -z "$PKG" || ! -f "$PKG" ]]; then
  echo "错误：找不到 BlackHole2ch-*.pkg"
  read -n 1 -s -r -p "按任意键关闭…"
  exit 1
fi

PKG_ABS="$(pwd)/$PKG"
osascript -e "do shell script \"installer -pkg \\\"${PKG_ABS}\\\" -target /\" with administrator privileges"
echo "✓ BlackHole 2ch 已安装"

echo "正在复制豆麦到「应用程序」…"
rm -rf "/Applications/豆麦.app"
cp -R "$APP_SRC" "/Applications/豆麦.app"
xattr -dr com.apple.quarantine "/Applications/豆麦.app" 2>/dev/null || true
echo "✓ 豆麦.app 已安装到 /Applications"

echo "正在刷新音频服务…"
osascript -e 'do shell script "killall coreaudiod" with administrator privileges' 2>/dev/null || true
sleep 1

echo
echo "完成。接下来："
echo "  1. 打开「豆麦」"
echo "  2. 允许蓝牙，连接录音豆，打开虚拟麦克风"
echo "  3. Typeless 麦克风选 BlackHole 2ch"
echo
echo "提示：系统声音「输出」不要选 BlackHole。"
echo
open -R "/Applications/豆麦.app" 2>/dev/null || true
read -n 1 -s -r -p "按任意键关闭…"
EOF
chmod +x "${STAGE}/一键安装.command"

TMP_DMG="${OUT_DIR}/.${DMG_NAME}.tmp.dmg"
FINAL_DMG="${OUT_DIR}/${DMG_NAME}"
rm -f "${TMP_DMG}" "${FINAL_DMG}"

hdiutil create \
  -volname "${VOL}" \
  -srcfolder "${STAGE}" \
  -ov -format UDRW \
  "${TMP_DMG}"

hdiutil convert "${TMP_DMG}" -format ULMO -o "${FINAL_DMG}"
rm -f "${TMP_DMG}"
rm -rf "${STAGE}"

echo "OK: ${FINAL_DMG}"
ls -lh "${FINAL_DMG}"
