import 'package:flutter_test/flutter_test.dart';
import 'package:wakemate/core/medication/dose_schedule.dart';

Map<String, dynamic> dose(String id, String time, String status) => {
  'id': id,
  'scheduled_time': time,
  'status': status,
};

void main() {
  test('server timezone offsets represent the same instant', () {
    expect(
      doseScheduledTime(dose('one', '2026-10-13T08:00:00+08:00', 'pending')),
      doseScheduledTime(dose('one', '2026-10-13T00:00:00Z', 'pending')),
    );
  });

  test(
    'pending and unconfirmed doses retain persisted identity and ordering',
    () {
      final later = dose('persisted-later', '2026-10-13T08:00:00Z', 'pending');
      final earlier = dose(
        'persisted-earlier',
        '2026-10-13T07:00:00Z',
        'unconfirmed',
      );
      final rows = actionableDoses([
        later,
        dose('old-version', '2026-10-13T06:00:00Z', 'cancelled'),
        dose('already-confirmed', '2026-10-13T05:00:00Z', 'confirmed'),
        earlier,
      ]);
      expect(rows, [earlier, later]);
      expect(identical(rows.first, earlier), true);
    },
  );

  test('ambiguous phone-local times and invalid identities are rejected', () {
    expect(
      () => doseScheduledTime(dose('one', '2026-10-13T08:00:00', 'pending')),
      throwsFormatException,
    );
    expect(
      () => actionableDoses([dose('', '2026-10-13T08:00:00Z', 'pending')]),
      throwsFormatException,
    );
    expect(
      () => actionableDoses([dose('one', '2026-10-13T08:00:00Z', 'missed')]),
      throwsFormatException,
    );
  });

  test('an older snoozed dose does not block a later due dose', () {
    final now = DateTime.parse('2026-10-13T10:00:00Z');
    final old = dose('old', '2026-10-13T08:00:00Z', 'unconfirmed');
    final later = dose('later', '2026-10-13T09:30:00Z', 'unconfirmed');
    expect(
      nextReminderDose(
        [old, later],
        now,
        remindedDoseIds: {'old'},
        snoozedUntil: const {},
      )?['id'],
      'later',
    );
    expect(nextCountdownDose([old, later], now)?['id'], 'later');
  });

  test('a snooze only suppresses its own dose until the deadline', () {
    final now = DateTime.parse('2026-10-13T10:00:00Z');
    final old = dose('old', '2026-10-13T08:00:00Z', 'unconfirmed');
    final later = dose('later', '2026-10-13T09:30:00Z', 'unconfirmed');
    expect(
      nextReminderDose(
        [old, later],
        now,
        remindedDoseIds: const {},
        snoozedUntil: {'old': now.add(const Duration(minutes: 5))},
      )?['id'],
      'later',
    );
    expect(
      nextReminderDose(
        [old],
        now.add(const Duration(minutes: 6)),
        remindedDoseIds: const {},
        snoozedUntil: {'old': now.add(const Duration(minutes: 5))},
      )?['id'],
      'old',
    );
  });
}
