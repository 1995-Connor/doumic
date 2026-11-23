import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../mic/mic_bridge.dart';
import '../../platform/background_sync_service.dart';
import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/scan_sheet.dart';

/// Standalone DouMic home: connect D3200 → system virtual microphone.
///
/// This is intentionally not a recording manager. Device "record" is only used
/// under the hood so the bean starts streaming Opus over BLE.
class MicBridgeScreen extends StatefulWidget {
  const MicBridgeScreen({super.key});

  @override
  State<MicBridgeScreen> createState() => _MicBridgeScreenState();
}

class _MicBridgeScreenState extends State<MicBridgeScreen> {
  @override
  void initState() {
    super.initState();
    MicBridge.instance.ensureInitialized();
  }

  Future<void> _confirmUnbind() async {
    final c = context.read<RecorderController>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgCard,
        title: const Text('确认解绑？'),
        content: Text(
          c.connected
              ? '将向录音豆发送解绑指令。\n'
                  '• 不会清空豆内录音或恢复出厂\n'
                  '• 成功后断开连接并清除本机绑定\n'
                  '• 之后可再扫描、连接'
              : '当前未连上设备，将只清除本机已保存的绑定。\n'
                  '之后可重新扫描连接；若豆仍显示已绑定，连上后再解绑一次。',
          style: const TextStyle(
            color: AppColors.textSecondary,
            height: 1.4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('解绑'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final bridge = MicBridge.instance;
    if (bridge.enabled) await bridge.setEnabled(false);
    if (c.recording) await c.pauseRecord();
    await c.unbindDevice();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(c.statusMessage ?? '已解绑')),
    );
  }

  Future<void> _disconnectOnly() async {
    final c = context.read<RecorderController>();
    final bridge = MicBridge.instance;
    if (bridge.enabled) await bridge.setEnabled(false);
    if (c.recording) await c.pauseRecord();
    await c.disconnect();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已断开（仍保留绑定，可自动重连）')),
    );
  }

  Future<void> _toggleBridge(bool on) async {
    final c = context.read<RecorderController>();
    final bridge = MicBridge.instance;
    if (on) {
      if (!c.connected) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先扫描并连接录音豆')),
        );
        return;
      }
      await bridge.refreshStatus();
      if (bridge.shizuku != 'Shizuku 已就绪') {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '还不能开启虚拟麦：${bridge.shizuku}\n'
              '请先完成 Shizuku「配对 → 启动 → 授权」',
            ),
            duration: const Duration(seconds: 4),
          ),
        );
      }
      await bridge.setEnabled(true);
      await BackgroundSyncService.start();
      // Hardware must be in capture mode to emit realtime Opus frames.
      if (!c.recording) await c.startRecord();
      await bridge.refreshStatus();
      if (!bridge.virtualMicRunning && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(bridge.status)),
        );
      }
    } else {
      await bridge.setEnabled(false);
      if (c.recording) {
        await c.pauseRecord();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final bridge = context.watch<MicBridge>();
    final connected = c.connected;
    final bound = c.bound || c.lastKnownDevice != null || connected;
    final level = bridge.level;
    final shizukuOk = bridge.shizuku == 'Shizuku 已就绪';
    final micOk = bridge.virtualMicRunning;
    final streaming = bridge.enabled && c.recording;

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: [
            const Text(
              '豆麦',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '独立的录音豆系统麦克风。只做一件事：把安克 D3200 的声音接到手机麦克风通路，供语音输入和线上会议使用。',
              style: TextStyle(
                color: AppColors.textSecondary,
                height: 1.45,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 20),
            _Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        connected
                            ? Icons.bluetooth_connected_rounded
                            : Icons.bluetooth_disabled_rounded,
                        color: connected ? AppColors.accent : AppColors.textMuted,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          connected
                              ? (c.activeDevice?.displayName ?? '已连接')
                              : '未连接录音豆',
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () => showScanDevicesSheet(context),
                        child: Text(connected ? '更换' : '扫描连接'),
                      ),
                    ],
                  ),
                  if (c.info != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      '电量 ${c.info!.displayBatteryPercent}% · '
                      '${streaming ? "麦克风推流中" : "待命"}'
                      '${c.bound ? " · 已绑定" : ""}',
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ] else if (bound && !connected) ...[
                    const SizedBox(height: 8),
                    Text(
                      c.bound ? '已绑定（离线）· 可解绑或重新扫描' : '曾连接过此设备',
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ],
                  if (bound) ...[
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        if (connected)
                          OutlinedButton(
                            onPressed: c.phase == AppPhase.busy
                                ? null
                                : _disconnectOnly,
                            child: const Text('断开连接'),
                          ),
                        FilledButton.tonal(
                          onPressed: c.phase == AppPhase.busy
                              ? null
                              : _confirmUnbind,
                          child: const Text('解绑设备'),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            _Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '① Shizuku（配对 → 启动 → 授权）',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '「配对」和「启动」是两步。只配对不算运行；必须看到 Shizuku「正在运行」后才能开麦。',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      height: 1.45,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'A. 开发者选项里打开 USB 调试 + 无线调试\n'
                    '   （小米/红米再开「USB 调试（安全设置）」）\n'
                    'B. Shizuku → 配对 → 系统「配对码」填进通知（通常一次）\n'
                    'C. Shizuku → 启动 → 显示「正在运行」（每次重启都要）\n'
                    'D. 回到豆麦 → 授权豆麦',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      height: 1.5,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Icon(
                        shizukuOk ? Icons.check_circle : Icons.info_outline,
                        size: 18,
                        color: shizukuOk ? AppColors.mint : AppColors.amber,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          bridge.shizuku,
                          style: TextStyle(
                            color: shizukuOk
                                ? AppColors.mint
                                : AppColors.textSecondary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      FilledButton.tonal(
                        onPressed: bridge.openShizukuApp,
                        child: const Text('打开 Shizuku'),
                      ),
                      OutlinedButton(
                        onPressed: bridge.openDeveloperOptions,
                        child: const Text('开发者选项'),
                      ),
                      FilledButton(
                        onPressed: bridge.requestShizukuPermission,
                        child: const Text('授权豆麦'),
                      ),
                      OutlinedButton(
                        onPressed: bridge.refreshStatus,
                        child: const Text('刷新状态'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '② 系统虚拟麦克风',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
                      ),
                      Switch.adaptive(
                        value: bridge.enabled,
                        onChanged: _toggleBridge,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(
                        micOk ? Icons.mic : Icons.mic_off,
                        size: 18,
                        color: micOk ? AppColors.coral : AppColors.textMuted,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          bridge.status,
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: bridge.enabled ? (0.05 + level * 0.95) : 0,
                      minHeight: 10,
                      backgroundColor: AppColors.border,
                      color: level > 0.55 ? AppColors.coral : AppColors.accent,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    bridge.enabled
                        ? '电平 ${(level * 100).round()}% · 增益 ×${bridge.appliedGain.toStringAsFixed(1)} · '
                            '已推送 ${(bridge.pcmBytesForwarded / 1024).toStringAsFixed(1)} KB'
                        : '开启后：录音豆 → 手机系统麦克风',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '麦克风增益（小声优化）',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      Text(
                        bridge.autoGain ? '自动' : '手动',
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                      Switch.adaptive(
                        value: bridge.autoGain,
                        onChanged: bridge.setAutoGain,
                      ),
                    ],
                  ),
                  Text(
                    '录音豆没有手机麦那套系统 AGC。小声时 Typeless 等输入法可能判成「无声」——自动增益会把电平抬到接近手机麦。',
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                  if (!bridge.autoGain) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Text(
                          '×${bridge.manualGain.toStringAsFixed(1)}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                        Expanded(
                          child: Slider(
                            value: bridge.manualGain.clamp(1.0, 16.0),
                            min: 1,
                            max: 16,
                            divisions: 30,
                            label: '×${bridge.manualGain.toStringAsFixed(1)}',
                            onChanged: bridge.setManualGain,
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),
                  FilledButton.tonal(
                    onPressed: (!micOk || bridge.testToneBusy)
                        ? null
                        : () async {
                            await bridge.injectTestTone();
                            if (!mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  '已注入约 1 秒测试音。看 Typeless 波形：跳动=走豆麦；完全不动=仍是手机麦',
                                ),
                                duration: Duration(seconds: 5),
                              ),
                            );
                          },
                    child: Text(
                      bridge.testToneBusy ? '正在注入测试音…' : '注入测试音（验证是否走豆麦）',
                    ),
                  ),
                  if (bridge.lastError != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      bridge.lastError!,
                      style: const TextStyle(
                        color: AppColors.coral,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            _Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '③ 怎么确认走的是豆麦？',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '系统蓝牙里看不到这支麦是正常的：录音豆不是经典蓝牙通话麦，而是豆麦用 Shizuku 把声音「冒充」成手机内置麦克风。\n\n'
                    '验证步骤：\n'
                    '1. 豆麦虚拟麦已开，Typeless 进入语音输入（看到波形条）\n'
                    '2. 用手捂住手机底部麦克风，自己先别说话\n'
                    '3. 回到豆麦点「注入测试音」——Typeless 波形跳一下 = 走豆麦\n'
                    '4. 或：手机放远/捂麦，只对录音豆小声说话；关掉豆麦开关后再试，对比波形有无',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      height: 1.5,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '说明',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '· 这是独立麦克风 App，不是 Soundcore Manager / 录音管理器\n'
                    '· 需要 Android 13+ 与 Shizuku\n'
                    '· 请先退出飞书等占用录音豆的 App\n'
                    '· 蓝牙设置不显示连接 ≠ 没在用；看「虚拟麦已开启」+ 测试音/捂麦对比\n'
                    '· 设备指示灯亮起只表示正在向手机推流，本 App 不保存录音文件',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      height: 1.5,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: child,
    );
  }
}
