import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Bridges D3200 realtime PCM into a **system-wide virtual microphone**.
///
/// On Android 13+, with Shizuku (wireless debugging), we register an AudioPolicy
/// injector so 搜狗 / 系统语音 / 腾讯会议 / Zoom etc. read the bean's audio
/// as if it were the phone mic. Stock Android cannot do this without privilege.
class MicBridge extends ChangeNotifier {
  MicBridge._();
  static final MicBridge instance = MicBridge._();

  static const _method = MethodChannel('com.doumic.app/mic_bridge');
  static const _events = EventChannel(
    'com.doumic.app/mic_bridge_events',
  );

  bool _enabled = false;
  bool _nativeReady = false;
  bool _virtualMicRunning = false;
  bool _dictating = false;
  double _level = 0;
  String _status = '未启用';
  String _shizuku = '未知';
  String? _partialText;
  String? _lastError;
  String _dictationBaseline = '';
  StreamSubscription? _eventSub;
  int _pcmBytesForwarded = 0;

  bool get enabled => _enabled;
  bool get nativeReady => _nativeReady;
  bool get virtualMicRunning => _virtualMicRunning;
  bool get dictating => _dictating;
  double get level => _level;
  String get status => _status;
  String get shizuku => _shizuku;
  String? get partialText => _partialText;
  String? get lastError => _lastError;
  int get pcmBytesForwarded => _pcmBytesForwarded;
  String get dictationBaseline => _dictationBaseline;

  void Function()? onDictationStart;
  void Function()? onDictationStop;

  Future<void> ensureInitialized() async {
    if (_eventSub != null) return;
    _eventSub = _events.receiveBroadcastStream().listen(
      _onNativeEvent,
      onError: (Object e) {
        _lastError = '$e';
        notifyListeners();
      },
    );
    try {
      final ready = await _method.invokeMethod<bool>('isReady');
      _nativeReady = ready == true;
      await refreshStatus();
    } catch (e) {
      _nativeReady = false;
      debugPrint('[MicBridge] native not ready: $e');
    }
    notifyListeners();
  }

  Future<void> refreshStatus() async {
    try {
      final map = await _method.invokeMethod<Map>('getVirtualMicStatus');
      if (map != null) {
        _status = map['message']?.toString() ?? _status;
        _virtualMicRunning = map['running'] == true;
        _shizuku = map['shizuku']?.toString() ?? _shizuku;
        _enabled = map['enabled'] == true || _enabled;
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> requestShizukuPermission() async {
    try {
      final map = await _method.invokeMethod<Map>('requestShizukuPermission');
      _shizuku = map?['shizuku']?.toString() ?? _shizuku;
      final msg = map?['message']?.toString();
      if (msg != null && msg.isNotEmpty) _status = msg;
    } catch (e) {
      _lastError = '请求 Shizuku 授权失败: $e';
    }
    notifyListeners();
  }

  Future<void> openShizukuApp() async {
    try {
      await _method.invokeMethod<void>('openShizukuApp');
    } catch (e) {
      _lastError = '无法打开 Shizuku: $e';
      notifyListeners();
    }
  }

  Future<void> openDeveloperOptions() async {
    try {
      await _method.invokeMethod<void>('openDeveloperOptions');
    } catch (e) {
      _lastError = '无法打开开发者选项: $e';
      notifyListeners();
    }
  }

  Future<void> setEnabled(bool value) async {
    await ensureInitialized();
    _enabled = value;
    _lastError = null;
    _status = value ? '正在启动系统虚拟麦克风…' : '未启用';
    notifyListeners();
    try {
      final map = await _method.invokeMethod<Map>('setEnabled', {
        'enabled': value,
      });
      if (map != null) {
        _status = map['virtualMic']?.toString() ?? _status;
        _virtualMicRunning = map['running'] == true;
        _shizuku = map['shizuku']?.toString() ?? _shizuku;
      }
    } catch (e) {
      _lastError = '无法启动虚拟麦克风: $e';
      debugPrint('[MicBridge] setEnabled failed: $e');
    }
    notifyListeners();
  }

  void pushPcm(Uint8List pcm) {
    if (!_enabled || pcm.isEmpty) return;
    _updateLevel(pcm);
    _pcmBytesForwarded += pcm.length;
    unawaited(
      _method.invokeMethod<void>('pushPcm', pcm).catchError((Object e) {
        if (_lastError == null) {
          _lastError = 'PCM 推送失败: $e';
          notifyListeners();
        }
      }),
    );
  }

  void beginDictation(String currentTranscript) {
    _dictationBaseline = currentTranscript.trim();
    _partialText = null;
    _dictating = true;
    notifyListeners();
  }

  Future<void> syncTranscript(String fullText, {bool isFinal = false}) async {
    if (!_dictating && !isFinal) return;
    final delta = _deltaFrom(fullText);
    if (delta.isEmpty) return;
    if (isFinal) {
      await pushFinalText(delta);
      _dictationBaseline = fullText.trim();
    } else {
      await pushPartialText(delta);
    }
  }

  String _deltaFrom(String fullText) {
    final text = fullText.trim();
    final baseline = _dictationBaseline;
    if (baseline.isEmpty) return text;
    if (text.startsWith(baseline)) {
      return text.substring(baseline.length).trim();
    }
    return text;
  }

  Future<void> pushPartialText(String text) async {
    _partialText = text;
    notifyListeners();
    try {
      await _method.invokeMethod<void>('pushPartialText', {'text': text});
    } catch (_) {}
  }

  Future<void> pushFinalText(String text) async {
    _partialText = text;
    notifyListeners();
    try {
      await _method.invokeMethod<void>('pushFinalText', {'text': text});
    } catch (_) {}
  }

  Future<void> openImeSettings() async {
    try {
      await _method.invokeMethod<void>('openImeSettings');
    } catch (e) {
      _lastError = '无法打开输入法设置: $e';
      notifyListeners();
    }
  }

  Future<void> showImePicker() async {
    try {
      await _method.invokeMethod<void>('showImePicker');
    } catch (e) {
      _lastError = '无法打开输入法切换器: $e';
      notifyListeners();
    }
  }

  void _onNativeEvent(dynamic event) {
    if (event is! Map) return;
    final type = event['type']?.toString();
    switch (type) {
      case 'dictationStart':
        _dictating = true;
        notifyListeners();
        onDictationStart?.call();
        break;
      case 'dictationStop':
        _dictating = false;
        notifyListeners();
        onDictationStop?.call();
        break;
      case 'virtualMicStatus':
        _status = event['message']?.toString() ?? _status;
        _virtualMicRunning = event['running'] == true;
        _shizuku = event['shizuku']?.toString() ?? _shizuku;
        notifyListeners();
        break;
      case 'imeStatus':
        _status = event['message']?.toString() ?? _status;
        notifyListeners();
        break;
    }
  }

  void _updateLevel(Uint8List pcm) {
    if (pcm.length < 4) return;
    final bd = ByteData.sublistView(pcm);
    var peak = 0;
    final samples = pcm.length ~/ 2;
    final step = samples > 320 ? samples ~/ 160 : 1;
    for (var i = 0; i < samples; i += step) {
      final v = bd.getInt16(i * 2, Endian.little).abs();
      if (v > peak) peak = v;
    }
    _level = (peak / 32768.0).clamp(0.0, 1.0);
    if (pcm.length >= 640) notifyListeners();
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _eventSub = null;
    super.dispose();
  }
}
