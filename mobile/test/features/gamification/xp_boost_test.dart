// 【FEAT-318 (2026-06-13 再活性化)】XP ブースト (xp_boost_1.5x) Flutter 契約テスト。
//
// 検証対象:
//   A: Player.fromJson が xp_boost_active_until (UTC isoformat) を正しくパース
//   B: Player.fromJson が xp_boost_active_until 欠落時に null フォールバック
//   C: isXpBoostActive / xpBoostRemaining の有効・無効・期限切れ判定 (Pre-mortem #2)

import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/features/habits/models/player.dart';

void main() {
  group('FEAT-318 XP ブースト Flutter 契約テスト', () {
    // ─────────────────────────────────────────────────────────────────
    // テスト A: xp_boost_active_until (UTC isoformat) のパース + アクティブ判定
    // ─────────────────────────────────────────────────────────────────
    test('A: 未来の UTC isoformat → isXpBoostActive=true、xpBoostRemaining > 0', () {
      final future = DateTime.now().toUtc().add(const Duration(hours: 18));
      final player = Player.fromJson({
        'id': 1,
        'xp_boost_active_until': future.toIso8601String(),
      });

      expect(player.xpBoostActiveUntil, isNotNull);
      expect(player.isXpBoostActive, isTrue);
      expect(player.xpBoostRemaining.inMinutes, greaterThan(0));
      // 残り時間がおよそ 18 時間であること
      expect(player.xpBoostRemaining.inHours, inInclusiveRange(17, 18));
    });

    // ─────────────────────────────────────────────────────────────────
    // テスト B: xp_boost_active_until 欠落 → null フォールバック (旧 Backend 互換)
    // ─────────────────────────────────────────────────────────────────
    test('B: xp_boost_active_until 欠落 → null、isXpBoostActive=false', () {
      final player = Player.fromJson({'id': 1});

      expect(player.xpBoostActiveUntil, isNull);
      expect(player.isXpBoostActive, isFalse);
      expect(player.xpBoostRemaining, Duration.zero);
    });

    // ─────────────────────────────────────────────────────────────────
    // テスト C: 過去の UTC isoformat (期限切れ) → isXpBoostActive=false
    // ─────────────────────────────────────────────────────────────────
    test('C: 過去の UTC isoformat (期限切れ) → isXpBoostActive=false', () {
      final past = DateTime.now().toUtc().subtract(const Duration(hours: 1));
      final player = Player.fromJson({
        'id': 1,
        'xp_boost_active_until': past.toIso8601String(),
      });

      expect(player.xpBoostActiveUntil, isNotNull);
      expect(player.isXpBoostActive, isFalse);
      expect(player.xpBoostRemaining, Duration.zero);
    });
  });
}
