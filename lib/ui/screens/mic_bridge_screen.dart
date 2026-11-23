import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../mic/mic_bridge.dart';
import '../../platform/background_sync_service.dart';
import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/scan_sheet.dart';

/// System virtual microphone: D3200 audio → phone mic for any app.
class MicBridgeScreen extends StatefulWidget {
  const MicBridgeScreen({super.key});

  @override
  State<MicBridgeScreen> createState() => _MicBridgeScreenState();
}

class _MicBridgeScreenState extends State<MicBridgeScreen> {
  @override
  void initState() {
    super.initState();
    final bridge = MicBridge.instance;
    bridge.ensureInitialized();
    bridge.onDictationStart = _handleDictationStart;
    bridge.onDictationStop = _handleDictationStop;
  }

  @override
  void dispose() {
    final bridge = MicBridge.instance;
    if (bridge.onDictationStart == _handleDictationStart) {
      bridge.onDictationStart = null;
    }
    if (bridge.onDictationStop == _handleDictationStop) {
      bridge.onDictationStop = null;
    }
    super.dispose();
  }

  Future<void> _handleDictationStart() async {
    if (!mounted) return;
    final c = context.read<RecorderController>();
    final live =
        (c.transcriptPartial?.isNotEmpty == true
                ? c.transcriptPartial!
                : c.transcript)
            .trim();
    MicBridge.instance.beginDictation(live);
    if (!c.connected) return;
    if (!c.recording) await c.startRecord();
  }

  Future<void> _handleDictationStop() async {
    if (!mounted) return;
    final c = context.read<RecorderController>();
    final live =
        (c.transcriptPartial?.isNotEmpty == true
                ? c.transcriptPartial!
                : c.transcript)
            .trim();
    await MicBridge.instance.syncTranscript(live, isFinal: true);
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
        // Still attempt so native side updates status text.
      }
      await bridge.setEnabled(true);
      await BackgroundSyncService.start();
      if (!c.recording) await c.startRecord();
      await bridge.refreshStatus();
      if (!bridge.virtualMicRunning && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(bridge.status)),
        );
      }
    } else {
      await bridge.setEnabled(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final bridge = context.watch<MicBridge>();
    final connected = c.connected;
    final level = bridge.level;
    final shizukuOk = bridge.shizuku == 'Shizuku 已就绪';
    final micOk = bridge.virtualMicRunning;

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
              '把录音豆变成手机的系统麦克风。开启后，搜狗/系统语音输入、腾讯会议、Zoom 等 App 开麦时，采到的就是录音豆的声音。',
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
                      '${c.recording ? "录音中（推流中）" : "待命"}',
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 13,
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
                    '① 准备 Shizuku（配对 → 启动 → 授权）',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '「配对」和「启动」是两步，只配对不算运行。豆麦必须等 Shizuku 顶部显示「正在运行」后才能开虚拟麦。',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      height: 1.45,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'A. 系统准备\n'
                    '  · 设置 → 关于手机 → 连续点版本号 7 次，打开开发者选项\n'
                    '  · 打开「USB 调试」和「无线调试」\n'
                    '  · 小米/红米还需打开「USB 调试（安全设置）」\n'
                    '\n'
                    'B. 配对（通常只需一次）\n'
                    '  1. 打开 Shizuku → 通过无线调试 → 点「配对」\n'
                    '  2. 允许通知权限（配对码要在通知里输入）\n'
                    '  3. 回到系统「无线调试」→「使用配对码配对设备」\n'
                    '  4. 把 6 位配对码填进 Shizuku 通知，看到「配对成功」\n'
                    '\n'
                    'C. 启动（每次重启手机后都要再做）\n'
                    '  · 在 Shizuku 里点「启动」，等到显示「Shizuku 正在运行」\n'
                    '\n'
                    'D. 回到豆麦\n'
                    '  · 点「授权 Shizuku」，再开下方虚拟麦克风开关',
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
                          '② 开启系统虚拟麦克风',
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
                        ? '实时电平 ${(level * 100).round()}% · 已转发 ${(bridge.pcmBytesForwarded / 1024).toStringAsFixed(1)} KB'
                        : '开启后：录音豆 → 系统麦克风',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 12),
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
                    '③ 在其他 App 里用',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '保持豆麦在后台运行（会有常驻通知）。然后：\n'
                    '· 语音输入法：直接按原有语音键，无需切换输入法\n'
                    '· 线上会议：在腾讯会议 / Zoom / 飞书里正常开麦\n'
                    '系统会把录音豆当成默认麦克风来源（MIC / 语音识别 / 通话采集）。',
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
                    '说明与限制',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '· 需要 Android 13+\n'
                    '· 需要 Shizuku；每次重启手机后重新启动 Shizuku\n'
                    '· 部分厂商 ROM 对动态 AudioPolicy 兼容性不一，若会议仍走手机麦，请反馈机型\n'
                    '· 请先退出飞书等占用录音豆的 App\n'
                    '· 「豆麦输入法」仍保留为备用，不是主路径',
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
