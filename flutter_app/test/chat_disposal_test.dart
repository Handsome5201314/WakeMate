import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wakemate/core/xiaozhi/xiaozhi_identity_store.dart';
import 'package:wakemate/core/xiaozhi/xiaozhi_session.dart';
import 'package:wakemate/features/chat/chat_page.dart';

class _ChatSession extends XiaozhiSession {
  int sentMessages = 0;

  _ChatSession()
    : super(identityStore: XiaozhiIdentityStore(userId: 'patient-a'));

  @override
  Future<void> connect() async {}

  @override
  Future<String> sendText(String text) async {
    sentMessages++;
    return '';
  }
}

void main() {
  for (final missed in [false, true]) {
    testWidgets(
      missed
          ? 'leaving after missed greeting cancels delayed chat command'
          : 'leaving before greeting does not update a disposed page',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final session = _ChatSession();
        addTearDown(session.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [xiaozhiSessionProvider.overrideWithValue(session)],
            child: MaterialApp(home: ChatPage(scene: missed ? 'missed' : null)),
          ),
        );
        if (missed) {
          await tester.pump(const Duration(milliseconds: 450));
        }
        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
        await tester.pump(const Duration(seconds: 2));

        expect(tester.takeException(), isNull);
        expect(session.sentMessages, 0);
      },
    );
  }
}
