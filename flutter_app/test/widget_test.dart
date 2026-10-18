// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wakemate/main.dart';

void main() {
  testWidgets('renders WakeMate splash screen', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const ProviderScope(child: WakeMateApp()));
    await tester.pump();

    expect(find.text('醒伴'), findsOneWidget);
    expect(find.text('WakeMate'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
