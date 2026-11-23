# 豆麦

把 **安克 AI 录音豆（soundcore Work / D3200）** 变成 Android **系统麦克风** 的独立小工具。

只做一件事：连接录音豆 → 实时收音 → 注入手机麦克风通路。  
**不是** Soundcore Manager，没有录音库、转写、文件导出。

开启后：

- 搜狗 / 讯飞 / 系统语音输入 → 采录音豆
- 腾讯会议 / Zoom / 飞书开会开麦 → 采录音豆

## 与 Soundcore Manager 共存

| | Soundcore Manager | 豆麦 |
|---|---|---|
| 包名 | `com.anker.anker_recorder` | **`com.doumic.app`** |
| 签名 | 上游证书 | 独立 DouMic 证书 |
| 功能 | 录音管理 / 转写 / 导出 | 仅系统虚拟麦克风 |

两者可同时安装。

## 要求

- Android 13+
- [Shizuku](https://shizuku.rikka.app/zh-hans/guide/setup/)（无线调试，无需 Root）

## 安装

[`releases/doumai-release.apk`](releases/doumai-release.apk)

```bash
flutter pub get
flutter build apk --release
cp build/app/outputs/flutter-apk/app-release.apk releases/doumai-release.apk
```

## 使用

### 1. Shizuku（配对 ≠ 启动）

1. 安装 Shizuku；打开开发者选项里的 **USB 调试** + **无线调试**  
   （小米/红米再开 **USB 调试（安全设置）**）
2. **配对**（通常一次）：Shizuku → 配对 → 系统「配对码」填进通知  
3. **启动**（每次重启后都要）：Shizuku → 启动 → 显示「正在运行」

### 2. 豆麦

1. 连接录音豆（先退出飞书等占用设备的 App）  
2. **授权豆麦** → 打开「系统虚拟麦克风」  
3. 保持后台，直接用原来的语音键 / 会议开麦  

设备指示灯亮起只表示正在向手机推流；本 App **不保存录音文件**。

## 原理

录音豆走 BLE Opus，不是经典蓝牙 HFP。豆麦用 Shizuku 以 shell 权限注册 `AudioPolicy` 注入轨，把 PCM 写进系统 `MIC` / `VOICE_RECOGNITION` / `VOICE_COMMUNICATION` 采集通路。

协议来自社区逆向：[tacshi/Soundcore](https://github.com/tacshi/Soundcore)。详见 [`PROTOCOL.md`](PROTOCOL.md)。

## 许可证

[MIT License](LICENSE)
