import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:record/record.dart';

/// 供非系统 ASR 提供方使用的最小 PCM 麦克风边界。
abstract interface class AsrAudioCapture {
  Future<bool> hasPermission();

  Future<Stream<Uint8List>> start({required int sampleRate});

  Future<void> stop();

  Future<void> cancel();

  Future<void> dispose();
}

final class RecordAsrAudioCapture implements AsrAudioCapture {
  RecordAsrAudioCapture({AudioRecorder? recorder})
    : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;
  bool _started = false;
  bool _disposed = false;

  @override
  Future<bool> hasPermission() {
    _ensureNotDisposed();
    return _recorder.hasPermission();
  }

  @override
  Future<Stream<Uint8List>> start({required int sampleRate}) async {
    _ensureNotDisposed();
    if (_started) throw StateError('PCM audio capture is already active.');
    if (sampleRate <= 0) {
      throw ArgumentError.value(sampleRate, 'sampleRate', 'Must be positive');
    }
    final stream = await _recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
        // 保持信号为原始状态。语音处理（尤其是 AGC）会在桌面上压低电平表，
        // 并可能扭曲离线声学模型所期望的 PCM。
        autoGain: false,
        echoCancel: false,
        noiseSuppress: false,
        streamBufferSize: 4096,
      ),
    );
    _started = true;
    return stream;
  }

  @override
  Future<void> stop() async {
    if (_disposed || !_started) return;
    _started = false;
    await _recorder.stop();
  }

  @override
  Future<void> cancel() async {
    if (_disposed || !_started) return;
    _started = false;
    await _recorder.cancel();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    if (_started) await cancel();
    _disposed = true;
    await _recorder.dispose();
  }

  void _ensureNotDisposed() {
    if (_disposed) throw StateError('PCM audio capture has been disposed.');
  }
}

/// 将小端序单声道 PCM16 转换为稳定的 0–1 波形值。
double normalizedPcm16Level(Uint8List bytes) {
  final sampleCount = bytes.length ~/ 2;
  if (sampleCount == 0) return 0;
  final data = ByteData.sublistView(bytes);
  var sumSquares = 0.0;
  for (var index = 0; index < sampleCount; index++) {
    final normalized = data.getInt16(index * 2, Endian.little) / 32768.0;
    sumSquares += normalized * normalized;
  }
  final rms = math.sqrt(sumSquares / sampleCount);
  // 提升正常语音，同时让房间噪声在视觉上保持安静。
  return math.pow((rms * 3.2).clamp(0.0, 1.0), 0.72).toDouble();
}
