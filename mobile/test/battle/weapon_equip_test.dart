// 【FEAT-326 Phase 4】 武器装備の Flutter 側 unit / widget test 3 件。
//
// 検証対象:
//   A: WeaponInfo.fromJson が atk_bonus を正しく解釈する
//   B: Player.fromJson が equipped_weapon ネストオブジェクトを WeaponInfo に変換
//   C: Player.equippedWeapon=null 時のフォールバックパース (古い Backend 互換)
//
// 設計判断: WeaponSelectSheet / EquipWeaponView の Dio 通信を含む統合テストは
// httpClient mock + Riverpod overrides + go_router の組み合わせで複雑化するため、
// 本テストでは「データ層の契約 (fromJson / 装備武器の atkBonus 経路)」に絞る。
// UI 結合は TestFlight 実機検証で担保 (Done 基準 §4 検証項目)。

import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/features/battle/models/weapon_info.dart';
import 'package:sabiowl/features/habits/models/player.dart';

void main() {
  group('FEAT-326 WeaponInfo データ層契約', () {
    test('A: WeaponInfo.fromJson が atk_bonus を正しく解釈する', () {
      final json = {
        'id':        3,
        'key':       'mythril_sword',
        'name':      'ミスリルの剣',
        'atk_bonus': 35,
      };
      final w = WeaponInfo.fromJson(json);
      expect(w.id,       3);
      expect(w.key,      'mythril_sword');
      expect(w.name,     'ミスリルの剣');
      expect(w.atkBonus, 35);
    });

    test('B: Player.fromJson が equipped_weapon ネストを解釈する', () {
      final json = {
        'id':                1,
        'name':              'Tester',
        'gender':            'm',
        'level':             5,
        'current_exp':       0,
        'max_exp':           500,
        'allocatable_points':0,
        'diamonds':          10,
        'diamonds_total':    10,
        'friend_id':         'F123',
        'gacha_tickets':     {'daily': 0, 'weekly': 0, 'monthly': 0},
        'reminder_enabled':  false,
        'mode':              'training',
        'equipped_weapon': {
          'id':        2,
          'key':       'iron_sword',
          'name':      '鉄の剣',
          'atk_bonus': 10,
        },
      };
      final p = Player.fromJson(json);
      expect(p.equippedWeapon, isNotNull);
      expect(p.equippedWeapon!.key,      'iron_sword');
      expect(p.equippedWeapon!.atkBonus, 10);
    });

    test('C: equipped_weapon=null で Player.equippedWeapon=null (古い Backend 互換)', () {
      // 古い Backend (FEAT-326 未デプロイ環境) は equipped_weapon キー自体が欠落
      // または null。Flutter は null フォールバックで動作継続できる契約を縛る。
      final jsonWithoutKey = {
        'id':                1,
        'name':              'Tester',
        'gender':            'm',
        'level':             1,
        'current_exp':       0,
        'max_exp':           100,
        'allocatable_points':0,
        'diamonds':          0,
        'diamonds_total':    0,
        'friend_id':         'F1',
        'gacha_tickets':     {'daily': 0, 'weekly': 0, 'monthly': 0},
        'reminder_enabled':  false,
        'mode':              'training',
        // equipped_weapon キーなし
      };
      final p = Player.fromJson(jsonWithoutKey);
      expect(p.equippedWeapon, isNull,
          reason: '古い Backend (キー欠落) でも null フォールバックで動作継続');

      // 明示的に null が渡されるケースも同様
      final jsonWithNull = {...jsonWithoutKey, 'equipped_weapon': null};
      final p2 = Player.fromJson(jsonWithNull);
      expect(p2.equippedWeapon, isNull);
    });
  });
}
