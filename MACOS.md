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
4. 点「注入测试音」：打开 **系统设置 → 声音 → 输入 → BlackHole 2ch**，电平应跳动
5. Typeless：麦克风选 **BlackHole 2ch**；若列表里没有，把系统输入默认改成 BlackHole，Typeless 选「自动检测」，并**完全退出后重开** Typeless

**系统「设置 → 声音 → 输出」不要选 BlackHole**，否则喇叭没声；只在「输入」和 App 麦克风里选。

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
| 系统 BlackHole 输入电平不动 | 换 v1.4.3+；开虚拟麦后点「注入测试音」；调试行应有 `render` 增长、`underrun` 不暴涨 |
| Typeless 列表无 BlackHole | 常见：Typeless 不列虚拟设备 → 系统输入默认选 BlackHole + Typeless「自动检测」+ 重启 Typeless |
| Typeless 无波形 | 先确认系统 BlackHole 电平会动，再查 Typeless 输入 |
| 电脑没声音 | 系统输出改回扬声器/耳机 |
| 打不开 App | 右键 → 打开；隐私与安全性 → 仍要打开 |
| 连不上豆 | 退出飞书 / Soundcore Manager 后再扫描 |
