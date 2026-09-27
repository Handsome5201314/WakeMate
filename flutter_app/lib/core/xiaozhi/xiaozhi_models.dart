import 'dart:typed_data';

enum XiaozhiConnectionState {
  uninitialized,
  otaLoading,
  activationRequired,
  activating,
  connecting,
  handshaking,
  ready,
  listening,
  speaking,
  disconnected,
  error,
}

class XiaozhiOtaConfig {
  final Uri otaUrl;
  final String deviceId;
  final String clientId;
  final String userAgent;
  final String language;
  final int activationVersion;

  const XiaozhiOtaConfig({
    required this.otaUrl,
    required this.deviceId,
    required this.clientId,
    this.userAgent = 'wakemate/1.0.0',
    this.language = 'zh-CN',
    this.activationVersion = 1,
  });

  Map<String, dynamic> toJson() => {
        // Keep the same device metadata shape used by the official ESP32 OTA
        // client. Self-hosted servers may use these fields for registration.
        'version': 2,
        'language': language,
        'mac_address': deviceId,
        'uuid': clientId,
        'application': {'name': 'wakemate', 'version': '1.0.0'},
        'board': {'type': 'android', 'name': 'wakemate'},
      };
}

class XiaozhiOtaResult {
  final String? activationCode;
  final String? activationMessage;
  final String? activationChallenge;
  final Duration activationTimeout;
  final Uri? websocketUrl;
  final String? token;
  final int protocolVersion;
  final Map<String, dynamic> raw;

  const XiaozhiOtaResult({
    this.activationCode,
    this.activationMessage,
    this.activationChallenge,
    this.activationTimeout = const Duration(seconds: 30),
    this.websocketUrl,
    this.token,
    this.protocolVersion = 1,
    this.raw = const {},
  });

  bool get requiresActivation =>
      activationCode != null || activationChallenge != null;
  bool get canConnect => websocketUrl != null;

  factory XiaozhiOtaResult.fromJson(Map<String, dynamic> json) {
    final activation = _asMap(json['activation']);
    final websocket = _asMap(json['websocket']);
    // The official cloud has returned both the documented nested shape and
    // a compact top-level {url, token} shape. Accept both so a successful OTA
    // response cannot be mistaken for a missing WebSocket endpoint.
    final timeoutMs = activation?['timeout_ms'];
    final websocketUrl = _asString(websocket?['url']) ?? _asString(json['url']);
    final token = _asString(websocket?['token']) ?? _asString(json['token']);
    final protocolVersion = (websocket?['version'] as num?)?.toInt() ??
        (json['version'] as num?)?.toInt() ??
        (json['protocol_version'] as num?)?.toInt() ??
        1;
    return XiaozhiOtaResult(
      activationCode: _asString(activation?['code']),
      activationMessage: _asString(activation?['message']),
      activationChallenge: _asString(activation?['challenge']),
      activationTimeout: timeoutMs is num
          ? Duration(milliseconds: timeoutMs.toInt())
          : const Duration(seconds: 30),
      websocketUrl: _parseUri(websocketUrl),
      token: token,
      protocolVersion: protocolVersion,
      raw: Map<String, dynamic>.unmodifiable(json),
    );
  }

  static Uri? _parseUri(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    return Uri.tryParse(value);
  }

  static String? _asString(Object? value) => value is String ? value : null;

  static Map<String, dynamic>? _asMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }
}

class XiaozhiTextEvent {
  final String type;
  final String? text;
  final String? state;
  final Map<String, dynamic> raw;

  const XiaozhiTextEvent({
    required this.type,
    this.text,
    this.state,
    this.raw = const {},
  });

  factory XiaozhiTextEvent.fromJson(Map<String, dynamic> json) =>
      XiaozhiTextEvent(
        type: json['type'] as String? ?? 'unknown',
        text: json['text'] as String?,
        state: json['state'] as String?,
        raw: Map<String, dynamic>.unmodifiable(json),
      );
}

class XiaozhiAudioEvent {
  final Uint8List data;
  final int? sampleRate;
  final int? frameDuration;

  const XiaozhiAudioEvent(
    this.data, {
    this.sampleRate,
    this.frameDuration,
  });
}
