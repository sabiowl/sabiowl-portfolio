import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sabiowl/core/constants/preferences_keys.dart';

/// 【FEAT-462 (2026-06-22)】バトル戻るボタン初回ヒントの抑制契約テスト。
void main() {
  group('FEAT-462 battle back hint', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('初回バトル: hint should show, mark後 falseになる', () async {
      final prefs = await SharedPreferences.getInstance();
      expect(await shouldShowBattleBackHint(prefs: prefs), isTrue);

      await markBattleBackHintShown(prefs: prefs);
      expect(await shouldShowBattleBackHint(prefs: prefs), isFalse);
    });

    test('既に表示済: hint should NOT show', () async {
      SharedPreferences.setMockInitialValues({
        kPrefsBattleBackHintShown: true,
      });
      final prefs = await SharedPreferences.getInstance();
      expect(await shouldShowBattleBackHint(prefs: prefs), isFalse);
    });
  });
}
