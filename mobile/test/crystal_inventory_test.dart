// 【FEAT-379 (2026-05-29)】ステータス結晶インベントリの Flutter 契約テスト (2 件)。
//
// 検証対象:
//   A: Player.fromJson が crystals ネスト 6 キーを正しく CrystalInventory にパース
//   B: CrystalInventory の [] operator が正しく各結晶値を返す

import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/features/habits/models/player.dart';

void main() {
  group('FEAT-379 ステータス結晶 Flutter 契約テスト', () {
    // ─────────────────────────────────────────────────────────────────
    // テスト A: Player.fromJson が crystals ネスト 6 キーを正しくパース
    // ─────────────────────────────────────────────────────────────────
    test('A: Player.fromJson が crystals ネスト 6 キーを CrystalInventory にパースする', () {
      final json = {
        'id': 1,
        'name': 'テスト',
        'gender': 'f',
        'level': 3,
        'current_exp': 0,
        'max_exp': 100,
        'allocatable_points': 0,
        'diamonds': 0,
        'diamonds_total': 0,
        'friend_id': '12345678',
        'gacha_tickets': {'daily': 0, 'weekly': 0, 'monthly': 0},
        'reminder_enabled': false,
        'mode': 'training',
        // 【FEAT-379】crystals ネスト
        'crystals': {
          'exercise':     5,
          'learning':     3,
          'health':       2,
          'mental':       1,
          'creation':     4,
          'contribution': 0,
        },
      };

      final player = Player.fromJson(json);

      expect(player.crystals.exercise,     5);
      expect(player.crystals.learning,     3);
      expect(player.crystals.health,       2);
      expect(player.crystals.mental,       1);
      expect(player.crystals.creation,     4);
      expect(player.crystals.contribution, 0);
    });

    // ─────────────────────────────────────────────────────────────────
    // テスト B: CrystalInventory の [] operator + 後方互換
    // ─────────────────────────────────────────────────────────────────
    test('B: CrystalInventory [] operator が正しく各結晶値を返す', () {
      const inv = CrystalInventory(
        exercise: 10,
        learning: 5,
        health:   3,
        mental:   1,
        creation: 7,
        contribution: 2,
      );

      expect(inv['exercise'],     10);
      expect(inv['learning'],     5);
      expect(inv['health'],       3);
      expect(inv['mental'],       1);
      expect(inv['creation'],     7);
      expect(inv['contribution'], 2);
      expect(inv['unknown_key'],  0, reason: '不明なキーは 0 を返すはず');

      // 後方互換: crystals フィールドなし (旧 Backend) → 全 0
      final jsonNocrystals = {
        'id': 1,
        'name': 'Old',
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
        // crystals キーなし
      };
      final playerOld = Player.fromJson(jsonNocrystals);
      expect(playerOld.crystals.exercise, 0, reason: '旧 Backend 互換: 全 0');
      expect(playerOld.crystals.contribution, 0);
    });
  });
}
