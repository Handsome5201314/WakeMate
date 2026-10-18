import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakemate/core/api/rest_client.dart';
import 'package:wakemate/shared/providers/auth_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer server;
  late ProviderContainer container;
  late Dio dio;
  HttpOverrides? previousHttpOverrides;

  setUp(() async {
    // These contract tests own a loopback server. Restore real HttpClient only
    // within this test isolate; widget tests retain Flutter's offline client.
    previousHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    container = ProviderContainer();
    dio = container.read(dioProvider);
    dio.options.baseUrl = 'http://127.0.0.1:${server.port}';
  });

  tearDown(() async {
    await server.close(force: true);
    dio.close(force: true);
    container.dispose();
    HttpOverrides.global = previousHttpOverrides;
  });

  test(
    'registration sends account fields and stores the returned identity',
    () async {
      final observed = Completer<Map<String, dynamic>>();
      server.listen((request) async {
        final body = jsonDecode(
          await utf8.decoder.bind(request).join(),
        ) as Map<String, dynamic>;
        observed.complete({'path': request.uri.path, 'body': body});
        request.response
          ..statusCode = 201
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'access_token': 'registration-session',
              'user_id': 'registered-patient',
              'role': 'patient',
              'expires_in': 3600,
            }),
          );
        await request.response.close();
      });
      await container.read(authProvider.future);
      await container
          .read(authProvider.notifier)
          .register(
            username: ' New_Account ',
            password: ' password-with-spaces ',
            displayName: ' 小醒用户 ',
          );

      final sent = await observed.future;
      expect(sent['path'], '/api/auth/register');
      expect(sent['body'], {
        'username': 'New_Account',
        'password': ' password-with-spaces ',
        'display_name': '小醒用户',
        'timezone': 'Asia/Shanghai',
      });
      final state = container.read(authProvider).requireValue;
      expect(state.isAuthenticated, isTrue);
      expect(state.userId, 'registered-patient');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kTokenKey), 'registration-session');
      expect(prefs.getString(kUserIdKey), 'registered-patient');
    },
    skip: kMockMode,
  );

  test(
    'password login uses the server contract and preserves password spaces',
    () async {
      final observed = Completer<Map<String, dynamic>>();
      server.listen((request) async {
        observed.complete({
          'path': request.uri.path,
          'body': jsonDecode(await utf8.decoder.bind(request).join()),
        });
        request.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'access_token': 'login-session',
              'user_id': 'same-patient',
              'role': 'patient',
            }),
          );
        await request.response.close();
      });
      await container.read(authProvider.future);
      await container
          .read(authProvider.notifier)
          .loginWithPassword(' Patient_1 ', ' password-with-spaces ');
      final sent = await observed.future;
      expect(sent['path'], '/api/auth/password');
      expect(sent['body'], {
        'username': 'Patient_1',
        'password': ' password-with-spaces ',
      });
      expect(container.read(authProvider).requireValue.userId, 'same-patient');
    },
    skip: kMockMode,
  );

  test(
    'unauthorized API response clears every identity field and auth state',
    () async {
      SharedPreferences.setMockInitialValues({
        kTokenKey: 'expired-session',
        kUserIdKey: 'expired-patient',
        'wm_role': 'patient',
      });
      await container.read(authProvider.future);
      server.listen((request) async {
        request.response
          ..statusCode = 401
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'detail': 'Invalid or expired session'}));
        await request.response.close();
      });

      await expectLater(dio.get('/api/plans'), throwsA(isA<DioException>()));
      expect(
        (await container.read(authProvider.future)).isAuthenticated,
        isFalse,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kTokenKey), isNull);
      expect(prefs.getString(kUserIdKey), isNull);
      expect(prefs.getString('wm_role'), isNull);
    },
  );

  test(
    'late unauthorized response from an older account preserves new login',
    () async {
      SharedPreferences.setMockInitialValues({
        kTokenKey: 'old-session',
        kUserIdKey: 'old-patient',
        'wm_role': 'patient',
      });
      final received = Completer<void>();
      final release = Completer<void>();
      server.listen((request) async {
        expect(request.headers.value('Authorization'), 'Bearer old-session');
        received.complete();
        await release.future;
        request.response
          ..statusCode = 401
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'detail': 'Invalid or expired session'}));
        await request.response.close();
      });
      final request = dio.get('/api/plans');
      final expectation = expectLater(request, throwsA(isA<DioException>()));
      await received.future;
      await mutateStoredSession((prefs) async {
        await prefs.setString(kTokenKey, 'new-session');
        await prefs.setString(kUserIdKey, 'new-patient');
        await prefs.setString('wm_role', 'patient');
      });
      release.complete();
      await expectation;
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kTokenKey), 'new-session');
      expect(prefs.getString(kUserIdKey), 'new-patient');
      expect(prefs.getString('wm_role'), 'patient');
      expect(container.read(sessionVersionProvider), 0);
    },
  );
}
