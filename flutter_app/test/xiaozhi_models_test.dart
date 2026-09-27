import 'package:flutter_test/flutter_test.dart';

import 'package:wakemate/core/xiaozhi/xiaozhi_models.dart';

void main() {
  test('parses OTA websocket and activation fields', () {
    final result = XiaozhiOtaResult.fromJson({
      'activation': {
        'code': '123456',
        'message': '请完成绑定',
        'challenge': 'challenge-value',
        'timeout_ms': 30000,
      },
      'websocket': {
        'url': 'wss://example.test/xiaozhi/v1/',
        'token': 'token-value',
        'version': 1,
      },
    });

    expect(result.requiresActivation, isTrue);
    expect(result.activationCode, '123456');
    expect(result.activationMessage, '请完成绑定');
    expect(result.activationChallenge, 'challenge-value');
    expect(result.activationTimeout, const Duration(seconds: 30));
    expect(result.websocketUrl.toString(), 'wss://example.test/xiaozhi/v1/');
    expect(result.token, 'token-value');
    expect(result.protocolVersion, 1);
  });

  test('parses server text events without dropping unknown fields', () {
    final event = XiaozhiTextEvent.fromJson({
      'type': 'tts',
      'state': 'sentence_start',
      'text': '测试成功',
      'session_id': 'session-1',
    });

    expect(event.type, 'tts');
    expect(event.state, 'sentence_start');
    expect(event.text, '测试成功');
    expect(event.raw['session_id'], 'session-1');
  });

  test('parses compact top-level OTA websocket response', () {
    final result = XiaozhiOtaResult.fromJson({
      'url': 'wss://example.test/xiaozhi/v1/',
      'token': 'test-token',
      'version': 2,
    });

    expect(result.canConnect, isTrue);
    expect(result.websocketUrl.toString(), 'wss://example.test/xiaozhi/v1/');
    expect(result.token, 'test-token');
    expect(result.protocolVersion, 2);
  });
}
