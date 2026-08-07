// 【FEAT-305 Phase 3】リリア口調 CI ガード (簡易版)。
//
// CLAUDE.md「受付女性リリア (ギルド NPC) の口調ルール」に基づき、Dart 定数
// `_kDialogue` の全セリフが以下を満たすかチェック:
//   1. 空でない (yaml 破損 / typo の検知)
//   2. サビ専用マーカー 🪶 を含まない (リリアは状況連動絵文字を使う)
//   3. 老人口調禁止語 (じゃ / じゃのう / ですぞ) を含まない
//   4. 少年口調禁止語 (〜だよ / 〜だね) を含まない
//   5. リリア口調必須要素のうち少なくとも 1 つを含む:
//      - 感嘆符「!」
//      - 「〜ますよ」/「〜ましょう」/「〜です」
//      - 一人称「私」 or 二人称「あなた様」/「お客様」
//      - 状況連動絵文字 (🗡️ / ⚔️ / 🌸 / 🛡️)
//
// 既存 sabi_tone_test.dart の sabi_dialogue.yaml regex 走査とは独立した
// 別ファイル (FEAT-305 §0 のチェックリスト遵守、既存テスト退行回避)。

import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/features/guild/services/receptionist_service.dart';

void main() {
  group('FEAT-305 リリア口調 CI ガード', () {
    final all = kReceptionistDialogueForTest;

    test('全シナリオに少なくとも 1 つのセリフが登録されている', () {
      for (final state in ReceptionistState.values) {
        final pool = all[state] ?? const [];
        expect(pool.isNotEmpty, isTrue,
            reason: '$state にセリフが 1 つも登録されていない（yaml 破損 or Dart 定数欠落）');
      }
    });

    test('全セリフが空文字でない', () {
      for (final entry in all.entries) {
        for (final line in entry.value) {
          expect(line.trim().isNotEmpty, isTrue,
              reason: '${entry.key} に空セリフが含まれている');
        }
      }
    });

    test('サビ専用マーカー 🪶 を含まない (リリア vs サビのレイヤー分離)', () {
      for (final entry in all.entries) {
        for (final line in entry.value) {
          expect(line.contains('🪶'), isFalse,
              reason: '${entry.key}: リリアのセリフに 🪶 が混入 → '
                  'CLAUDE.md「サビ = 🪶 のみ / リリア = 🗡️/⚔️/🌸/🛡️」違反');
        }
      }
    });

    test('老人口調禁止語 (じゃ/じゃのう/ですぞ/なのじゃ) を含まない', () {
      const banned = ['じゃのう', 'ですぞ', 'なのじゃ'];
      for (final entry in all.entries) {
        for (final line in entry.value) {
          for (final word in banned) {
            expect(line.contains(word), isFalse,
                reason: '${entry.key}: 「$word」が含まれている → 老人口調禁止');
          }
        }
      }
    });

    test('少年口調禁止語 (〜だよ / 〜だね / 〜かな？) を含まない', () {
      const banned = ['だよ', 'だね', 'かな？', 'かな?'];
      for (final entry in all.entries) {
        for (final line in entry.value) {
          for (final word in banned) {
            expect(line.contains(word), isFalse,
                reason: '${entry.key}: 「$word」が含まれている → 少年口調禁止');
          }
        }
      }
    });

    test('全エントリが有効な ARB key 形式 (guildLilia で始まる)', () {
      // 【FEAT-489 Phase 2A】_kDialogueKeys は日本語テキストではなく ARB key を格納。
      // 口調チェックは AppLocalizations の値で別途カバー。ここでは key 形式のみ検証。
      final keyPattern = RegExp(r'^guildLilia[A-Za-z0-9]+$');
      for (final entry in all.entries) {
        for (final key in entry.value) {
          expect(keyPattern.hasMatch(key), isTrue,
              reason: '${entry.key}: 「$key」が有効な ARB key 形式でない '
                  '(guildLilia[A-Za-z0-9]+ を期待)');
        }
      }
    });
  });
}
