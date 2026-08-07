// 【2026-08-02 hotfix】`Player.copyWith` のフィールド網羅ガード。
//
// ## なぜ必要か
//
// 楽観 UI 更新 (`setStreakProtectionAutoEnabled` / `setGcalPushEnabled` /
// `setTimelineUncompletedReminderEnabled` / `setFreeMemoEnabled`) は、以前は
// `Player(id: current.id, name: current.name, ...)` と全フィールドを手書きで
// 詰め替えていた。この方式は「新フィールドを追加したとき、既存のコピー箇所に
// 追記し忘れると、そのフィールドだけ既定値に戻る」silent degradation を招く。
//
// 実際に以下の実害が出ていた (2026-08-02 user 実機報告):
//   - setStreakProtectionAutoEnabled: 9 フィールド欠落
//     → 連続記録の保護をトグルすると仮メモ機能が一瞬 OFF に見える
//   - setGcalPushEnabled / setTimelineUncompletedReminderEnabled: 16 フィールド欠落
//
// `copyWith` に一本化して解消したが、**copyWith 自体が同じ腐り方をする**
// (Player に field を足して copyWith に足し忘れる) ため、それを CI で止める。
//
// ## 判定方法
//
// リフレクションは Flutter で使えないので、`player.dart` のソースを読んで
// `class Player` の `final` フィールド名と `copyWith` の引数名を突き合わせる。
// i18n_coverage_test.dart の check D と同じ source レベル検証。
//
// 実行方法:
// ```powershell
// cd mobile
// flutter test test/player_copy_with_test.dart
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Player の全フィールドが copyWith の引数に存在する', () {
    final file = File('lib/features/habits/models/player.dart');
    expect(
      file.existsSync(),
      isTrue,
      reason: 'player.dart が見つかりません。'
          'プロジェクトルート (mobile/) から実行してください。',
    );
    final src = file.readAsStringSync();

    // ── class Player { ... } の範囲を切り出す ──────────────────────────
    // player.dart には CharacterStat / ActiveCharacter 等も同居しているため、
    // Player 本体に限定しないと他クラスの field を誤検出する。
    final classStart = src.indexOf('class Player {');
    expect(classStart, greaterThanOrEqualTo(0),
        reason: 'class Player の定義が見つかりません');

    final copyWithStart = src.indexOf('Player copyWith({', classStart);
    expect(copyWithStart, greaterThanOrEqualTo(0),
        reason: 'Player.copyWith が見つかりません。'
            '楽観 UI 更新はすべて copyWith 経由にする方針です');

    // field 宣言は copyWith より前 (クラス冒頭) にまとまっている。
    final fieldSection = src.substring(classStart, copyWithStart);
    final copyWithEnd = src.indexOf('}) {', copyWithStart);
    expect(copyWithEnd, greaterThan(copyWithStart));
    final copyWithParams = src.substring(copyWithStart, copyWithEnd);

    // ── field 名を抽出 ────────────────────────────────────────────────
    // 例: `  final int dailyBattleCount;` / `  final ActiveCharacter? activeCharacter;`
    final fieldNames = RegExp(r'^\s*final\s+[\w<>?,\s]+?\s+(\w+);', multiLine: true)
        .allMatches(fieldSection)
        .map((m) => m.group(1)!)
        .toSet();

    expect(fieldNames, isNotEmpty, reason: 'field を 1 つも抽出できませんでした');

    // ── copyWith の引数名を抽出 ───────────────────────────────────────
    // 例: `    int? dailyBattleCount,`
    final paramNames = RegExp(r'^\s*[\w<>?,\s]+?\s+(\w+),', multiLine: true)
        .allMatches(copyWithParams)
        .map((m) => m.group(1)!)
        .toSet();

    final missing = fieldNames.difference(paramNames).toList()..sort();

    expect(
      missing,
      isEmpty,
      reason: 'Player に追加されたが copyWith の引数にないフィールドがあります。\n'
          'このまま放置すると、楽観 UI 更新 (設定トグル等) のたびに\n'
          '該当フィールドが既定値へ silent に戻ります\n'
          '(2026-08-02 に「連続記録の保護をトグルすると仮メモ機能が消える」\n'
          'として実機で顕在化した不具合と同じ構造)。\n'
          'copyWith に引数と `xxx ?? this.xxx` を追加してください:\n'
          '  ${missing.join(', ')}',
    );
  });

  test('楽観 UI 更新に Player の手書き詰め替えが残っていない', () {
    final src =
        File('lib/features/habits/providers/habits_provider.dart').readAsStringSync();

    // `state = AsyncData(Player(` = 全フィールド手書きコピーの signature。
    // copyWith を使っていれば `AsyncData(current.copyWith(` になる。
    expect(
      src.contains('AsyncData(Player('),
      isFalse,
      reason: '楽観 UI 更新で Player を手書きで詰め替えている箇所があります。\n'
          'フィールド追加時に落ちる構造なので、current.copyWith(...) を使ってください。',
    );
  });
}
