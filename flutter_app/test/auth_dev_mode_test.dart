import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wakemate/core/api/rest_client.dart';

void main() {
  test('production build rejects local bypass', () async {
    if (kDevAuthBypass) return;

    final api = WakeMateApi(Dio());
    await expectLater(
      api.loginAsDev(),
      throwsA(isA<StateError>()),
    );
  });

  test('mock build creates a local session without network', () async {
    if (!kDevAuthBypass) return;

    final api = WakeMateApi(Dio());
    final session = await api.loginAsDev();

    expect(session['access_token'], 'dev-wakemate-token');
    expect(session['user_id'], 'dev-user');
    expect(session['role'], 'patient');
  });
}
