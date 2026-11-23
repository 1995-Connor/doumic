import 'dart:typed_data';

import 'package:anker_recorder/mic/pcm_gain.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _tone({required int amplitude, int samples = 320}) {
  final out = Uint8List(samples * 2);
  final bd = ByteData.sublistView(out);
  for (var i = 0; i < samples; i++) {
    final s = (i.isEven ? amplitude : -amplitude).clamp(-32768, 32767);
    bd.setInt16(i * 2, s, Endian.little);
  }
  return out;
}

int _peak(Uint8List pcm) {
  final bd = ByteData.sublistView(pcm);
  var peak = 0;
  for (var i = 0; i < pcm.length ~/ 2; i++) {
    final v = bd.getInt16(i * 2, Endian.little).abs();
    if (v > peak) peak = v;
  }
  return peak;
}

void main() {
  test('quiet speech is boosted above IME-like floor', () {
    final g = PcmGain()..auto = true;
    // Soft speech ~3% FS — typical quiet bean capture.
    final quiet = _tone(amplitude: 1000);
    Uint8List out = quiet;
    for (var i = 0; i < 12; i++) {
      out = g.process(quiet);
    }
    expect(_peak(out), greaterThan(4000));
    expect(g.appliedGain, greaterThan(3.0));
  });

  test('manual gain scales and soft-clips loud peaks', () {
    final g = PcmGain()
      ..auto = false
      ..manualGain = 8;
    final loud = _tone(amplitude: 20000);
    final out = g.process(loud);
    expect(_peak(out), lessThanOrEqualTo(32767));
    expect(_peak(out), greaterThan(20000));
  });
}
