// lib/core/api/openai_client.dart
// OpenAI 兼容接口 · SSE 流式调用
// POST /v1/chat/completions → 小醒 AI 对话
// 醒伴 WakeMate Flutter APP

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'rest_client.dart';

// 消息数据结构
class ChatMsg {
  final String role; // user | assistant | system
  final String content;
  final String? pose; // gentle | calm | soothe（assistant 时有值）
  final String? intent;

  const ChatMsg({
    required this.role,
    required this.content,
    this.pose,
    this.intent,
  });

  Map<String, dynamic> toJson() => {'role': role, 'content': content};
}

// 流式 chunk
class StreamChunk {
  final String delta; // 本次增量文字
  final bool isDone; // 是否结束
  final String? pose; // 小醒姿态
  final String? intent; // 识别到的意图
  final List<dynamic>? mcpResults; // MCP 工具执行结果

  const StreamChunk({
    required this.delta,
    this.isDone = false,
    this.pose,
    this.intent,
    this.mcpResults,
  });
}

class XiaoxingChatClient {
  XiaoxingChatClient();

  /// 流式调用小醒 AI
  /// 返回 Stream<StreamChunk>，调用方用 StreamBuilder 或 await for 消费
  Stream<StreamChunk> chatStream({
    required List<ChatMsg> messages,
    String sessionType = 'patient',
    String model = 'xiaoxing-v1',
  }) async* {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(kTokenKey) ?? '';

    final request = http.Request(
      'POST',
      Uri.parse('$kBaseUrl/v1/chat/completions'),
    );
    request.headers.addAll({
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
      'Accept': 'text/event-stream',
    });
    request.body = jsonEncode({
      'model': model,
      'messages': messages.map((m) => m.toJson()).toList(),
      'stream': true,
      'session_type': sessionType,
    });

    try {
      final client = http.Client();
      final streamedResponse = await client.send(request);

      String pose = 'calm';
      String intent = 'general';

      await for (final chunk in streamedResponse.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (chunk.isEmpty) continue;
        if (!chunk.startsWith('data: ')) continue;

        final data = chunk.substring(6).trim();
        if (data == '[DONE]') {
          yield StreamChunk(
              delta: '', isDone: true, pose: pose, intent: intent);
          break;
        }

        try {
          final json = jsonDecode(data) as Map<String, dynamic>;
          final choices = json['choices'] as List<dynamic>?;
          final delta = choices?.first['delta']?['content'] as String? ?? '';
          pose = json['xiaoxing_pose'] as String? ?? pose;
          intent = json['xiaoxing_intent'] as String? ?? intent;
          final mcpResults = json['mcp_results'] as List<dynamic>?;

          if (delta.isNotEmpty || mcpResults != null) {
            yield StreamChunk(
              delta: delta,
              pose: pose,
              intent: intent,
              mcpResults: mcpResults,
            );
          }
        } catch (_) {
          continue;
        }
      }
      client.close();
    } catch (e) {
      if (kMockMode) {
        yield* _mockStream(messages.last.content);
      } else {
        rethrow;
      }
    }
  }

  /// Mock 流式响应（网络不可用时降级）
  Stream<StreamChunk> _mockStream(String userInput) async* {
    const mockResponses = {
      '漏': '没关系，有时候忘记是完全正常的。现在补服还来得及，请参考医嘱的补服建议～',
      '吃了': '太好了 ✓ 记录已更新，今天这次按时完成了。',
      '睡不着': '睡前可以试试 4-7-8 呼吸法：吸气 4 秒，屏气 7 秒，呼气 8 秒。',
    };

    String response = '嗯嗯，我在听 💙 有什么需要随时告诉我。';
    String pose = 'calm';

    for (final entry in mockResponses.entries) {
      if (userInput.contains(entry.key)) {
        response = entry.value;
        pose = userInput.contains('漏') ? 'soothe' : 'gentle';
        break;
      }
    }

    for (final char in response.split('')) {
      await Future.delayed(const Duration(milliseconds: 40));
      yield StreamChunk(delta: char, pose: pose, intent: 'mock');
    }
    yield StreamChunk(delta: '', isDone: true, pose: pose, intent: 'mock');
  }
}

final chatClientProvider =
    Provider<XiaoxingChatClient>((_) => XiaoxingChatClient());
