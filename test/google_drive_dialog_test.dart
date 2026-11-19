import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unified_cloud_manager/ui/screens/add_account_dialog.dart';

void main() {
  testWidgets('AddAccountDialog exposes Google OAuth login UI', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AddAccountDialog(),
        ),
      ),
    );

    await tester.tap(find.text('Google Drive'));
    await tester.pumpAndSettle();

    expect(find.text('커스텀 OAuth API 키 설정 (선택 사항)'), findsOneWidget);
    expect(find.text('고급: Access Token 직접 입력 / 샘플 모드'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is Text &&
            (w.data == '브라우저 열어 로그인 및 연결' ||
                w.data == '브라우저로 OAuth 로그인 (커스텀 키 / 일반)' ||
                w.data == 'Google 계정으로 원터치 연결'),
      ),
      findsWidgets,
    );
  });
}
