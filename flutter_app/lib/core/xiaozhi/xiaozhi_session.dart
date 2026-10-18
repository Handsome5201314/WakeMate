import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/providers/auth_provider.dart';
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
  XiaozhiSpeechService? _speech;
  XiaozhiAudioService? _audio;
  XiaozhiSpeechService get speech => _speech ??= XiaozhiSpeechService();
  XiaozhiAudioService get audio => _audio ??= XiaozhiAudioService(realtime);

  XiaozhiIdentity? _identity;
  XiaozhiConnectionState _state = XiaozhiConnectionState.uninitialized;
  String? _activationCode;
  String? _activationMessage;
  String? _error;
  Future<void>? _connectFuture;
  bool _disposed = false;
  Future<void>? _disposeFuture;
  final _stateController = StreamController<XiaozhiConnectionState>.broadcast();
  late final StreamSubscription<XiaozhiConnectionState>
  _realtimeStateSubscription;

  XiaozhiSession({
    required this.identityStore,
    XiaozhiOtaService? ota,
    XiaozhiRealtimeClient? realtime,
    XiaozhiSpeechService? speech,
  }) : ota = ota ?? XiaozhiOtaService(identityStore: identityStore),
       realtime = realtime ?? XiaozhiRealtimeClient(),
       _speech = speech {
    if (!identical(this.ota.identityStore, identityStore)) {
      throw ArgumentError(
        'OTA and session must share the same account identity',
      );
    }
    _realtimeStateSubscription = this.realtime.states.listen(_setState);
  }

  XiaozhiConnectionState get state => _state;
  String? get activationCode => _activationCode;
  String? get activationMessage => _activationMessage;
  String? get error => _error;
  bool get isDisposed => _disposed;
  bool get isReady => !_disposed && realtime.isReady;
  Stream<XiaozhiTextEvent> get events => realtime.textEvents;
  Stream<XiaozhiConnectionState> get states => _stateController.stream;

  Future<void> connect() {
    if (_disposed) return Future<void>.error(StateError('小智会话已结束'));
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
      _ensureActive();
      var result = await ota.checkVersion();
      _ensureActive();
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
        _ensureActive();
        _activationCode = null;
        _activationMessage = null;
      }
      _setState(XiaozhiConnectionState.connecting);
      await realtime.connect(
        ota: result,
        deviceId: _identity!.deviceId,
        clientId: _identity!.clientId,
      );
      _ensureActive();
      await audio.initialize(playbackSampleRate: realtime.serverSampleRate);
      _ensureActive();
      _setState(XiaozhiConnectionState.ready);
    } catch (error) {
      _error = error.toString();
      _setState(XiaozhiConnectionState.error);
      rethrow;
    }
  }

  Future<String> sendText(String text) async {
    _ensureActive();
    if (!isReady) await connect();
    _ensureActive();
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
      return await done.future.timeout(
        const Duration(seconds: 45),
        onTimeout: () => buffer.toString(),
      );
    } finally {
      await subscription.cancel();
    }
  }

  Future<void> startVoice() async {
    _ensureActive();
    if (!isReady) await connect();
    _ensureActive();
    await audio.startListening();
  }

  Future<void> stopVoice() async {
    _ensureActive();
    await audio.stopListening();
  }

  void _ensureActive() {
    if (_disposed) throw StateError('小智会话已结束，请重新登录后连接');
  }

  void _setState(XiaozhiConnectionState next) {
    if (_disposed) return;
    _state = next;
    if (!_stateController.isClosed) _stateController.add(next);
  }

  Future<void> dispose() {
    if (_disposeFuture != null) return _disposeFuture!;
    _disposed = true;
    // Close OTA immediately so a pending response cannot start a new socket.
    ota.dispose();
    return _disposeFuture = _disposeResources();
  }

  Future<void> _disposeResources() async {
    try {
      await realtime.disconnect();
    } finally {
      await Future.wait<void>([
        if (_audio != null) _audio!.dispose(),
        _realtimeStateSubscription.cancel(),
        realtime.dispose(),
        if (_speech != null) _speech!.stop(),
        _stateController.close(),
      ]);
    }
  }
}

final xiaozhiSessionProvider = Provider<XiaozhiSession>((ref) {
  final account = ref.watch(authProvider).valueOrNull;
  if (account == null || !account.isAuthenticated || account.userId == null) {
    throw StateError('请先登录醒伴账户，再连接小智智能体');
  }
  final session = XiaozhiSession(
    identityStore: XiaozhiIdentityStore(userId: account.userId!),
  );
  ref.onDispose(() {
    unawaited(
      session.dispose().catchError((Object error) {
        debugPrint('[Xiaozhi] 会话释放失败：$error');
      }),
    );
  });
  return session;
});
