# 豆麦 · macOS 演示（系统级虚拟麦克风）

在 Mac 上可以真正演示「录音豆 → 任意 App 麦克风」：通过 **BlackHole** 虚拟声卡。  
Typeless / Zoom / 系统听写把输入选成 BlackHole 后，就会听到录音豆。

```text
录音豆 (BLE Opus) → 豆麦 App → BlackHole 2ch → Typeless / Zoom / …
```

## 1. 安装 BlackHole

```bash
brew install blackhole-2ch
```

或官网：https://existential.audio/blackhole/

装完后打开 **音频 MIDI 设置**，应能看到 **BlackHole 2ch**。

> 不要把系统「输出」设成 BlackHole，否则电脑喇叭会没声。  
> 只在 **Typeless / 会议 App 的麦克风输入** 里选 BlackHole。

## 2. 编译运行豆麦（Mac）

在本仓库根目录（需要本机 Xcode）：

```bash
flutter pub get
flutter run -d macos
# 或打包：
flutter build macos --release
# App 位于 build/macos/Build/Products/Release/豆麦.app
```

首次运行允许 **蓝牙** 权限。

## 3. 演示步骤

1. 豆麦：扫描并连接录音豆（退出飞书等占用设备的 App）
2. 确认界面显示「已检测到虚拟声卡（BlackHole）」
3. 打开「系统虚拟麦克风」开关
4. Typeless：麦克风选 **BlackHole 2ch**，开始语音输入
5. 对着录音豆说话 → Typeless 波形应跳动

可选：豆麦里点「注入测试音」——不用说话，Typeless（已选 BlackHole）波形应跳一下。

## 4. 和 Android 的区别

| | macOS | Android |
|---|---|---|
| 虚拟麦 | BlackHole 等 HAL 驱动，系统官方支持选输入 | 无普通权限虚拟声卡；只能特权 AudioPolicy 注入 |
| Typeless | 可选 BlackHole，**可以演示通** | 多数国产 ROM 仍读手机麦 |
| 蓝牙列表 | 同样不会出现录音豆（BLE ≠ HFP） | 同左 |

## 故障排除

- **开虚拟麦提示未找到 BlackHole**：确认已安装并重启「音频 MIDI 设置」/注销一次
- **Typeless 无波形**：确认 Typeless 输入是 BlackHole，且豆麦开关已开、电平在跳
- **电脑没声音了**：系统输出被改成了 BlackHole，改回扬声器/耳机
- **连不上豆**：退出飞书 / Soundcore Manager，再在豆麦里扫描
