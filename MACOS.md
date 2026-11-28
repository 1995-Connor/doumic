# 豆麦 · macOS（系统级虚拟麦克风）

```text
录音豆 (BLE Opus) → 豆麦.app → BlackHole 2ch → Typeless / Zoom
```

和其他能「装完就能语音输入」的 Mac 应用一样：虚拟声卡驱动和 App **打在同一个 DMG 里**，一键安装。

## 安装（推荐）

1. 下载 [`releases/doumai-macos.dmg`](releases/doumai-macos.dmg)
2. 打开 DMG，双击 **「一键安装.command」**
   - 会安装 **BlackHole 2ch**（需输入一次 Mac 密码）
   - 并把 **豆麦.app** 拷到「应用程序」
3. 打开豆麦 → 允许蓝牙 → 连接录音豆 → 打开「系统虚拟麦克风」
4. Typeless 麦克风选 **BlackHole 2ch**，对着豆说话

**系统「设置 → 声音 → 输出」不要选 BlackHole**，否则喇叭没声；只在 Typeless 的输入里选。

DMG 内也带官方 `BlackHole2ch-*.pkg`（GPL-3.0，见盘内 `BlackHole-LICENSE.txt`），可手动双击安装。

## 本地打包

需要本机 Xcode + Flutter：

```bash
flutter pub get
flutter build macos --release
chmod +x macos/packaging/create_dmg.sh
macos/packaging/create_dmg.sh
# → releases/doumai-macos.dmg（已含 BlackHole 安装包）
```

CI：`.github/workflows/macos-dmg.yml`（push / 手动触发）。

## 故障排除

| 现象 | 处理 |
|---|---|
| 一键安装要密码 | 正常，装系统音频驱动必须管理员权限 |
| Typeless 无波形 | 确认输入是 BlackHole，豆麦虚拟麦已开 |
| 电脑没声音 | 系统输出改回扬声器/耳机 |
| 打不开 App | 右键 → 打开；隐私与安全性 → 仍要打开 |
| 连不上豆 | 退出飞书 / Soundcore Manager 后再扫描 |
