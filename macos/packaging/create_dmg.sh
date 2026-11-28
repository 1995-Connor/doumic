#!/usr/bin/env bash
# Build a distributable DMG on macOS after `flutter build macos --release`.
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

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: create_dmg.sh must run on macOS" >&2
  exit 1
fi

if [[ ! -d "${APP_PATH}" ]]; then
  echo "error: missing ${APP_PATH}" >&2
  echo "run: flutter build macos --release" >&2
  exit 1
fi

# Ad-hoc sign so Gatekeeper is slightly less angry on fresh machines.
codesign --force --deep --sign - "${APP_PATH}" || true

rm -rf "${STAGE}"
mkdir -p "${STAGE}" "${OUT_DIR}"
cp -R "${APP_PATH}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"

cat > "${STAGE}/使用说明.txt" <<EOF
豆麦 macOS ${VERSION}
====================

作用：把安克 AI 录音豆（D3200）的声音送到系统虚拟麦克风，供 Typeless / Zoom 等选用。

首次使用（只需一次）
--------------------
1. 安装 BlackHole 2ch 虚拟声卡（豆麦依赖它才能出现「系统麦」）
   - 双击「安装 BlackHole.command」，或浏览器打开：
     https://existential.audio/blackhole/
   - 装完后打开「音频 MIDI 设置」，应能看到 BlackHole 2ch

2. 把「豆麦.app」拖到「Applications」文件夹

3. 首次打开：若提示无法验证开发者 → 右键 App → 打开 → 仍要打开
   并允许「蓝牙」权限

日常使用
--------
1. 退出飞书 / Soundcore Manager 等占用录音豆的 App
2. 打开豆麦 → 扫描连接录音豆 → 打开「系统虚拟麦克风」
3. Typeless / 会议软件：麦克风选「BlackHole 2ch」
4. 对着录音豆说话；也可在豆麦里点「注入测试音」验证

注意
----
- 系统「设置 → 声音 → 输出」不要选 BlackHole，否则电脑喇叭没声
- 只在 Typeless 等 App 的「输入/麦克风」里选 BlackHole
EOF

cat > "${STAGE}/安装 BlackHole.command" <<'EOF'
#!/bin/bash
cd "$(dirname "$0")"
echo "正在打开 BlackHole 官网下载页（请安装 2ch 版本）…"
open "https://existential.audio/blackhole/"
if command -v brew >/dev/null 2>&1; then
  echo
  echo "检测到 Homebrew。也可以在终端执行："
  echo "  brew install blackhole-2ch"
fi
echo
read -n 1 -s -r -p "按任意键关闭…"
EOF
chmod +x "${STAGE}/安装 BlackHole.command"

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
