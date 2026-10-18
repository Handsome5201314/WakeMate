import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wakemate/core/xiaozhi/xiaozhi_identity_store.dart';
import 'package:wakemate/core/xiaozhi/xiaozhi_ota_service.dart';
import 'package:wakemate/core/xiaozhi/xiaozhi_session.dart';
import 'package:wakemate/shared/providers/auth_provider.dart';

class _AccountNotifier extends AuthNotifier {
  @override
  Future<AuthState> build() async => const AuthState(
    status: AuthStatus.authenticated,
    userId: 'patient-a',
    role: 'patient',
  );

  void switchTo(String? userId) {
    state = AsyncData(
      AuthState(
        status: userId == null
            ? AuthStatus.unauthenticated
            : AuthStatus.authenticated,
        userId: userId,
        role: userId == null ? null : 'patient',
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'keeps distinct stable device identities for each WakeMate account',
    () async {
      final accountA = XiaozhiIdentityStore(userId: 'patient-a');
      final accountB = XiaozhiIdentityStore(userId: 'patient-b');
      final firstA = await accountA.loadOrCreate();
      final firstB = await accountB.loadOrCreate();
      final returningA = await XiaozhiIdentityStore(userId: 'patient-a')
          .loadOrCreate();

      expect(firstA.deviceId, isNot(firstB.deviceId));
      expect(firstA.clientId, isNot(firstB.clientId));
      expect(returningA.deviceId, firstA.deviceId);
      expect(returningA.clientId, firstA.clientId);
    },
  );

  test(
    'never adopts an unowned legacy identity or cached OTA credential',
    () async {
      SharedPreferences.setMockInitialValues({
        'xiaozhi_device_id': '02:01:02:03:04:05',
        'xiaozhi_client_id': 'legacy-client',
        'xiaozhi_token': 'legacy-secret',
        'xiaozhi_ws_url': 'wss://legacy.example.test/',
        'xiaozhi_protocol_version': 1,
        'unrelated_preference': 'keep',
      });
      final identity = await XiaozhiIdentityStore(userId: 'patient-a')
          .loadOrCreate();
      final prefs = await SharedPreferences.getInstance();

      expect(identity.deviceId, isNot('02:01:02:03:04:05'));
      expect(identity.clientId, isNot('legacy-client'));
      expect(prefs.containsKey('xiaozhi_token'), isFalse);
      expect(prefs.containsKey('xiaozhi_ws_url'), isFalse);
      expect(prefs.getString('unrelated_preference'), 'keep');
    },
  );

  test(
    'concurrent sessions for one account keep a single device identity',
    () async {
      final identities = await Future.wait(
        List.generate(
          4,
          (_) => XiaozhiIdentityStore(userId: 'patient-a').loadOrCreate(),
        ),
      );
      expect(identities.map((item) => item.deviceId).toSet(), hasLength(1));
      expect(identities.map((item) => item.clientId).toSet(), hasLength(1));
    },
  );

  test(
    'OTA and activation use the same scoped identity without saving tokens',
    () async {
      final store = XiaozhiIdentityStore(userId: 'patient-a');
      final identity = await store.loadOrCreate();
      final requests = <http.Request>[];
      final ota = XiaozhiOtaService(
        identityStore: store,
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('/activate')) {
            return http.Response('{}', 200);
          }
          return http.Response(
            jsonEncode({
              'websocket': {
                'url': 'wss://example.test/xiaozhi/v1/',
                'token': 'runtime-only-token',
                'version': 1,
              },
            }),
            200,
          );
        }),
      );
      addTearDown(ota.dispose);
      final result = await ota.checkVersion();
      await ota.activate(ota: result);
      final prefs = await SharedPreferences.getInstance();

      expect(result.token, 'runtime-only-token');
      expect(requests, hasLength(2));
      for (final request in requests) {
        expect(request.headers['Device-Id'], identity.deviceId);
        expect(request.headers['Client-Id'], identity.clientId);
      }
      expect(prefs.containsKey('xiaozhi_token'), isFalse);
      expect(prefs.containsKey('xiaozhi_ws_url'), isFalse);
    },
  );

  test(
    'switching or signing out disposes the previous account session',
    () async {
      final container = ProviderContainer(
        overrides: [authProvider.overrideWith(_AccountNotifier.new)],
      );
      addTearDown(container.dispose);
      await container.read(authProvider.future);
      final first = container.read(xiaozhiSessionProvider);
      final firstIdentity = await first.identityStore.loadOrCreate();
      expect(identical(first.ota.identityStore, first.identityStore), isTrue);

      (container.read(authProvider.notifier) as _AccountNotifier).switchTo(
        'patient-b',
      );
      await container.pump();
      final second = container.read(xiaozhiSessionProvider);
      final secondIdentity = await second.identityStore.loadOrCreate();
      expect(first.isDisposed, isTrue);
      expect(firstIdentity.deviceId, isNot(secondIdentity.deviceId));
      await expectLater(first.connect(), throwsStateError);

      (container.read(authProvider.notifier) as _AccountNotifier).switchTo(
        null,
      );
      await container.pump();
      expect(second.isDisposed, isTrue);
      expect(() => container.read(xiaozhiSessionProvider), throwsStateError);
    },
  );

  test(
    'a disposed OTA response cannot reopen the previous account session',
    () async {
      final response = Completer<http.Response>();
      final received = Completer<void>();
      final store = XiaozhiIdentityStore(userId: 'patient-a');
      final ota = XiaozhiOtaService(
        identityStore: store,
        client: MockClient((_) {
          received.complete();
          return response.future;
        }),
      );
      final session = XiaozhiSession(identityStore: store, ota: ota);
      final connecting = session.connect();
      final expectation = expectLater(connecting, throwsStateError);
      await received.future;
      await session.dispose();
      response.complete(
        http.Response(
          jsonEncode({
            'websocket': {
              'url': 'wss://example.test/xiaozhi/v1/',
              'token': 'runtime-only-token',
            },
          }),
          200,
        ),
      );
      await expectation;
      expect(session.isReady, isFalse);
    },
  );
}
