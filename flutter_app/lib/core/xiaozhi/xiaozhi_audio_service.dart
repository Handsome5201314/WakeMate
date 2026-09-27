import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:opus_codec_dart/opus_codec_dart.dart';
import 'package:record/record.dart';

import 'xiaozhi_models.dart';
import 'xiaozhi_realtime_client.dart';

class XiaozhiAudioService {
  static const sampleRate = 16000;
  static const channels = 1;
  static const frameBytes = sampleRate * 60 ~/ 1000 * channels * 2;

  final AudioRecorder _recorder = AudioRecorder();
  final XiaozhiRealtimeClient _client;
  StreamSubscription<Uint8List>? _recordSubscription;
  StreamSubscription<XiaozhiAudioEvent>? _audioSubscription;
  final List<int> _recordBuffer = <int>[];
  final List<int> _playbackBuffer = <int>[];
  SimpleOpusEncoder? _encoder;
  SimpleOpusDecoder? _decoder;
  bool _playbackReady = false;
  int _playbackRate = sampleRate;

  XiaozhiAudioService(this._client);

  Future<void> initialize({int playbackSampleRate = sampleRate}) async {
    _encoder ??= SimpleOpusEncoder(
      sampleRate: sampleRate,
      channels: channels,
      application: Application.audio,
    );
    _audioSubscription ??= _client.audioEvents.listen(_onAudioPacket);
    await _setupPlayback(playbackSampleRate);
  }

  Future<void> startListening() async {
    await initialize(
        playbackSampleRate: _playbackReady ? _playbackRate : sampleRate);
    if (!await _recorder.hasPermission()) {
      throw const AudioServiceException('没有麦克风权限，请在系统设置中允许醒伴使用麦克风');
    }
    await _client.startListening();
    final stream = await _recorder.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: sampleRate,
      numChannels: channels,
      echoCancel: true,
      noiseSuppress: true,
      autoGain: true,
      streamBufferSize: frameBytes,
    ));
    _recordBuffer.clear();
    _recordSubscription = stream.listen(_onPcmChunk);
  }

  Future<void> stopListening() async {
    await _recordSubscription?.cancel();
    _recordSubscription = null;
    await _recorder.stop();
    _recordBuffer.clear();
    await _client.stopListening();
  }

  void _onPcmChunk(Uint8List chunk) {
    _recordBuffer.addAll(chunk);
    while (_recordBuffer.length >= frameBytes) {
      final bytes = Uint8List.fromList(_recordBuffer.take(frameBytes).toList());
      _recordBuffer.removeRange(0, frameBytes);
      final samples = bytes.buffer.asInt16List(
        bytes.offsetInBytes,
        bytes.lengthInBytes ~/ 2,
      );
      final packet = _encoder!.encode(input: samples);
      _client.sendAudio(packet);
    }
  }

  Future<void> _setupPlayback(int rate) async {
    if (_playbackReady && _playbackRate == rate) return;
    _playbackBuffer.clear();
    _playbackRate = rate;
    await FlutterPcmSound.setup(sampleRate: rate, channelCount: channels);
    await FlutterPcmSound.setFeedThreshold(rate ~/ 5);
    FlutterPcmSound.setFeedCallback(_feedPlayback);
    _decoder?.destroy();
    _decoder = SimpleOpusDecoder(sampleRate: rate, channels: channels);
    _playbackReady = true;
  }

  Future<void> _onAudioPacket(XiaozhiAudioEvent event) async {
    if (!_playbackReady || _decoder == null) return;
    try {
      final sampleRate = event.sampleRate;
      if (sampleRate != null && sampleRate > 0 && sampleRate != _playbackRate) {
        await _setupPlayback(sampleRate);
      }
      if (_decoder == null) return;
      final samples = _decoder!.decode(input: event.data);
      _playbackBuffer.addAll(samples);
      FlutterPcmSound.start();
      _feedPlayback(0);
    } catch (error) {
      // A malformed packet must not terminate the WebSocket/audio session.
      debugPrint('[Xiaozhi] Opus 播放失败：$error');
    }
  }

  Future<void> _feedPlayback(int _) async {
    if (_playbackBuffer.isEmpty) return;
    final count = _playbackBuffer.length > _playbackRate ~/ 10
        ? _playbackRate ~/ 10
        : _playbackBuffer.length;
    final samples = _playbackBuffer.sublist(0, count);
    _playbackBuffer.removeRange(0, count);
    await FlutterPcmSound.feed(PcmArrayInt16.fromList(samples));
  }

  Future<void> dispose() async {
    await _recordSubscription?.cancel();
    await _audioSubscription?.cancel();
    await _recorder.dispose();
    _encoder?.destroy();
    _decoder?.destroy();
    await FlutterPcmSound.release();
  }
}

class AudioServiceException implements Exception {
  final String message;
  const AudioServiceException(this.message);

  @override
  String toString() => message;
}
