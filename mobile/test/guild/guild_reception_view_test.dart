// 【FEAT-305 Phase 3】GuildReceptionView の widget test 2 シナリオ。
//
// 検証対象:
//   - A: SpeechBubble がメッセージを表示する (受付セリフ表示の最小契約)
//   - B: SpeechBubble が長文 (overflow 想定) を渡しても crash しない
//        (maxLines 4 + TextOverflow.ellipsis の防御)

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/features/guild/widgets/speech_bubble.dart';

void main() {
  group('FEAT-305 SpeechBubble 描画契約', () {
    testWidgets('A: SpeechBubble がメッセージを表示する', (tester) async {
      const message = 'ようこそギルドへ! 🗡️';
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: 80,
              child: SpeechBubble(message: message),
            ),
          ),
        ),
      );

      expect(find.text(message), findsOneWidget,
          reason: 'SpeechBubble は渡されたメッセージをそのまま表示するはず');
    });

    testWidgets('B: 長文を渡しても crash せず ellipsis で省略される', (tester) async {
      // 80px 高 × 普通の幅では 4 行を超える長文
      final longMessage = '長いセリフです。' * 30; // ~210 文字
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 200,
              height: 60,
              child: SpeechBubble(message: longMessage),
            ),
          ),
        ),
      );

      // overflow 発生でもクラッシュせず、Text widget が存在する
      expect(find.byType(Text), findsOneWidget,
          reason: '長文でも Text widget が render される');
      // tester に exception が発生していないこと
      expect(tester.takeException(), isNull,
          reason: 'maxLines + ellipsis で overflow を吸収、exception なし');
    });
  });
}
