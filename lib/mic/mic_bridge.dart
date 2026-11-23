import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Bridges D3200 realtime PCM into the Android 豆麦 IME / foreground service.
///
/// Android cannot register a third-party BLE device as a system microphone
/// without root. This bridge feeds decoded PCM + dictation text to a custom
/// input method so voice typing still uses the bean's mics.
class MicBridge extends ChangeNotifier {
  MicBridge._();
  static final MicBridge instance = MicBridge._();

  static const _method = MethodChannel('com.anker.anker_recorder/mic_bridge');
  static const _events = EventChannel('com.anker.anker_recorder/mic_bridge_events');

  bool _enabled = false;
  bool _nativeReady = false;
  bool _dictating = false;
  double _level = 0;
  String _status = '未启用';
  String? _partialText;
  String? _lastError;
  String _dictationBaseline = '';
  StreamSubscription? _eventSub;
  int _pcmBytesForwarded = 0;

  bool get enabled => _enabled;
  bool get nativeReady => _nativeReady;
  bool get dictating => _dictating;
  double get level => _level;
  String get status => _status;
  String? get partialText => _partialText;
  String? get lastError => _lastError;
  int get pcmBytesForwarded => _pcmBytesForwarded;
  String get dictationBaseline => _dictationBaseline;

  /// Called by UI / IME via native → Flutter when user starts/stops dictation.
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
    } catch (e) {
      _nativeReady = false;
      debugPrint('[MicBridge] native not ready: $e');
    }
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    await ensureInitialized();
    _enabled = value;
    _status = value ? '麦克风桥接已开启' : '未启用';
    _lastError = null;
    try {
      await _method.invokeMethod<void>('setEnabled', {'enabled': value});
    } catch (e) {
      _lastError = '无法通知系统服务: $e';
      debugPrint('[MicBridge] setEnabled failed: $e');
    }
    notifyListeners();
  }

  /// Push one PCM16 LE mono frame (typically 16 kHz) to the Android bridge.
  void pushPcm(Uint8List pcm) {
    if (!_enabled || pcm.isEmpty) return;
    _updateLevel(pcm);
    _pcmBytesForwarded += pcm.length;
    // Fire-and-forget; drop under backpressure rather than block BLE decode.
    unawaited(
      _method.invokeMethod<void>('pushPcm', pcm).catchError((Object e) {
        if (_lastError == null) {
          _lastError = 'PCM 推送失败: $e';
          notifyListeners();
        }
      }),
    );
  }

  /// Mark the transcript length at the moment the IME starts holding.
  void beginDictation(String currentTranscript) {
    _dictationBaseline = currentTranscript.trim();
    _partialText = null;
    _dictating = true;
    notifyListeners();
  }

  /// Live STT text → IME preview, only the portion after [dictationBaseline].
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
        _status = '正在听写…';
        notifyListeners();
        onDictationStart?.call();
        break;
      case 'dictationStop':
        _dictating = false;
        _status = _enabled ? '麦克风桥接已开启' : '未启用';
        notifyListeners();
        onDictationStop?.call();
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
    // Throttle UI updates.
    if (pcm.length >= 640) notifyListeners();
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _eventSub = null;
    super.dispose();
  }
}
