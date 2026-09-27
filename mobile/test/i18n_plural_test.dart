// 【FEAT-489 Phase 2G-b §2.2】ICU plural の `=1` / `other` 出し分け契約テスト。
//
// ## なぜ必要か
//
// Phase 2F-a で 26 key を ICU plural 化するまで、英語は "1 times" / "1 days" /
// "1 memos" と表示されていた。`app_en.arb` の plural 構文は手書きなので、
// **key を追加・編集する際に plain な `{count} times` に戻しやすい**。
// 戻っても ja では一切気付けない (日本語に複数形が無いため) ので CI で締める。
//
// ## 検査方針
//
// 全 26 key を列挙するのではなく、**パターンごとの代表**を固定する (§2.2)。
// 加えて「plural 化された key の総数」を固定し、**まとめて plain に戻される**
// 事故を検出する。
//
// 実行方法:
// ```powershell
// cd mobile
// flutter test test/i18n_plural_test.dart
// ```

import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sabiowl/l10n/app_localizations.dart';

/// Phase 2F-a で plural 化した key 数。**減ったら plain に戻された合図**。
///
/// 増やす分には問題ないので下限で assert する。
const int kMinPluralizedKeys = 26;

void main() {
  late AppLocalizations en;
  late AppLocalizations ja;

  setUpAll(() {
    en = lookupAppLocalizations(const Locale('en'));
    ja = lookupAppLocalizations(const Locale('ja'));
  });

  // ───────────────────────────────────────────────────────────────────────────
  // A: 代表パターンの =1 / other
  // ───────────────────────────────────────────────────────────────────────────
  // 【2026-08-06】完成文の assert を廃止し、**単複の切り替わり**だけを見る。
  //
  // 旧実装は 'Searching 1 visible memo' のように文全体を assert していたため、
  // FEAT-489 の英文レビューで語尾に句点が付いただけで落ちた (batch 08-14 の
  // 反映で 3 件)。本 group が守りたいのは ICU plural が正しく分岐すること
  // であって、文言そのものではない。文言は persona guide と native review の
  // 担当領域なので、ここで固定すると **レビューのたびに偽陽性が出る**。
  void expectPlural(String Function(int) f, String singular, String plural) {
    expect(f(1), contains('1 $singular'),
        reason: '=1 の分岐が単数形になっていない');
    expect(f(1), isNot(contains('1 $plural')),
        reason: '=1 なのに複数形が出ている');
    expect(f(3), contains('3 $plural'),
        reason: 'other の分岐が複数形になっていない');
  }

  group('A: en の =1 / other 出し分け', () {
    test('名詞が直後に来る単純形 (time / times)', () {
      expectPlural(en.challengeCardCountLabel, 'time', 'times');
      expectPlural(en.habitDetailPageTotalCountTimes, 'time', 'times');
    });

    test('文中に埋まる形 (memo / memos)', () {
      expectPlural(en.freeMemoPageSearchCount, 'visible memo', 'visible memos');
    });

    test('前置き付き (day / days)', () {
      expectPlural(en.gamifGachaPendingExpiryLabel, 'day', 'days');
    });

    test('絵文字を含む形 (coin / coins)', () {
      expectPlural(en.socialGiftRewardCoins, 'coin', 'coins');
      expect(en.socialGiftRewardCoins(1), contains('🪙'),
          reason: '絵文字が落ちている');
    });

    test('複数 placeholder を持つ形 (他の placeholder が壊れていない)', () {
      // plural 側だけでなく、**同居する 2 つ目の placeholder** が
      // 展開されているかを見る (ICU 分岐の中で消えることがある)。
      expect(en.gamifGachaDailyProgress(1, 20), contains('1 day'));
      expect(en.gamifGachaDailyProgress(1, 20), contains('20'));
      expect(en.gamifGachaDailyProgress(15, 50), contains('15 days'));
      expect(en.gamifGachaDailyProgress(15, 50), contains('50'));
    });

    test('0 は other 側に入る (=0 を勝手に作っていない)', () {
      // 「0 件」を専用文言にしたい箇所は空状態用の別 key が既にあるため、
      // plural 側に =0 を足すと二重管理になる (Phase 2F-a の判断)。
      expect(en.challengeCardCountLabel(0), contains('0 times'));
      expect(en.freeMemoPageSearchCount(0), contains('0 visible memos'));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // B: (s) 暫定表記が復活していない
  // ───────────────────────────────────────────────────────────────────────────
  group('B: "(s)" 暫定表記', () {
    // 【2026-08-06】完成文のハードコードを廃止。
    //
    // 旧実装は '1 event removed 🪶' のように **文全体**を assert していたため、
    // FEAT-489 の英文レビューで語彙が変わるたびに落ちた (実際に batch 03-06 の
    // 反映で落ちた)。本テストが守りたいのは「`event(s)` のような暫定表記に
    // 戻っていないこと」= **単複が正しく切り替わること**であって、文言そのもの
    // ではない。語彙は persona guide と native review の担当領域。
    test('plural 化した key が単複を正しく切り替える (event(s) 表記に戻っていない)', () {
      void expectSingularPlural(
        String Function(int) f,
        String singular,
        String plural,
      ) {
        expect(f(1), contains('1 $singular'));
        expect(f(1), isNot(contains(plural)));
        expect(f(3), contains('3 $plural'));
      }

      expectSingularPlural(
          en.calendarPageUnsyncSuccessSnackbarSabi_message, 'event', 'events');
      expectSingularPlural(
          en.socialContactPageConfirmDialogAttachmentCountValue, 'photo', 'photos');
    });

    test('app_en.arb 全体に "(s)" 表記が無い', () {
      final offenders = <String>[];
      _readArbMessages('lib/l10n/app_en.arb').forEach((k, v) {
        if (RegExp(r'\w\(s\)').hasMatch(v)) offenders.add('$k: $v');
      });
      expect(offenders, isEmpty,
          reason: '"event(s)" のような暫定表記は ICU plural に置き換えてください。\n'
              '${offenders.join('\n')}');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // C: ja は数によらず同一 (日本語に複数形は無い)
  // ───────────────────────────────────────────────────────────────────────────
  group('C: ja 側の不変性', () {
    test('ja は 1 でも 5 でも同じ語形', () {
      expect(ja.challengeCardCountLabel(1), '1 回');
      expect(ja.challengeCardCountLabel(5), '5 回');
      expect(ja.socialGiftRewardCoins(1), '🪙 1 コイン');
      expect(ja.socialGiftRewardCoins(3), '🪙 3 コイン');
    });

    // ── 【機能レビュー 20260822 followup §4】数値を印字しない plural ──────
    //
    // 🔴 **単複だけ選ばせて、数値そのものは印字しない** という形が 1 件だけある。
    // ホーム額縁のカウントダウンは 56pt の数字を**別の `Text`** が描いており、
    // 説明文はその下に置かれる。ここで数値を印字すると二重に出てしまう。
    //
    //   ja: 10 / 秒後に自動出陣しますよ 🪶
    //   en: 10 / seconds until Auto Battle begins 🪶
    //
    // カウントダウンは 1 まで下がる (`ambient_auto_battle_orchestrator` の
    // `for (int i = countdownSeconds; i > 0; i--)`) ので、plural を付けないと
    // **最後の 1 秒に "1 seconds" と出る** (機能レビュー followup §4 で指摘)。
    //
    // ja は本 group の契約どおり plain のまま。`seconds` は @-metadata で
    // 宣言だけして本文では使わない —— gen-l10n はこれを許し、ja の実装は
    // 引数を無視する形で生成される (実測で確認済み)。
    test('🔴 カウントダウンは数値を印字せず単複だけ切り替える', () {
      expect(en.habitWorldAmbientCountdownHintSabi_message(1),
          'second until Auto Battle begins \u{1FAB6}',
          reason: '🔴 1 のとき "1 seconds" に戻っていないか');
      expect(en.habitWorldAmbientCountdownHintSabi_message(10),
          'seconds until Auto Battle begins \u{1FAB6}');

      for (final n in [1, 2, 10]) {
        expect(en.habitWorldAmbientCountdownHintSabi_message(n).contains('$n'),
            isFalse,
            reason: '数値は 56pt の別 Text が描いている。ここに出すと二重になる');
        expect(ja.habitWorldAmbientCountdownHintSabi_message(n),
            '秒後に自動出陣しますよ \u{1FAB6}',
            reason: 'ja は数によらず同一 (日本語に複数形は無い)');
      }
    });

    test('ja 側に plural 構文を書いていない (template は plain のままが正)', () {
      final offenders = <String>[];
      _readArbMessages('lib/l10n/app_ja.arb').forEach((k, v) {
        if (v.contains(', plural,')) offenders.add(k);
      });
      expect(offenders, isEmpty,
          reason: 'template (app_ja.arb) は plain のままで、en 側だけ plural に'
              'するのが Phase 2F-a の設計です。\n'
              'ja に plural を書くと日本語で不要な分岐が生まれます。\n'
              '${offenders.join(', ')}');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // D: plural 化された key 数が減っていない
  // ───────────────────────────────────────────────────────────────────────────
  group('D: plural 化の網羅', () {
    test('en の plural key が $kMinPluralizedKeys 件以上ある', () {
      final n = _readArbMessages('lib/l10n/app_en.arb')
          .values
          .where((v) => v.contains(', plural,'))
          .length;

      expect(
        n,
        greaterThanOrEqualTo(kMinPluralizedKeys),
        reason: 'plural 化された key が減っています (実測 $n 件)。\n'
            '数え上げの直後に名詞が来る文言を plain に戻すと、英語で '
            '"1 times" のような表示になります。\n'
            'Phase 2F-a で 26 key を plural 化しました。',
      );
    });
  });
}

Map<String, String> _readArbMessages(String path) {
  final f = File(path);
  expect(f.existsSync(), isTrue,
      reason: '$path が見つかりません。プロジェクトルート (mobile/) から実行してください');
  final decoded = json.decode(f.readAsStringSync()) as Map<String, dynamic>;
  return {
    for (final e in decoded.entries)
      if (!e.key.startsWith('@') && e.value is String) e.key: e.value as String,
  };
}
