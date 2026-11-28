# 豆麦 · macOS（系统级虚拟麦克风）

把安克 AI 录音豆（D3200）的声音送到 **BlackHole**，Typeless / Zoom 等把麦克风选成 BlackHole 即可。

```text
录音豆 (BLE Opus) → 豆麦.app → BlackHole 2ch → Typeless / Zoom
```

## 推荐：安装 DMG

1. 下载 [`releases/doumai-macos.dmg`](releases/doumai-macos.dmg)  
   （若仓库里还没有该文件：等 GitHub Actions「macOS DMG」跑完，或在自己 Mac 上按下方「本地打包」生成）
2. 打开 DMG：
   - 先看「使用说明.txt」
   - 双击「安装 BlackHole.command」或按说明安装 **BlackHole 2ch**（只需一次）
   - 把 **豆麦.app** 拖到 **Applications**
3. 首次打开：右键 → 打开（未签名会提示一次）→ 允许蓝牙
4. 豆麦连上录音豆 → 打开「系统虚拟麦克风」
5. Typeless 麦克风选 **BlackHole 2ch**，对着豆说话

**系统「声音 → 输出」不要选 BlackHole**，否则喇叭没声；只在 Typeless 的输入里选。

## 本地运行 / 打包

需要本机 Xcode + Flutter。

```bash
flutter pub get
flutter run -d macos

# 打 DMG：
flutter build macos --release
chmod +x macos/packaging/create_dmg.sh
macos/packaging/create_dmg.sh
# → releases/doumai-macos.dmg
```

GitHub Actions（`.github/workflows/macos-dmg.yml`）在 push 到 `main` 且改到 macOS 相关文件时会自动构建，也可在 Actions 页手动 **Run workflow**，产物名 `doumai-macos-dmg`。

## 故障排除

| 现象 | 处理 |
|---|---|
| 提示未找到 BlackHole | 安装 2ch，打开「音频 MIDI 设置」确认 |
| Typeless 无波形 | 确认输入是 BlackHole，且豆麦虚拟麦已开、电平在跳 |
| 电脑没声音 | 系统输出被改成了 BlackHole，改回扬声器 |
| 打不开 App | 右键 → 打开；系统设置 → 隐私与安全性 → 仍要打开 |
| 连不上豆 | 退出飞书 / Soundcore Manager 后再扫描 |
