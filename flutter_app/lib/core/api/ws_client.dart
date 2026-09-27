// lib/core/api/ws_client.dart
// WebSocket 长连接管理 · 自动重连 + 事件分发
// 醒伴 WakeMate Flutter APP · 醒时科技 Wakeshift
//
// [IS_MOCK_MODE 开关]
// kMockMode = true  → 本地 Timer 模拟事件，不建立真实 WS 连接
// kMockMode = false → 等待后端 realtime ticket 契约完成后连接官方端点
//
// 使用方式：
//   final client = WakeMateWsClient.instance;
//   client.events.listen((event) {
//     if (event.type == WsEventType.reminderTrigger) { ... }
//   });
//   client.connect(userId: userId);

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'rest_client.dart';

// ── 事件类型 ──────────────────────────────────────────────────────
enum WsEventType {
  reminderTrigger, // 服药提醒到点
  doseConfirmed, // 服药已确认
  doseMissed, // 漏服判定
  doseSnoozed, // 稍后提醒
  deviceStatus, // 设备状态变更
  batteryLow, // 电量低告警
  planSynced, // 计划同步完成
  unknown,
}

class WsEvent {
  final WsEventType type;
  final Map<String, dynamic> payload;
  final DateTime receivedAt;

  WsEvent({required this.type, required this.payload})
      : receivedAt = DateTime.now();

  static WsEventType _typeFromString(String s) {
    switch (s) {
      case 'REMINDER_TRIGGER':
        return WsEventType.reminderTrigger;
      case 'DOSE_CONFIRMED':
        return WsEventType.doseConfirmed;
      case 'DOSE_MISSED':
        return WsEventType.doseMissed;
      case 'DOSE_SNOOZED':
        return WsEventType.doseSnoozed;
      case 'DEVICE_STATUS':
        return WsEventType.deviceStatus;
      case 'BATTERY_LOW':
        return WsEventType.batteryLow;
      case 'PLAN_SYNC_DOWN':
        return WsEventType.planSynced;
      default:
        return WsEventType.unknown;
    }
  }

  factory WsEvent.fromJson(Map<String, dynamic> json) => WsEvent(
        type: _typeFromString(json['type'] as String? ?? ''),
        payload: json['payload'] as Map<String, dynamic>? ?? {},
      );
}

// ── WakeMateWsClient 单例 ─────────────────────────────────────────
class WakeMateWsClient {
  WakeMateWsClient._();
  static final instance = WakeMateWsClient._();

  WebSocketChannel? _channel;
  String? _userId;
  bool _connected = false;
  bool _disposed = false;

  // 重连指数退避
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 10;
  Timer? _reconnectTimer;
  Timer? _heartbeatTimer;
  Timer? _mockTimer;

  // 事件流
  final _controller = StreamController<WsEvent>.broadcast();
  Stream<WsEvent> get events => _controller.stream;
  bool get isConnected => _connected;

  // ── 连接 ────────────────────────────────────────────────────────
  void connect({required String userId}) {
    _userId = userId;
    _disposed = false;

    if (kMockMode) {
      _startMockEvents();
      return;
    }

    _doConnect();
  }

  void _doConnect() {
    if (_disposed || _userId == null) return;

    // 当前交付包的 FastAPI 尚未提供 /api/realtime/ticket；不要连接架构文档
    // 已标记为迁移期的 /ws/session/{user_id}，避免把未鉴权连接误当生产链路。
    if (!kMockMode) {
      _connected = false;
      debugPrint('[WsClient] realtime ticket 未配置，业务 WebSocket 保持断开');
      return;
    }

    try {
      final wsUrl =
          kBaseUrl.replaceFirst('http', 'ws').replaceFirst('https', 'wss');
      final uri = Uri.parse('$wsUrl/ws/session/${_userId}');

      _channel = WebSocketChannel.connect(uri);
      _connected = true;
      _reconnectAttempts = 0;

      debugPrint('[WsClient] ✅ 已连接 $uri');

      // 监听消息
      _channel!.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
        cancelOnError: false,
      );

      // 启动心跳（30s ping）
      _startHeartbeat();

      // 注册身份
      _send({'type': 'REGISTER', 'user_id': _userId});
    } catch (e) {
      debugPrint('[WsClient] ❌ 连接失败: $e');
      _scheduleReconnect();
    }
  }

  // ── 消息处理 ─────────────────────────────────────────────────────
  void _onMessage(dynamic raw) {
    try {
      final json = jsonDecode(raw as String) as Map<String, dynamic>;
      final event = WsEvent.fromJson(json);
      if (!_controller.isClosed) _controller.add(event);
      debugPrint('[WsClient] ← ${event.type.name}');
    } catch (e) {
      debugPrint('[WsClient] 消息解析失败: $e');
    }
  }

  void _onError(Object error) {
    debugPrint('[WsClient] ⚠️ 错误: $error');
    _connected = false;
    _scheduleReconnect();
  }

  void _onDone() {
    debugPrint('[WsClient] 连接关闭');
    _connected = false;
    if (!_disposed) _scheduleReconnect();
  }

  // ── 发送消息 ─────────────────────────────────────────────────────
  void _send(Map<String, dynamic> data) {
    if (_channel == null) return;
    try {
      _channel!.sink.add(jsonEncode(data));
    } catch (e) {
      debugPrint('[WsClient] 发送失败: $e');
    }
  }

  void sendConfirm(String reminderId, String planId, String drugName) {
    if (kMockMode) return;
    _send({
      'type': 'DOSE_CONFIRMED',
      'payload': {
        'reminder_id': reminderId,
        'plan_id': planId,
        'drug_name': drugName,
        'confirmed_at': DateTime.now().toIso8601String(),
      },
    });
  }

  void sendSnooze(String reminderId, int snoozeMinutes) {
    if (kMockMode) return;
    _send({
      'type': 'DOSE_SNOOZED',
      'payload': {
        'reminder_id': reminderId,
        'snooze_minutes': snoozeMinutes,
      },
    });
  }

  // ── 心跳 ─────────────────────────────────────────────────────────
  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _send({'type': 'PING', 'ts': DateTime.now().millisecondsSinceEpoch});
    });
  }

  // ── 指数退避重连 ──────────────────────────────────────────────────
  void _scheduleReconnect() {
    if (_disposed || _reconnectAttempts >= _maxReconnectAttempts) return;

    _reconnectAttempts++;
    final delaySeconds = min(
      30,
      pow(2, _reconnectAttempts).toInt(),
    );
    debugPrint('[WsClient] 🔄 ${delaySeconds}s 后重连（第$_reconnectAttempts次）');

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: delaySeconds), _doConnect);
  }

  // ── Mock 事件模拟 ─────────────────────────────────────────────────
  // kMockMode=true 时，用 Timer 模拟真实事件流，方便开发调试
  void _startMockEvents() {
    _connected = true;
    debugPrint('[WsClient] 🟡 Mock 模式启动');

    // 30 秒后发一次演示提醒
    _mockTimer = Timer(const Duration(seconds: 30), () {
      if (_disposed || _controller.isClosed) return;
      _controller.add(WsEvent(
        type: WsEventType.reminderTrigger,
        payload: {
          'reminder_id': 'rem_mock_${DateTime.now().millisecondsSinceEpoch}',
          'plan_id': 'plan_001',
          'drug_name': '艾司唑仑片',
          'dosage': '1片',
          'scheduled_time': _nowHHMM(),
          'reminder_key': 'demo_key',
        },
      ));
      debugPrint('[WsClient] Mock REMINDER_TRIGGER 已触发');
    });
  }

  String _nowHHMM() {
    final now = DateTime.now();
    return '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
  }

  // ── 断开 & 清理 ───────────────────────────────────────────────────
  void disconnect() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _heartbeatTimer?.cancel();
    _mockTimer?.cancel();
    _channel?.sink.close();
    _connected = false;
    debugPrint('[WsClient] 已断开');
  }

  void dispose() {
    disconnect();
    _controller.close();
  }
}
