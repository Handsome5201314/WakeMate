import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wakemate/core/xiaozhi/xiaozhi_models.dart';
import 'package:wakemate/core/xiaozhi/xiaozhi_realtime_client.dart';

class _BlockedDisconnectClient extends XiaozhiRealtimeClient {
  final entered = Completer<void>();
  final release = Completer<void>();
  bool _blocked = false;

  @override
  Future<void> disconnect() async {
    if (!_blocked) {
      _blocked = true;
      entered.complete();
      await release.future;
    }
    await super.disconnect();
  }
}

XiaozhiOtaResult _ota(int port) => XiaozhiOtaResult.fromJson({
  'websocket': {'url': 'ws://127.0.0.1:$port/xiaozhi/v1/', 'version': 1},
});

void main() {
  test(
    'dispose during disconnect prevents opening an old account socket',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var requestCount = 0;
      server.listen((request) {
        requestCount++;
        request.response.close();
      });
      final client = _BlockedDisconnectClient();
      final connecting = client.connect(
        ota: _ota(server.port),
        deviceId: '02:01:02:03:04:05',
        clientId: 'patient-a-device',
      );
      final expectation = expectLater(connecting, throwsStateError);
      await client.entered.future;
      await client.dispose();
      client.release.complete();
      await expectation;

      expect(client.isReady, isFalse);
      expect(requestCount, 0);
    },
  );

  test(
    'dispose cancels a pending handshake and ignores a late server hello',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final received = Completer<WebSocket>();
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen((message) {
          final json = jsonDecode(message as String) as Map<String, dynamic>;
          if (json['type'] == 'hello' && !received.isCompleted) {
            received.complete(socket);
          }
        });
      });
      final client = XiaozhiRealtimeClient();
      final connecting = client.connect(
        ota: _ota(server.port),
        deviceId: '02:01:02:03:04:05',
        clientId: 'patient-a-device',
      );
      final expectation = expectLater(connecting, throwsStateError);
      final socket = await received.future;
      final disposing = client.dispose();
      if (socket.readyState == WebSocket.open) {
        socket.add(
          jsonEncode({
            'type': 'hello',
            'transport': 'websocket',
            'session_id': 'late-session',
          }),
        );
      }
      await disposing;
      await expectation;
      await expectLater(
        client.connect(
          ota: _ota(server.port),
          deviceId: '02:01:02:03:04:05',
          clientId: 'patient-a-device',
        ),
        throwsStateError,
      );
      expect(client.state, XiaozhiConnectionState.disconnected);
      expect(client.isReady, isFalse);
    },
  );
}
