import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wakemate/core/api/rest_client.dart';
import 'package:wakemate/core/theme/wakemate_theme.dart';
import 'package:wakemate/features/home/home_page.dart';
import 'package:wakemate/features/stats/stats_page.dart';

class _MedicationApi extends WakeMateApi {
  _MedicationApi() : super(Dio()) {
    final now = DateTime.now().toUtc();
    doses = [
      _dose(
        'old-dose',
        'Earlier medicine',
        now.subtract(const Duration(minutes: 6)),
      ),
      _dose(
        'later-dose',
        'Later medicine',
        now.subtract(const Duration(minutes: 3)),
      ),
    ];
  }

  late final List<Map<String, dynamic>> doses;
  int statsRequests = 0;
  String? confirmedId;
  String? confirmationKey;

  Map<String, dynamic> _dose(String id, String drug, DateTime scheduled) => {
        'id': id,
        'dose_instance_id': id,
        'drug_name': drug,
        'dosage': '1片',
        'scheduled_time': scheduled.toIso8601String(),
        'status': 'unconfirmed',
      };

  @override
  Future<List<dynamic>> getDoses({String? date}) async => doses;

  @override
  Future<List<dynamic>> getPlans() async => [];

  @override
  Future<List<dynamic>> getDevices() async => [];

  @override
  Future<List<dynamic>> getStats({int days = 30}) async {
    statsRequests++;
    final confirmed =
        doses.where((dose) => dose['status'] == 'confirmed').length;
    return List.generate(
      days,
      (index) => {
        'date': DateTime.now()
            .subtract(Duration(days: days - 1 - index))
            .toIso8601String()
            .substring(0, 10),
        'total': index == days - 1 ? doses.length : 0,
        'ontime': index == days - 1 ? confirmed : 0,
        'late': 0,
        'unconfirmed': index == days - 1 ? doses.length - confirmed : 0,
        'pending': 0,
        'rate': index == days - 1 ? confirmed * 100.0 / doses.length : 0.0,
        'streak_days': 0,
      },
    );
  }

  @override
  Future<Map<String, dynamic>> confirmDose(
    Map<String, dynamic> data, {
    required String idempotencyKey,
  }) async {
    confirmedId = data['dose_instance_id'] as String;
    confirmationKey = idempotencyKey;
    final selected = doses.singleWhere((dose) => dose['id'] == confirmedId);
    selected['status'] = 'confirmed';
    return {'message': 'Medication confirmation saved', 'data': selected};
  }
}

Widget _app(ProviderContainer container, Widget page) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: buildWakeMateTheme(), home: page),
    );

void main() {
  testWidgets('snoozing an earlier dose allows the later due reminder', (
    tester,
  ) async {
    final api = _MedicationApi();
    final container = ProviderContainer(
      overrides: [apiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(_app(container, const HomePage()));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('请确认这次服药'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('reminder-dose-old-dose')), findsOneWidget);
    await tester.tap(find.text('稍后提醒'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('请确认这次服药'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('reminder-dose-later-dose')), findsOneWidget);
    expect(api.confirmedId, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'selecting a later real dose confirms that identity and refreshes cached stats',
    (tester) async {
      final api = _MedicationApi();
      final container = ProviderContainer(
        overrides: [apiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(_app(container, const StatsPage()));
      await tester.pumpAndSettle();
      expect(find.text('0%'), findsWidgets);
      expect(api.statsRequests, 1);

      await tester.pumpWidget(_app(container, const HomePage()));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('view-dose-later-dose')),
      );
      await tester.tap(find.byKey(const ValueKey('view-dose-later-dose')));
      await tester.pump();
      expect(find.text('请确认这次服药'), findsOneWidget);
      await tester.tap(find.text('已服用 ✓'));
      await tester.pumpAndSettle();
      expect(api.confirmedId, 'later-dose');
      expect(api.confirmationKey, isNotEmpty);
      expect(api.doses.first['status'], 'unconfirmed');

      await tester.pumpWidget(_app(container, const StatsPage()));
      await tester.pumpAndSettle();
      expect(find.text('50%'), findsWidgets);
      expect(api.statsRequests, 2);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
