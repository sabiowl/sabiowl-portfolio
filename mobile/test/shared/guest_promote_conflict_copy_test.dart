// 【FEAT-489 (2026-08-06)】ゲスト昇格の衝突ダイアログ文言の契約テスト。
//
// ## 何を守るか
//
// このダイアログは **既存アカウント名を文中に埋める** 数少ない画面で、
// 埋め方の不具合が 2 つ同時に見つかった:
//
// 1. **日本語の鉤括弧が英語 UI に漏れていた**
//    widget が `'「$existingUserName」'` と直書きしており、英語でも
//    `linked to 「suzuki-taro」.` と表示されていた。
//    囲み文字は locale ごとに違うので arb へ移した。
//
// 2. **英文が文法的に壊れていた**
//    `registered as {existing} existing account` = 「suzuki-taro 既存の
//    アカウントとして登録」という非文。英文レビューで指摘され、
//    `linked to {existing}.` に直した。
//
//    このとき reviewer は **{existing} を落とす**案を出してきた。
//    採用すると「どの既存アカウントと衝突したのか」が表示されなくなる。
//    placeholder を保ったまま文法を直し、fallback 側を
//    "your existing account" にすることで同じ英文を実現している。
//
// ユーザー名が入る経路と入らない経路で **文が両方とも成立すること**を縛る。

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/l10n/app_localizations.dart';

/// 日本語 (ひらがな / カタカナ / 漢字)。
final _kJapanese = RegExp(r'[぀-ヿ一-龯]');

/// widget と同じ組み立て (`guest_promote_conflict_dialog.dart` の `show`)。
String buildIntro(AppLocalizations l, String provider, String? userName) {
  final existing = (userName?.isNotEmpty ?? false)
      ? l.sharedGuestPromoteConflictDialogExistingName(userName!)
      : l.sharedGuestPromoteConflictDialogExistingFallback;
  return l.sharedGuestPromoteConflictDialogBodyIntro(provider, existing);
}

void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  final ja = lookupAppLocalizations(const Locale('ja'));

  group('A: ユーザー名がある経路', () {
    test('英語 UI に日本語の囲み文字が漏れない', () {
      final text = buildIntro(en, 'Google', 'suzuki-taro');
      expect(text, contains('suzuki-taro'), reason: 'ユーザー名が消えている');
      expect(text, isNot(contains('「')),
          reason: '🔴 日本語の鉤括弧が英語 UI に出ています');
      expect(text, isNot(contains('」')));
      expect(text, isNot(matches(_kJapanese)));
    });

    test('日本語 UI では鉤括弧のまま', () {
      final text = buildIntro(ja, 'Google', 'suzuki-taro');
      expect(text, contains('「suzuki-taro」'),
          reason: '日本語側の囲み文字まで変えてしまっている');
    });

    test('provider 名が両 locale で埋まる', () {
      expect(buildIntro(en, 'Apple', 'taro'), contains('Apple'));
      expect(buildIntro(ja, 'Apple', 'taro'), contains('Apple'));
    });
  });

  group('B: ユーザー名が無い経路 (fallback)', () {
    test('英語で文として成立する', () {
      final text = buildIntro(en, 'Google', null);
      // 旧実装は "registered as an existing account" で、fallback 側だけは
      // たまたま読めていた。文型を変えたので fallback も追随している。
      expect(text, contains('your existing account'));
      expect(text, isNot(matches(_kJapanese)));
    });

    test('空文字も fallback 扱い', () {
      expect(buildIntro(en, 'Google', ''), contains('your existing account'));
    });

    test('日本語でも文として成立する', () {
      expect(buildIntro(ja, 'Google', null), contains('その'));
    });
  });

  group('C: placeholder が落ちていない', () {
    test('未展開の {existing} / {providerLabel} が残らない', () {
      for (final l in [en, ja]) {
        for (final name in ['suzuki-taro', null]) {
          final text = buildIntro(l, 'Google', name);
          expect(text, isNot(contains('{')),
              reason: 'placeholder が未展開のまま出力されています: $text');
        }
      }
    });
  });
}
