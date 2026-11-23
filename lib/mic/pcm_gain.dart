import 'dart:math' as math;
import 'dart:typed_data';

/// Soft AGC / manual boost for D3200 PCM before virtual-mic injection.
///
/// Phone mics usually go through HAL AGC for [VOICE_RECOGNITION]. Our AudioPolicy
/// loopback injects raw BLE PCM with no hardware AGC, so soft speech often sits
/// below Typeless / IME VAD thresholds even when the bean is picking it up.
class PcmGain {
  /// When true, gain tracks recent peak toward [targetPeak].
  bool auto = true;

  /// Used when [auto] is false. Typical useful range: 4–16×.
  double manualGain = 8.0;

  /// Target peak as fraction of full-scale (0–1). Soft speech needs headroom.
  double targetPeak = 0.55;

  /// Never apply less than this (bean is quieter than phone mics).
  double minGain = 4.0;

  /// Hard ceiling to avoid runaway on silence noise.
  double maxGain = 18.0;

  /// Current applied gain (for UI).
  double appliedGain = 2.0;

  double _envelope = 0.02;

  /// Amplify PCM16 LE mono in-place-safe copy; soft-clips near full scale.
  Uint8List process(Uint8List pcm) {
    if (pcm.length < 4) return pcm;
    final samples = pcm.length ~/ 2;
    final bdIn = ByteData.sublistView(pcm);

    var peak = 0;
    final step = samples > 320 ? samples ~/ 160 : 1;
    for (var i = 0; i < samples; i += step) {
      final v = bdIn.getInt16(i * 2, Endian.little).abs();
      if (v > peak) peak = v;
    }
    final peakNorm = peak / 32768.0;

    // Fast attack / slow release so soft syllables get boosted quickly.
    if (peakNorm > _envelope) {
      _envelope = _envelope * 0.55 + peakNorm * 0.45;
    } else {
      _envelope = _envelope * 0.985 + peakNorm * 0.015;
    }

    double gain;
    if (auto) {
      final env = math.max(_envelope, 0.008);
      gain = (targetPeak / env).clamp(minGain, maxGain);
    } else {
      gain = manualGain.clamp(1.0, maxGain);
    }
    // Smooth gain changes to avoid zipper noise.
    appliedGain = appliedGain * 0.85 + gain * 0.15;

    final out = Uint8List(pcm.length);
    final bdOut = ByteData.sublistView(out);
    final g = appliedGain;
    for (var i = 0; i < samples; i++) {
      final s = bdIn.getInt16(i * 2, Endian.little).toDouble() * g;
      // Soft knee into ±32767 (rational approx of tanh) — dart:math has no tanh.
      final n = (s / 32768.0) * 1.15;
      final soft = (n / (1.0 + n.abs())) * 32767.0;
      bdOut.setInt16(i * 2, soft.round().clamp(-32768, 32767), Endian.little);
    }
    return out;
  }

  void reset() {
    _envelope = 0.02;
    appliedGain = minGain;
  }
}
