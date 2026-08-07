// 【FEAT-399 (2026-05-31)】BackupPromptSheet マイルストーン抑制の契約テスト (4 シナリオ)。
//
// 検証対象: `lib/core/constants/preferences_keys.dart` の
//   - `kBackupSheetMilestoneLevels` セット
//   - `shouldShowBackupPromptSheet()` ヘルパー
//   - `markBackupPromptSheetShown()` ヘルパー
//
// 背景: 旧実装はゲストのレベルアップ毎に BackupPromptSheet が表示されていた (Lv 1→20 間で 20 回)。
//       FEAT-399 で Lv 5/10/20/30 の節目のみ (3 回) に抑制し、ダークパターン懸念を解消。
//
// テスト方針:
//   - Backend 接続不要 (SharedPreferences in-memory mock で完結)
//   - Widget rendering 不要 (pure unit test)
//   - `SharedPreferences.setMockInitialValues({})` で test isolation 保証
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sabiowl/core/constants/preferences_keys.dart';

void main() {
  group('FEAT-399 BackupPromptSheet マイルストーン抑制 契約テスト', () {
    setUp(() {
      // 各テストで SharedPreferences を空状態にリセット
      SharedPreferences.setMockInitialValues({});
    });

    // ─────────────────────────────────────────────────────────────────────
    // シナリオ A: マイルストーン Lv セットの値確認
    // ─────────────────────────────────────────────────────────────────────
    test('シナリオ A: kBackupSheetMilestoneLevels が {5, 10, 20, 30} である', () {
      // Lv 5/10/20/30 は節目 (BackupPromptSheet 発火)
      expect(kBackupSheetMilestoneLevels.contains(5),  isTrue);
      expect(kBackupSheetMilestoneLevels.contains(10), isTrue);
      expect(kBackupSheetMilestoneLevels.contains(20), isTrue);
      expect(kBackupSheetMilestoneLevels.contains(30), isTrue);

      // 節目以外は含まない (毎レベルアップ発火を防ぐ)
      for (final notMilestone in [1, 2, 3, 4, 6, 7, 8, 9, 11, 15, 19, 21, 25, 29, 31, 50]) {
        expect(
          kBackupSheetMilestoneLevels.contains(notMilestone), isFalse,
          reason: 'Lv $notMilestone はマイルストーンではない',
        );
      }

      // 4 要素のみ (増えたらテストで気づける)
      expect(kBackupSheetMilestoneLevels.length, 4);
    });

    // ─────────────────────────────────────────────────────────────────────
    // シナリオ B: SharedPreferences 空状態 (初回) → 表示する
    // ─────────────────────────────────────────────────────────────────────
    test('シナリオ B: SharedPreferences 未記録 (初回) → shouldShowBackupPromptSheet が true',
        () async {
      // Arrange: SharedPreferences 空 (setUp で setMockInitialValues({}) 済)
      final prefs = await SharedPreferences.getInstance();

      // Act & Assert: Lv 5 初回 → 表示すべき
      expect(await shouldShowBackupPromptSheet(5, prefs: prefs), isTrue);
      // Lv 10 初回 → 表示すべき (lastLevel=0 < 10)
      expect(await shouldShowBackupPromptSheet(10, prefs: prefs), isTrue);
    });

    // ─────────────────────────────────────────────────────────────────────
    // シナリオ C: Lv 5 で表示済み → Lv 5 再チェックで非表示 (1 Lv につき 1 回限定)
    // ─────────────────────────────────────────────────────────────────────
    test('シナリオ C: Lv 5 を markBackupPromptSheetShown 後 → shouldShow が false',
        () async {
      final prefs = await SharedPreferences.getInstance();

      // Act: Lv 5 で表示済みとしてマーク
      await markBackupPromptSheetShown(5, prefs: prefs);

      // Assert: 同 Lv での 2 回目以降は表示しない
      expect(await shouldShowBackupPromptSheet(5, prefs: prefs), isFalse,
          reason: 'Lv 5 は既に表示済み、同 Lv で再表示しない');
    });

    // ─────────────────────────────────────────────────────────────────────
    // シナリオ D: Lv 5 で表示済み → Lv 10 は表示する (上位 Lv は別節目)
    // ─────────────────────────────────────────────────────────────────────
    test('シナリオ D: Lv 5 を markShown 後 → Lv 10 は shouldShow が true',
        () async {
      final prefs = await SharedPreferences.getInstance();

      // Arrange: Lv 5 で表示済み
      await markBackupPromptSheetShown(5, prefs: prefs);

      // Act & Assert: Lv 10 → lastLevel=5 < 10 = 表示する
      expect(await shouldShowBackupPromptSheet(10, prefs: prefs), isTrue,
          reason: 'Lv 5 済み後も Lv 10 は別節目で表示すべき');

      // Lv 10 で表示したらマーク
      await markBackupPromptSheetShown(10, prefs: prefs);

      // Lv 10 再チェック → 非表示
      expect(await shouldShowBackupPromptSheet(10, prefs: prefs), isFalse);

      // Lv 20 は次の節目 → まだ表示すべき
      expect(await shouldShowBackupPromptSheet(20, prefs: prefs), isTrue);
    });
  });
}
