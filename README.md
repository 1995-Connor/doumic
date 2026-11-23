# 豆麦 · 安克录音豆系统麦克风

基于 [tacshi/Soundcore](https://github.com/tacshi/Soundcore) 的 D3200 BLE 协议，把 **soundcore Work（安克 AI 录音豆）** 变成 Android **系统麦克风**。

开启后：

- 搜狗 / 讯飞 / 系统语音输入 → 采录音豆
- 腾讯会议 / Zoom / 飞书开会开麦 → 采录音豆

## 原理与限制

录音豆通过 BLE 传 Opus，**不是**经典蓝牙 HFP 耳机，系统不会自动把它当成麦克风。

Android 也不允许普通 App 注册虚拟麦。豆麦用 **Shizuku（无线调试，无需 Root）** 以 shell 权限注册 `AudioPolicy` LOOP_BACK 注入轨，把解密后的 PCM 写进系统采集通路（覆盖 `MIC` / `VOICE_RECOGNITION` / `VOICE_COMMUNICATION` 等）。

| 条件 | 要求 |
|------|------|
| 系统 | **Android 13+** |
| 权限 | **Shizuku**（每次重启后需重新启动） |
| 设备 | 需兼容动态 AudioPolicy（多数 AOSP/接近 AOSP 的 ROM） |

## 安装 APK

预编译：[`releases/doumai-release.apk`](releases/doumai-release.apk)

```bash
flutter pub get
flutter build apk --release
cp build/app/outputs/flutter-apk/app-release.apk releases/doumai-release.apk
```

## 使用步骤

1. 安装 **Shizuku**，用「无线调试」启动，并保持运行
2. 安装豆麦 APK，授予蓝牙权限，连接录音豆（先退出飞书等占用设备的 App）
3. 打开 **豆麦** Tab → **授权 Shizuku** → 打开「系统虚拟麦克风」
4. 保持豆麦在后台（常驻通知）
5. 正常使用原来的语音输入法或会议开麦，无需切换输入法

## 项目结构

```
lib/mic/           # Flutter ↔ 原生桥（PCM 推送）
android/.../
  VirtualMicEngine.kt       # AudioPolicy 注入（系统麦）
  VirtualMicUserService.kt  # Shizuku shell 进程
  VirtualMicController.kt   # 绑定 / 状态
  BeanMicImeService.kt      # 备用输入法（非主路径）
```

协议细节见 [`PROTOCOL.md`](PROTOCOL.md)。上游：[tacshi/Soundcore](https://github.com/tacshi/Soundcore)。虚拟麦注入思路参考 VirtuMic / AOSP AudioPolicy（MIT）。

## 许可证

[MIT License](LICENSE)。与 Anker / 飞书无关。
