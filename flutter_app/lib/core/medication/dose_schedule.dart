/// The service owns dose identity and scheduled instants; the phone only
/// selects and displays those persisted doses.
DateTime doseScheduledTime(Map<String, dynamic> dose) {
  final value = dose['scheduled_time'];
  if (value is! String ||
      !RegExp(r'(Z|[+-]\d{2}:\d{2})$', caseSensitive: false).hasMatch(value)) {
    throw const FormatException('剂次缺少带时区的服药时间');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) throw const FormatException('剂次服药时间无效');
  return parsed.toUtc();
}

List<Map<String, dynamic>> actionableDoses(List<dynamic> doses) {
  final result = <Map<String, dynamic>>[];
  for (final item in doses) {
    if (item is! Map<String, dynamic> ||
        item['id'] is! String ||
        (item['id'] as String).isEmpty) {
      throw const FormatException('剂次缺少服务端标识');
    }
    doseScheduledTime(item);
    final status = item['status'];
    if (![
      'pending',
      'unconfirmed',
      'confirmed',
      'cancelled',
    ].contains(status)) {
      throw const FormatException('剂次状态无效');
    }
    if (status == 'pending' || status == 'unconfirmed') result.add(item);
  }
  result.sort(
    (left, right) =>
        doseScheduledTime(left).compareTo(doseScheduledTime(right)),
  );
  return result;
}

/// Show the next scheduled instant without letting an older unconfirmed dose
/// hide the rest of today's schedule. Older doses remain in the dose list.
Map<String, dynamic>? nextCountdownDose(
  List<Map<String, dynamic>> doses,
  DateTime now,
) {
  if (doses.isEmpty) return null;
  for (final dose in doses) {
    if (doseScheduledTime(dose).isAfter(now)) return dose;
  }
  return doses.last;
}

/// A closed or snoozed reminder applies only to that persisted dose.
Map<String, dynamic>? nextReminderDose(
  List<Map<String, dynamic>> doses,
  DateTime now, {
  required Set<String> remindedDoseIds,
  required Map<String, DateTime> snoozedUntil,
}) {
  for (final dose in doses) {
    final id = dose['id'] as String;
    final scheduled = doseScheduledTime(dose);
    final snoozed = snoozedUntil[id];
    if (!scheduled.isAfter(now) &&
        !remindedDoseIds.contains(id) &&
        (snoozed == null || !now.isBefore(snoozed))) {
      return dose;
    }
  }
  return null;
}
