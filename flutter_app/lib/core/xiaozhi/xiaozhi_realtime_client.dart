import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';

import 'xiaozhi_models.dart';

class XiaozhiRealtimeException implements Exception {
  final String message;
  const XiaozhiRealtimeException(this.message);

  @override
  String toString() => message;
}

class XiaozhiRealtimeClient {
  IOWebSocketChannel? _channel;
  String? _sessionId;
  XiaozhiConnectionState _state = XiaozhiConnectionState.disconnected;
  int _serverSampleRate = 16000;
  int _serverFrameDuration = 60;
  int _binaryProtocolVersion = 1;
  StreamSubscription<dynamic>? _subscription;
  int _connectionGeneration = 0;
  final _textController = StreamController<XiaozhiTextEvent>.broadcast();
  final _audioController = StreamController<XiaozhiAudioEvent>.broadcast();
  final _stateController = StreamController<XiaozhiConnectionState>.broadcast();

  Stream<XiaozhiTextEvent> get textEvents => _textController.stream;
  Stream<XiaozhiAudioEvent> get audioEvents => _audioController.stream;
  Stream<XiaozhiConnectionState> get states => _stateController.stream;
  XiaozhiConnectionState get state => _state;
  int get serverSampleRate => _serverSampleRate;
  int get serverFrameDuration => _serverFrameDuration;
  bool get isReady =>
      _state == XiaozhiConnectionState.ready ||
      _state == XiaozhiConnectionState.listening ||
      _state == XiaozhiConnectionState.speaking;

  Future<void> connect(
      {required XiaozhiOtaResult ota,
      required String deviceId,
      required String clientId}) async {
    final url = ota.websocketUrl;
    if (url == null) {
      throw const XiaozhiRealtimeException('小智 OTA 未返回可用的 WebSocket 地址');
    }

    await disconnect();
    _serverSampleRate = 16000;
    _serverFrameDuration = 60;
    _binaryProtocolVersion = ota.protocolVersion;
    final generation = _connectionGeneration;
    _setState(XiaozhiConnectionState.connecting);
    final headers = <String, dynamic>{
      'Protocol-Version': ota.protocolVersion.toString(),
      'Device-Id': deviceId,
      'Client-Id': clientId,
    };
    final token = ota.token;
    if (token != null && token.trim().isNotEmpty) {
      final normalizedToken = token.trim();
      // OTA responses may provide either a raw token or a complete
      // authorization value such as `Bearer ...`/`Token ...`.
      headers['Authorization'] = normalizedToken.contains(' ')
          ? normalizedToken
          : 'Bearer $normalizedToken';
    }
    final channel = IOWebSocketChannel.connect(
      url,
      headers: headers,
      connectTimeout: const Duration(seconds: 15),
    );
    _channel = channel;
    _setState(XiaozhiConnectionState.handshaking);

    final hello = Completer<void>();
    _subscription = channel.stream.listen(
      (message) {
        if (generation != _connectionGeneration) return;
        if (message is String) {
          _onText(message, hello);
        } else if (message is List<int>) {
          final packet = _decodeAudio(Uint8List.fromList(message));
          if (packet != null) {
            _audioController.add(XiaozhiAudioEvent(
              packet,
              sampleRate: _serverSampleRate,
              frameDuration: _serverFrameDuration,
            ));
          }
        }
      },
      onError: (Object error, StackTrace stack) {
        if (generation != _connectionGeneration) return;
        if (!hello.isCompleted) hello.completeError(error, stack);
        _setState(XiaozhiConnectionState.error);
      },
      onDone: () {
        if (generation != _connectionGeneration) return;
        if (!hello.isCompleted) {
          hello.completeError(
              const XiaozhiRealtimeException('小智 WebSocket 在握手前断开'));
        }
        _setState(XiaozhiConnectionState.disconnected);
      },
      cancelOnError: false,
    );

    try {
      _send({
        'type': 'hello',
        'version': ota.protocolVersion,
        'features': {'mcp': true},
        'transport': 'websocket',
        'audio_params': {
          'format': 'opus',
          'sample_rate': 16000,
          'channels': 1,
          'frame_duration': 60,
        },
      });
      await hello.future.timeout(const Duration(seconds: 10));
      _setState(XiaozhiConnectionState.ready);
    } catch (error) {
      await disconnect();
      if (error is XiaozhiRealtimeException) rethrow;
      throw XiaozhiRealtimeException('小智 WebSocket 握手失败：$error');
    }
  }

  Uint8List? _decodeAudio(Uint8List packet) {
    if (_binaryProtocolVersion <= 1) return packet;
    try {
      if (_binaryProtocolVersion == 2) {
        if (packet.length < 16) throw const FormatException('v2 音频头长度不足');
        final data = ByteData.sublistView(packet);
        final version = data.getUint16(0, Endian.big);
        final type = data.getUint16(2, Endian.big);
        final payloadSize = data.getUint32(12, Endian.big);
        // Official v2 servers currently emit zero in this field on downlink
        // frames, while the ESP32 client also accepts the framed value 2.
        // Keep validating the frame type and exact payload length instead.
        if ((version != 0 && version != 2) ||
            type != 0 ||
            payloadSize != packet.length - 16) {
          throw const FormatException('v2 音频头无效');
        }
        return Uint8List.sublistView(packet, 16, 16 + payloadSize);
      }
      if (_binaryProtocolVersion == 3) {
        if (packet.length < 4) throw const FormatException('v3 音频头长度不足');
        final data = ByteData.sublistView(packet);
        final type = data.getUint8(0);
        final payloadSize = data.getUint16(2, Endian.big);
        if (type != 0 || payloadSize != packet.length - 4) {
          throw const FormatException('v3 音频头无效');
        }
        return Uint8List.sublistView(packet, 4, 4 + payloadSize);
      }
      throw FormatException('不支持的小智二进制协议版本 $_binaryProtocolVersion');
    } catch (error) {
      debugPrint('[Xiaozhi] 音频帧解析失败：$error');
      return null;
    }
  }

  void _onText(String raw, Completer<void>? hello) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      final json = decoded;
      if (json['type'] == 'hello') {
        if (json['transport'] != 'websocket') {
          final error = XiaozhiRealtimeException(
              '小智 WebSocket 握手返回了不支持的 transport：${json['transport']}');
          if (hello != null && !hello.isCompleted) {
            hello.completeError(error);
          }
          return;
        }
        _sessionId = json['session_id'] as String?;
        final audioParams = json['audio_params'];
        if (audioParams is Map) {
          final sampleRate = audioParams['sample_rate'];
          final frameDuration = audioParams['frame_duration'];
          if (sampleRate is num && sampleRate > 0) {
            _serverSampleRate = sampleRate.toInt();
          }
          if (frameDuration is num && frameDuration > 0) {
            _serverFrameDuration = frameDuration.toInt();
          }
        }
        if (hello != null && !hello.isCompleted) hello.complete();
      } else if (json['type'] == 'tts' && json['state'] == 'start') {
        final sampleRate = json['sample_rate'];
        if (sampleRate is num && sampleRate > 0) {
          _serverSampleRate = sampleRate.toInt();
        }
        final frameDuration = json['frame_duration'];
        if (frameDuration is num && frameDuration > 0) {
          _serverFrameDuration = frameDuration.toInt();
        }
      }
      final event = XiaozhiTextEvent.fromJson(json);
      if (event.type == 'tts' && event.state == 'start') {
        _setState(XiaozhiConnectionState.speaking);
      } else if (event.type == 'tts' && event.state == 'stop') {
        _setState(XiaozhiConnectionState.ready);
      }
      _textController.add(event);
    } catch (error) {
      debugPrint('[Xiaozhi] JSON 消息解析失败：$error');
    }
  }

  Future<void> sendText(String text) async {
    _ensureReady();
    _send({
      'type': 'listen',
      'state': 'detect',
      'text': text,
    });
  }

  Future<void> startListening() async {
    _ensureReady();
    _setState(XiaozhiConnectionState.listening);
    _send({
      'type': 'listen',
      'state': 'start',
      'mode': 'manual',
    });
  }

  Future<void> stopListening() async {
    if (!isReady) return;
    _send({'type': 'listen', 'state': 'stop'});
    _setState(XiaozhiConnectionState.ready);
  }

  void sendAudio(Uint8List opusPacket) {
    _ensureReady();
    _channel!.sink.add(_encodeAudio(opusPacket));
  }

  Uint8List _encodeAudio(Uint8List packet) {
    if (_binaryProtocolVersion <= 1) return packet;
    if (_binaryProtocolVersion == 2) {
      final data = ByteData(16 + packet.length);
      data.setUint16(0, 2, Endian.big);
      data.setUint16(2, 0, Endian.big);
      data.setUint32(4, 0, Endian.big);
      data.setUint32(8, 0, Endian.big);
      data.setUint32(12, packet.length, Endian.big);
      data.buffer.asUint8List().setRange(16, 16 + packet.length, packet);
      return data.buffer.asUint8List();
    }
    if (_binaryProtocolVersion == 3) {
      if (packet.length > 0xffff) {
        throw const XiaozhiRealtimeException('小智 v3 音频帧超过协议长度限制');
      }
      final data = ByteData(4 + packet.length);
      data.setUint8(0, 0);
      data.setUint8(1, 0);
      data.setUint16(2, packet.length, Endian.big);
      data.buffer.asUint8List().setRange(4, 4 + packet.length, packet);
      return data.buffer.asUint8List();
    }
    throw XiaozhiRealtimeException('不支持的小智二进制协议版本 $_binaryProtocolVersion');
  }

  void abort() {
    if (_channel == null) return;
    _send({'type': 'abort', 'reason': 'user_abort'});
  }

  void _ensureReady() {
    if (!isReady || _channel == null) {
      throw const XiaozhiRealtimeException('小智连接尚未就绪');
    }
  }

  void _send(Map<String, dynamic> message) {
    final payload = Map<String, dynamic>.from(message);
    if (_sessionId != null) payload['session_id'] = _sessionId;
    _channel?.sink.add(jsonEncode(payload));
  }

  void _setState(XiaozhiConnectionState value) {
    if (_state == value) return;
    _state = value;
    if (!_stateController.isClosed) _stateController.add(value);
  }

  Future<void> disconnect() async {
    _connectionGeneration++;
    final subscription = _subscription;
    _subscription = null;
    final channel = _channel;
    _channel = null;
    _sessionId = null;
    await subscription?.cancel();
    if (channel != null) await channel.sink.close();
    _setState(XiaozhiConnectionState.disconnected);
  }

  Future<void> dispose() async {
    await disconnect();
    await _textController.close();
    await _audioController.close();
    await _stateController.close();
  }
}
