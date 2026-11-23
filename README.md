# 豆麦

把 **安克 AI 录音豆（soundcore Work / D3200）** 变成 Android **系统麦克风** 的独立小工具。

只做一件事：连接录音豆 → 实时收音 → 注入手机麦克风通路。  
**不是** Soundcore Manager，没有录音库、转写、文件导出。

目标：

- 搜狗 / 讯飞 / Typeless / 系统语音 → 采录音豆
- 腾讯会议 / Zoom / 飞书开会开麦 → 采录音豆

**重要限制（请先读）**：Android **不允许**普通 App 把自己注册成「系统麦克风」。豆麦走的是 Shizuku/shell 的 `AudioPolicy` 注入（和 VirtuMic 同类），在接近 AOSP 的机器上可以冒充内置麦；在大量国产 ROM（小米 HyperOS、OPPO/vivo 等）上，厂商改过音频策略，**注册成功也不一定会替换硬件麦**——这时 Typeless 波形不会跳，蓝牙列表里也不会出现录音豆。这不是安装错了，而是系统层没放行。

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

Release APK 仅含 **arm64-v8a**（近些年手机都是这个架构）。体积主要来自 Flutter 引擎本身，与业务功能多少关系不大。


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
4. 要换设备或解除占用：点「解绑设备」（在线发解绑指令；离线则清本机绑定）  

设备指示灯亮起只表示正在向手机推流；本 App **不保存录音文件**。

### Typeless 波形不跳？

1. 豆麦电平能动，只说明「豆 → 豆麦」通了。  
2. 点「本机回采自检」：失败 = 这台 ROM 没把注入当成系统麦，Typeless 也必然听不到。  
3. 蓝牙设置里看不到录音豆是正常的——它是 BLE 传 Opus，不是经典蓝牙通话麦（HFP）。

市面上「能当系统麦」的第三方麦，通常是下面几类之一，**都不是**普通 App 权限能做的事：

| 类型 | 例子 | 系统怎么认 |
|---|---|---|
| 经典蓝牙通话麦 | 蓝牙耳机 HFP | 系统蓝牙协议栈挂上真正的 mic 设备 |
| USB 声卡麦 | USB 麦克风 | USB Audio 设备节点 |
| 特权虚拟麦 | VirtuMic（ADB/Magisk） | shell/root 注册 AudioPolicy（和豆麦同路，依赖 ROM） |
| App 内自用 | 飞书 / Soundcore Manager | 只在自己 App 里收 BLE，**不**替换系统麦 |

录音豆属于 BLE 配件，官方也是「App 内收音」，不是 HFP 耳机。

## 原理

录音豆走 BLE Opus。豆麦用 Shizuku 以 shell 权限注册 `AudioPolicy` 注入轨，尝试把 PCM 写进 `MIC` / `VOICE_RECOGNITION` / `VOICE_COMMUNICATION`。若厂商 AudioPolicy 忽略动态注入，这条路在这台手机上就走不通；可选后续：Magisk 系统级模块、或做「豆麦输入法」在输入法进程内直接用豆（不再经过系统麦，也就不能驱动 Typeless）。

协议来自社区逆向：[tacshi/Soundcore](https://github.com/tacshi/Soundcore)。详见 [`PROTOCOL.md`](PROTOCOL.md)。

## 许可证

[MIT License](LICENSE)
