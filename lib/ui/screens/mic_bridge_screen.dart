import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../mic/mic_bridge.dart';
import '../../platform/background_sync_service.dart';
import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/scan_sheet.dart';

/// Turn the D3200 into a voice-input mic via the 豆麦 IME.
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
    if (!c.connected) {
      await MicBridge.instance.pushPartialText('请先连接录音豆');
      return;
    }
    if (!c.recording) {
      await c.startRecord();
    }
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
    // Keep recording so the next dictation is low-latency; user can stop on Device tab.
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
      await bridge.setEnabled(true);
      await BackgroundSyncService.start();
      if (!c.recording) {
        await c.startRecord();
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
              '把安克录音豆变成语音输入麦克风。Android 无法把第三方 BLE 设备注册成系统麦，因此通过「豆麦输入法」在任意输入框里用录音豆收音并上屏。',
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
                      '${c.recording ? "录音中" : "待命"}',
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
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '麦克风桥接',
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
                  Text(
                    bridge.status,
                    style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
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
                        : '开启后开始从录音豆拉取实时音频',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                  ),
                  if (bridge.lastError != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      bridge.lastError!,
                      style: const TextStyle(color: AppColors.coral, fontSize: 12),
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
                    '启用豆麦输入法',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '1. 在系统设置中启用「豆麦输入法」\n'
                    '2. 在任意 App 的输入框切换到豆麦\n'
                    '3. 按住麦克风键说话，松手后文字上屏\n'
                    '4. 转写使用设置里配置的 Soniox（需 API Key）',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      height: 1.5,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.tonal(
                          onPressed: bridge.openImeSettings,
                          child: const Text('打开输入法设置'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton(
                          onPressed: bridge.showImePicker,
                          child: const Text('切换输入法'),
                        ),
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
                  const Text(
                    '说明',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '录音豆通过 BLE 传输 Opus 音频，不是经典蓝牙 HFP 耳机，'
                    '所以微信/系统自带语音键无法直接选它当麦克风。'
                    '豆麦输入法是无 Root 前提下，把录音豆收音接到「语音输入」的可行方案。'
                    '请保持本应用在后台运行（会显示常驻通知）。',
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
