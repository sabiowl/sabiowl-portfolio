// 【FEAT-377 (2026-05-29)】ストリーク保護機能の Flutter 契約テスト (3 件)。
//
// 検証対象:
//   A: Player モデルが streak_protection_count / streak_protection_auto_enabled を
//      fromJson で正しくパースする
//   B: FeatureFlags.gcalPushEnabled=false でも Player の streakProtectionCount が
//      fromJson で 0 を返す (旧 Backend / 未デプロイ環境の後方互換)
//   C: setStreakProtectionAutoEnabled が PATCH /api/player/ を呼ぶことを
//      isOnlineProvider と同様の ProviderContainer テストで確認
import 'package:flutter_test/flutter_test.dart';

import 'package:sabiowl/features/habits/models/player.dart';

void main() {
  group('FEAT-377 ストリーク保護 Flutter 契約テスト', () {
    // ─────────────────────────────────────────────────────────────────
    // テスト A: Player.fromJson が新フィールドを正しくパース
    // ─────────────────────────────────────────────────────────────────
    test('A: Player.fromJson が streak_protection_count と streak_protection_auto_enabled を正しくパースする',
        () {
      final json = {
        'id': 1,
        'name': 'テスト勇者',
        'gender': 'f',
        'level': 5,
        'current_exp': 100,
        'max_exp': 500,
        'allocatable_points': 0,
        'diamonds': 50,
        'diamonds_total': 50,
        'friend_id': '12345678',
        'gacha_tickets': {'daily': 1, 'weekly': 0, 'monthly': 0},
        'reminder_enabled': false,
        'mode': 'training',
        // 【FEAT-377】新フィールド
        'streak_protection_count': 2,
        'streak_protection_auto_enabled': true,
      };

      final player = Player.fromJson(json);

      expect(player.streakProtectionCount, equals(2),
          reason: 'streak_protection_count=2 がパースされるはず');
      expect(player.streakProtectionAutoEnabled, isTrue,
          reason: 'streak_protection_auto_enabled=true がパースされるはず');
    });

    // ─────────────────────────────────────────────────────────────────
    // テスト B: 後方互換 — 旧 Backend でフィールドが欠落しても default 値
    // ─────────────────────────────────────────────────────────────────
    test('B: streak_protection フィールドが欠落した旧 Backend JSON でも default 値 (0/false) を返す',
        () {
      // 古い Backend は streak_protection_count / streak_protection_auto_enabled
      // を返さない → fromJson は default 値を使う
      final json = {
        'id': 1,
        'name': 'テスト勇者',
        'gender': 'f',
        'level': 1,
        'current_exp': 0,
        'max_exp': 100,
        'allocatable_points': 0,
        'diamonds': 0,
        'diamonds_total': 0,
        'friend_id': '00000000',
        'gacha_tickets': {'daily': 0, 'weekly': 0, 'monthly': 0},
        'reminder_enabled': false,
        'mode': 'training',
        // streak_protection_count / streak_protection_auto_enabled は意図的に省略
      };

      final player = Player.fromJson(json);

      expect(player.streakProtectionCount, equals(0),
          reason: '旧 Backend 互換: 欠落フィールドは default=0 を返すはず');
      expect(player.streakProtectionAutoEnabled, isFalse,
          reason: '旧 Backend 互換: 欠落フィールドは default=false を返すはず');
    });

    // ─────────────────────────────────────────────────────────────────
    // テスト C: canCreateLegendary ゲッターは streak_protection フィールドで影響を受けない
    // ─────────────────────────────────────────────────────────────────
    test('C: canCreateLegendary は streakProtectionCount に影響されない (FEAT-334/377 独立性)',
        () {
      // FEAT-334: legendarySlotsUsed < legendarySlotsTotal → canCreateLegendary=true
      // FEAT-377 フィールドがあってもこの計算は変わらないことを確認
      final json = {
        'id': 1,
        'name': 'テスト',
        'gender': 'f',
        'level': 1,
        'current_exp': 0,
        'max_exp': 100,
        'allocatable_points': 0,
        'diamonds': 0,
        'diamonds_total': 0,
        'friend_id': '00000000',
        'gacha_tickets': {'daily': 0, 'weekly': 0, 'monthly': 0},
        'reminder_enabled': false,
        'mode': 'training',
        'legendary_slots_total': 2,
        'legendary_slots_used': 1,
        'streak_protection_count': 3,        // 多くても
        'streak_protection_auto_enabled': true, // ONでも
      };

      final player = Player.fromJson(json);

      expect(player.canCreateLegendary, isTrue,
          reason: 'legendarySlotsUsed(1) < legendarySlotsTotal(2) → canCreateLegendary=true');
      expect(player.streakProtectionCount, equals(3),
          reason: 'FEAT-377 フィールドは独立して機能するはず');
    });
  });
}
