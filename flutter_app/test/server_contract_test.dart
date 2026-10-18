import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'package:wakemate/core/api/rest_client.dart';
import 'package:wakemate/core/medication/dose_schedule.dart';
import 'package:wakemate/shared/providers/auth_provider.dart';

// Only run against verification/serve-ui-qa.py's disposable PostgreSQL schema.
// The QA administrator below is isolated and never a production credential.
const _runContract = bool.fromEnvironment('WAKEMATE_SERVICE_CONTRACT');

void main() {
  test(
    'Flutter client registers, confirms persisted doses and reaches admin',
    () async {
      expect(kMockMode, false);
      final uri = Uri.parse(kBaseUrl);
      expect(uri.host, '127.0.0.1');
      expect(uri.port, 18093);
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      final adminDio = Dio(BaseOptions(baseUrl: kBaseUrl));
      addTearDown(() {
        container.read(dioProvider).close(force: true);
        container.dispose();
        adminDio.close(force: true);
      });
      await container.read(authProvider.future);
      final auth = container.read(authProvider.notifier);
      final account = 'app_${DateTime.now().microsecondsSinceEpoch}';
      const password = 'App-contract-password-2026';
      await auth.register(
        username: account,
        password: password,
        timezone: 'UTC',
      );
      final identity = container.read(authProvider).requireValue;
      expect(identity.role, 'patient');
      final api = container.read(apiProvider);
      final me = await api.getMe();
      expect(me['id'], identity.userId);
      expect(me['username'], account);
      expect(me['phone_masked'], null);
      final plan = await api.createPlan({
        'drug_name': 'Isolated contract medicine',
        'dosage': '1 tablet',
        'times': ['00:00'],
        'timezone': 'UTC',
      });
      final doses = actionableDoses(await api.getDoses());
      expect(doses.length, 1);
      final dose = doses.single;
      expect(dose['plan_id'], plan['id']);
      final operationId = const Uuid().v4();
      final confirmation = await api.confirmDose({
        'dose_instance_id': dose['id'],
        'confirmed_by': 'user_tap',
      }, idempotencyKey: operationId);
      expect(confirmation['data']['id'], dose['id']);
      expect(confirmation['data']['status'], 'confirmed');
      final replay = await api.confirmDose({
        'dose_instance_id': dose['id'],
        'confirmed_by': 'user_tap',
      }, idempotencyKey: operationId);
      expect(replay, confirmation);
      expect(actionableDoses(await api.getDoses()), isEmpty);
      final records = await api.getRecords();
      expect(records.single['id'], dose['id']);
      final stats = await api.getStats();
      expect(stats.last['ontime'] + stats.last['late'], 1);
      expect(stats.last['unconfirmed'], 0);
      expect(stats.last['pending'], 0);
      await api.updateSettings({'quiet_start': '23:00'});
      expect((await api.getSettings())['quiet_start'], '23:00');
      expect(await api.getDevices(), isEmpty);
      await auth.logout();
      await auth.loginWithPassword(account, password);
      expect(container.read(authProvider).requireValue.userId, identity.userId);
      final admin = await WakeMateApi(adminDio)
          .passwordLogin('admin', 'Qa-admin-password-2026');
      adminDio.options.headers['Authorization'] =
          'Bearer ${admin['access_token']}';
      final listed = await adminDio.get('/api/admin/patients');
      expect((listed.data as List).single['id'], identity.userId);
      expect((listed.data as List).single['username'], account);
      await auth.logout();
      await auth.register(
        username: '${account}_b',
        password: password,
        timezone: 'UTC',
      );
      expect(await api.getPlans(), isEmpty);
      expect(await api.getRecords(), isEmpty);
      await expectLater(
        api.confirmDose({
          'dose_instance_id': dose['id'],
          'confirmed_by': 'user_tap',
        }, idempotencyKey: const Uuid().v4()),
        throwsA(
          isA<DioException>().having(
            (error) => error.response?.statusCode,
            'patient isolation',
            404,
          ),
        ),
      );
    },
    skip: !_runContract,
    timeout: const Timeout(Duration(seconds: 45)),
  );
}
