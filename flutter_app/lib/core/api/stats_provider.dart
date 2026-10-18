import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'rest_client.dart';

/// Shared statistics cache for the home summary and the full statistics page.
/// Invalidating it after a dose confirmation keeps both views on the same data.
final statsProvider = FutureProvider<List<dynamic>>((ref) async {
  return ref.watch(apiProvider).getStats(days: 30);
});
