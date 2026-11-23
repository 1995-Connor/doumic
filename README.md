# 豆麦 · 安克录音豆蓝牙麦克风

基于 [tacshi/Soundcore](https://github.com/tacshi/Soundcore) 的 D3200 BLE 协议，把 **soundcore Work（安克 AI 录音豆）** 变成 Android 上可用的语音输入麦克风。

## 为什么需要「豆麦输入法」

录音豆通过 **BLE GATT** 传输加密 Opus 音频，**不是**经典蓝牙 HFP 耳机。Android 不允许普通 App 把自定义音频注册成系统麦克风（需要 Root / 系统权限）。

因此本应用提供：

1. **麦克风桥接**：连接录音豆 → 实时解密 Opus → PCM16（16 kHz）
2. **豆麦输入法**：在任意输入框切换到该输入法，按住说话，用录音豆收音并上屏

这样微信、备忘录、浏览器等 App 里的「语音输入」需求，可以通过切换输入法实现，收音来自录音豆而不是手机麦。

## 快速开始（Android APK）

1. 安装 `releases/doumai-release.apk`（或自行 `flutter build apk`）
2. 打开 **豆麦**，授予蓝牙 / 定位权限，扫描并连接录音豆  
   （请先退出飞书或其他占用该设备的 App）
3. 进入 **豆麦** Tab，打开「麦克风桥接」
4. 系统设置 → 键盘 / 输入法 → 启用 **豆麦输入法**
5. 在任意输入框切换到豆麦，按住麦克风键说话
6. 在 **设置** 中配置 **Soniox API Key**，并保持自动转写开启（听写上屏依赖实时转写）

预编译 APK 路径：`releases/doumai-release.apk`

## 支持平台

| 平台 | 状态 |
|------|------|
| Android | BLE + 豆麦输入法 + 麦克风桥接（本仓库重点） |
| iOS / macOS | 上游 Soundcore Manager 能力仍保留 |

## 功能一览

- **豆麦**：麦克风桥接开关、实时电平、输入法设置入口
- **首页**：本地与设备端录音浏览、播放、转写详情
- **设备**：电量、录音控制、配对 / 解绑
- **设置**：Soniox API Key、语言、自动转写
- **Wi‑Fi SoftAP 批量导出**（上游能力）

## 本地构建 APK

```bash
flutter pub get
flutter build apk --release
# 产物：build/app/outputs/flutter-apk/app-release.apk
mkdir -p dist && cp build/app/outputs/flutter-apk/app-release.apk releases/doumai-release.apk
```

## 项目结构

```
lib/
├── mic/         # 麦克风桥接（PCM → Android IME）
├── ai/          # Soniox 等实时转写
├── audio/       # Opus → PCM
├── ble/         # D3200 BLE / 实时流
├── crypto/      # ECDH / AES
├── protocol/    # 帧与命令字
└── ui/          # 首页 / 豆麦 / 设备 / 设置
android/.../BeanMicImeService.kt   # 豆麦输入法
```

协议细节见 [`PROTOCOL.md`](PROTOCOL.md)。上游项目：[tacshi/Soundcore](https://github.com/tacshi/Soundcore)。

## 许可证

基于 [MIT License](LICENSE)。协议逆向研究来自社区，与 Anker / 飞书无关。
