import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'xiaozhi_audio_service.dart';
import 'xiaozhi_identity_store.dart';
import 'xiaozhi_models.dart';
import 'xiaozhi_ota_service.dart';
import 'xiaozhi_realtime_client.dart';
import 'xiaozhi_speech_service.dart';

class XiaozhiSession {
  final XiaozhiOtaService ota;
  final XiaozhiRealtimeClient realtime;
  final XiaozhiIdentityStore identityStore;
  final XiaozhiSpeechService speech;
  late final XiaozhiAudioService audio;

  XiaozhiIdentity? _identity;
  XiaozhiConnectionState _state = XiaozhiConnectionState.uninitialized;
  String? _activationCode;
  String? _activationMessage;
  String? _error;
  Future<void>? _connectFuture;
  final _stateController = StreamController<XiaozhiConnectionState>.broadcast();
  late final StreamSubscription<XiaozhiConnectionState>
      _realtimeStateSubscription;

  XiaozhiSession({
    XiaozhiOtaService? ota,
    XiaozhiRealtimeClient? realtime,
    XiaozhiIdentityStore? identityStore,
    XiaozhiSpeechService? speech,
  })  : ota = ota ?? XiaozhiOtaService(),
        realtime = realtime ?? XiaozhiRealtimeClient(),
        identityStore = identityStore ?? XiaozhiIdentityStore(),
        speech = speech ?? XiaozhiSpeechService() {
    audio = XiaozhiAudioService(this.realtime);
    _realtimeStateSubscription = this.realtime.states.listen(_setState);
  }

  XiaozhiConnectionState get state => _state;
  String? get activationCode => _activationCode;
  String? get activationMessage => _activationMessage;
  String? get error => _error;
  bool get isReady => realtime.isReady;
  Stream<XiaozhiTextEvent> get events => realtime.textEvents;
  Stream<XiaozhiConnectionState> get states => _stateController.stream;

  Future<void> connect() {
    if (isReady) return Future<void>.value();
    final activeConnect = _connectFuture;
    if (activeConnect != null) return activeConnect;

    final connectFuture = _connectInternal();
    _connectFuture = connectFuture;
    // Clear the shared task on both success and failure without creating an
    // unhandled error future alongside the caller's future.
    connectFuture.then<void>(
      (_) {
        if (identical(_connectFuture, connectFuture)) _connectFuture = null;
      },
      onError: (Object _, StackTrace __) {
        if (identical(_connectFuture, connectFuture)) _connectFuture = null;
      },
    );
    return connectFuture;
  }

  Future<void> _connectInternal() async {
    try {
      _error = null;
      _setState(XiaozhiConnectionState.otaLoading);
      _identity = await identityStore.loadOrCreate();
      var result = await ota.checkVersion();
      if (result.requiresActivation) {
        _activationCode = result.activationCode;
        _activationMessage = result.activationMessage;
        _setState(XiaozhiConnectionState.activationRequired);
        if (_activationCode != null) {
          try {
            await speech.speakActivationCode(_activationCode!);
          } catch (error) {
            debugPrint('[Xiaozhi] 激活码播报失败：$error');
          }
        }
        _setState(XiaozhiConnectionState.activating);
        result = await ota.waitForActivation(initial: result);
        _activationCode = null;
        _activationMessage = null;
      }
      _setState(XiaozhiConnectionState.connecting);
      await realtime.connect(
        ota: result,
        deviceId: _identity!.deviceId,
        clientId: _identity!.clientId,
      );
      await audio.initialize(playbackSampleRate: realtime.serverSampleRate);
      _setState(XiaozhiConnectionState.ready);
    } catch (error) {
      _error = error.toString();
      _setState(XiaozhiConnectionState.error);
      rethrow;
    }
  }

  Future<String> sendText(String text) async {
    if (!isReady) await connect();
    final buffer = StringBuffer();
    final done = Completer<String>();
    late final StreamSubscription<XiaozhiTextEvent> subscription;
    subscription = events.listen((event) {
      final isSentence = event.type == 'tts' && event.state == 'sentence_start';
      final isLlmText = event.type == 'llm' && event.text != null;
      if ((isSentence || isLlmText) && event.text != null) {
        buffer.write(event.text);
      }
      if (event.type == 'tts' && event.state == 'stop' && !done.isCompleted) {
        done.complete(buffer.toString());
      }
    });
    try {
      await realtime.sendText(text);
      return await done.future.timeout(const Duration(seconds: 45),
          onTimeout: () => buffer.toString());
    } finally {
      await subscription.cancel();
    }
  }

  Future<void> startVoice() async {
    if (!isReady) await connect();
    await audio.startListening();
  }

  Future<void> stopVoice() => audio.stopListening();

  void _setState(XiaozhiConnectionState next) {
    _state = next;
    if (!_stateController.isClosed) _stateController.add(next);
  }

  Future<void> dispose() async {
    await audio.dispose();
    await _realtimeStateSubscription.cancel();
    await realtime.dispose();
    ota.dispose();
    await speech.stop();
    await _stateController.close();
  }
}

final xiaozhiSessionProvider = Provider<XiaozhiSession>((ref) {
  final session = XiaozhiSession();
  ref.onDispose(session.dispose);
  return session;
});
