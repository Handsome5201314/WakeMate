import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wakemate/core/api/rest_client.dart';
import 'package:wakemate/features/settings/settings_page.dart';
import 'package:wakemate/shared/providers/auth_provider.dart';

class _SettingsApi extends WakeMateApi {
  _SettingsApi() : super(Dio());

  @override
  Future<Map<String, dynamic>> getSettings() async => {
    'family_push_enabled': true,
    'quiet_start': '22:00',
    'quiet_end': '07:00',
  };

  @override
  Future<List<dynamic>> getDevices() async => [];
}

void main() {
  testWidgets('production settings logs out without erasing device identity', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      kTokenKey: 'test-session',
      kUserIdKey: 'patient-a',
      'wm_role': 'patient',
      'xiaozhi_patient-a_device_id': '02:01:02:03:04:05',
      'unrelated_preference': 'keep',
    });
    final container = ProviderContainer(
      overrides: [apiProvider.overrideWithValue(_SettingsApi())],
    );
    addTearDown(container.dispose);
    await container.read(authProvider.future);
    final router = GoRouter(
      initialLocation: '/settings',
      routes: [
        GoRoute(path: '/settings', builder: (_, __) => const SettingsPage()),
        GoRoute(
          path: '/login',
          builder: (_, __) => const Scaffold(body: Text('login destination')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('退出登录'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    if (!kMockMode) {
      expect(find.text('清除本地演示设置'), findsNothing);
      expect(find.text('清除演示数据'), findsNothing);
    }
    await tester.tap(find.text('退出登录'));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(kTokenKey), isFalse);
    expect(prefs.containsKey(kUserIdKey), isFalse);
    expect(prefs.containsKey('wm_role'), isFalse);
    expect(prefs.getString('xiaozhi_patient-a_device_id'), '02:01:02:03:04:05');
    expect(prefs.getString('unrelated_preference'), 'keep');
    expect(container.read(authProvider).valueOrNull?.isAuthenticated, isFalse);
    expect(find.text('login destination'), findsOneWidget);
  });
}
