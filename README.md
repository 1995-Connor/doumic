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

## 与 Soundcore Manager 共存

本应用使用独立包名 **`com.doumic.app`** 与独立签名证书，可与官方/社区 Soundcore Manager（`com.anker.anker_recorder`）同时安装。

## 安装 APK

预编译：[`releases/doumai-release.apk`](releases/doumai-release.apk)

```bash
flutter pub get
flutter build apk --release
cp build/app/outputs/flutter-apk/app-release.apk releases/doumai-release.apk
```

## 使用步骤

### 1. 安装并启动 Shizuku（配对 ≠ 启动）

1. 安装 [Shizuku](https://shizuku.rikka.app/zh-hans/guide/setup/)
2. 打开开发者选项：设置 → 关于手机 → 连续点版本号 7 次；打开 **USB 调试** 和 **无线调试**  
   （小米/红米还需打开 **USB 调试（安全设置）**）
3. **配对（通常只需一次）**  
   - 打开 Shizuku → 通过无线调试 → 点「配对」→ 允许通知  
   - 系统「无线调试」→「使用配对码配对设备」  
   - 把 6 位码填进 Shizuku 通知，看到「配对成功」
4. **启动（每次重启手机后都要再点）**  
   - 在 Shizuku 点「启动」，等到顶部显示「Shizuku 正在运行」  
   - 只配对、不启动，豆麦这边无法开虚拟麦

### 2. 豆麦

1. 安装豆麦 APK，授予蓝牙权限，连接录音豆（先退出飞书等占用设备的 App）
2. 打开 **豆麦** Tab → **授权豆麦** → 打开「系统虚拟麦克风」
3. 保持豆麦在后台（常驻通知）
4. 正常使用原来的语音输入法或会议开麦，无需切换输入法

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
