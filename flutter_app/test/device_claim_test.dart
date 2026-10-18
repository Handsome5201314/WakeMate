import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wakemate/core/api/rest_client.dart';
import 'package:wakemate/core/theme/wakemate_theme.dart';
import 'package:wakemate/features/device/device_page.dart';
import 'package:wakemate/shared/providers/auth_provider.dart';

class _DeviceApi extends WakeMateApi {
  _DeviceApi({this.devices = const []}) : super(Dio());

  List<dynamic> devices;
  int getDevicesCalls = 0;
  int bindCalls = 0;
  Future<Map<String, dynamic>> Function(String, String)? onBind;
  Object? loadError;
  Completer<List<dynamic>>? firstDevicesPending;

  @override
  Future<List<dynamic>> getDevices() async {
    getDevicesCalls++;
    if (loadError != null) throw loadError!;
    if (getDevicesCalls == 1 && firstDevicesPending != null) {
      return firstDevicesPending!.future;
    }
    return devices;
  }

  @override
  Future<Map<String, dynamic>> bindDevice({
    required String deviceSn,
    required String claimCode,
    CancelToken? cancelToken,
  }) async {
    bindCalls++;
    final callback = onBind;
    if (callback == null) return {'id': 'bound', 'device_sn': deviceSn};
    return callback(deviceSn, claimCode);
  }
}

Widget _app(ProviderContainer container) => UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: buildWakeMateTheme(), home: const DevicePage()),
    );

Map<String, dynamic> _device(String id, String sn,
        {String? lastSync, String status = 'offline'}) =>
    {
      'id': id,
      'device_sn': sn,
      'device_type': 'pillbox',
      'firmware_ver': null,
      'last_sync_at': lastSync,
      'state': {'status': status},
    };

class _SwitchingAuthNotifier extends AuthNotifier {
  @override
  Future<AuthState> build() async => const AuthState(
        status: AuthStatus.authenticated,
        userId: 'patient-a',
        role: 'patient',
      );

  void switchAccount(String? userId) {
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
  setUp(() {
    SharedPreferences.setMockInitialValues({
      kTokenKey: 'test-session',
      kUserIdKey: 'patient-a',
      'wm_role': 'patient',
    });
  });

  testWidgets('renders every bound device and preserves server status',
      (tester) async {
    final api = _DeviceApi(devices: [
      _device('a', 'BOARD-A'),
      _device('b', 'BOARD-B',
          lastSync: '2026-10-13T08:00:00Z', status: 'online'),
    ]);
    final container =
        ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);
    addTearDown(container.dispose);

    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();

    expect(find.text('已绑定设备（2）'), findsOneWidget);
    expect(find.text('BOARD-A'), findsOneWidget);
    expect(find.text('BOARD-B'), findsOneWidget);
    expect(find.text('尚未上报'), findsOneWidget);
    expect(find.text('在线'), findsOneWidget);
  });

  testWidgets('rejects empty claim fields before making a request',
      (tester) async {
    final api = _DeviceApi();
    final container =
        ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);
    addTearDown(container.dispose);
    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('claim-device-button')));
    await tester.pump();
    expect(api.bindCalls, 0);
    expect(find.text('请填写设备序列号和绑定码'), findsOneWidget);
  });

  testWidgets('shows a load error and recovers when retry succeeds',
      (tester) async {
    final api = _DeviceApi()..loadError = StateError('offline');
    final container =
        ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);
    addTearDown(container.dispose);
    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();
    expect(find.text('设备列表加载失败，请检查网络后重试'), findsOneWidget);
    api.loadError = null;
    api.devices = [_device('retry', 'BOARD-RETRY')];
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('BOARD-RETRY'), findsOneWidget);
    expect(find.text('设备列表加载失败，请检查网络后重试'), findsNothing);
  });

  testWidgets('ignores a stale device response after account switching',
      (tester) async {
    final api = _DeviceApi()
      ..devices = [_device('b', 'BOARD-B')]
      ..firstDevicesPending = Completer<List<dynamic>>();
    final container = ProviderContainer(overrides: [
      apiProvider.overrideWithValue(api),
      authProvider.overrideWith(_SwitchingAuthNotifier.new),
    ]);
    addTearDown(container.dispose);
    await container.read(authProvider.future);
    await tester.pumpWidget(_app(container));
    await tester.pump();
    (container.read(authProvider.notifier) as _SwitchingAuthNotifier)
        .switchAccount('patient-b');
    await container.pump();
    await tester.pumpAndSettle();
    expect(find.text('BOARD-B'), findsOneWidget);
    api.firstDevicesPending!.complete([_device('a', 'BOARD-A')]);
    await tester.pumpAndSettle();
    expect(find.text('BOARD-A'), findsNothing);
    expect(find.text('BOARD-B'), findsOneWidget);
  });

  testWidgets('claims device, clears credentials, and refreshes the list',
      (tester) async {
    final api = _DeviceApi();
    api.onBind = (sn, _) async {
      api.devices = [_device('new', sn, lastSync: '2026-10-13T08:00:00Z')];
      return {'id': 'new', 'device_sn': sn};
    };
    final container =
        ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);
    addTearDown(container.dispose);

    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('device-sn-field')), 'BOARD-NEW');
    await tester.enterText(
        find.byKey(const ValueKey('claim-code-field')), 'claim-code');
    await tester.tap(find.byKey(const ValueKey('claim-device-button')));
    await tester.pumpAndSettle();

    expect(api.bindCalls, 1);
    expect(api.getDevicesCalls, 2);
    expect(find.text('BOARD-NEW'), findsOneWidget);
    expect(find.text('当前账号还没有绑定醒伴设备'), findsNothing);
    expect(find.text('24 小时内有效'), findsOneWidget);
    expect(find.byKey(const ValueKey('claim-error')), findsNothing);
  });

  testWidgets('shows claim error and keeps entered values for retry',
      (tester) async {
    final api = _DeviceApi();
    api.onBind = (_, __) async => throw DioException(
          requestOptions: RequestOptions(path: '/api/device/bind'),
          response: Response(
            requestOptions: RequestOptions(path: '/api/device/bind'),
            statusCode: 403,
          ),
        );
    final container =
        ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);
    addTearDown(container.dispose);

    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('device-sn-field')), 'BOARD-USED');
    await tester.enterText(
        find.byKey(const ValueKey('claim-code-field')), 'expired-code');
    await tester.tap(find.byKey(const ValueKey('claim-device-button')));
    await tester.pumpAndSettle();

    expect(find.text('绑定码无效、已使用或已过期，请向管理员重新获取。'), findsOneWidget);
    expect(find.widgetWithText(TextField, '设备序列号'), findsOneWidget);
    expect(
        (tester.widget<TextField>(
                find.byKey(const ValueKey('device-sn-field'))))
            .controller!
            .text,
        'BOARD-USED');
    expect(
        (tester.widget<TextField>(
                find.byKey(const ValueKey('claim-code-field'))))
            .controller!
            .text,
        'expired-code');
  });

  testWidgets('does not submit twice while claim is pending', (tester) async {
    final api = _DeviceApi();
    final pending = Completer<Map<String, dynamic>>();
    api.onBind = (_, __) => pending.future;
    final container =
        ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);
    addTearDown(container.dispose);

    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('device-sn-field')), 'BOARD-PENDING');
    await tester.enterText(
        find.byKey(const ValueKey('claim-code-field')), 'claim-code');
    await tester.tap(find.byKey(const ValueKey('claim-device-button')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('claim-device-button')));
    expect(api.bindCalls, 1);
    expect(find.text('绑定中…'), findsOneWidget);

    pending.complete({'id': 'pending', 'device_sn': 'BOARD-PENDING'});
    await tester.pumpAndSettle();
  });

  testWidgets('device page fits a narrow viewport without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer(
        overrides: [apiProvider.overrideWithValue(_DeviceApi())]);
    addTearDown(container.dispose);
    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
