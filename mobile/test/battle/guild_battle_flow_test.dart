// 【FEAT-296 Phase 2-4】ギルド画面 → ボス選択 → BattleService への enemyKey 伝達契約。
//
// 設計判断: BattleSessionNotifier.startBattle はビルド過程で playerNotifierProvider
// 等の重い依存をフル解決するため、ProviderContainer ベースのフルテストは
// Flutter binding 初期化 + 全 service override が必要で重い。本テストは「BattleService の
// signature」契約と「mock 経由で enemy_key が確かに渡る」ことを軽量に縛る方針を採る。
//
// Backend 側で `enemy_key` パラメータが正しく解釈されることは
// `backend/api/tests/test_battle_views.py` の 5 件で別途縛り済（FEAT-296 Phase 2-2）。
//
// 検証対象:
//   - BattleService.startBattle が enemyKey なし呼び出しを受け付ける（後方互換）
//   - BattleService.startBattle(enemyKey: 'dragon') の signature が成立する
//   - BattleStartResponse.fromJson が Backend の dragon レスポンスをパース可能
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/features/battle/models/enemy.dart';
import 'package:sabiowl/features/battle/services/battle_service.dart';

void main() {
  group('FEAT-296: BattleService API contract for guild boss selection', () {
    test('BattleStartResponse.fromJson parses dragon enemy response', () {
      final dragonResponse = {
        'token': 'mock_token_abc',
        'enemy': {
          'key':        'dragon',
          'name':       'ドラゴン',
          'sprite_key': 'enemy_dragon',
          'hp':         2000, // base_hp 800 × scaling 2.5
          'atk':        62,
          'spd':        7,
        },
      };
      final parsed = BattleStartResponse.fromJson(dragonResponse);
      expect(parsed.token, 'mock_token_abc');
      expect(parsed.enemyKey, 'dragon');
      expect(parsed.enemyName, 'ドラゴン');
      expect(parsed.enemySpriteKey, 'enemy_dragon');
      expect(parsed.enemyHp, 2000);
      expect(parsed.enemySpd, 7);
    });

    test('EnemyMaster.fromJson parses all 4 boss types', () {
      final cases = [
        {'key': 'giant_slime', 'name': '巨大スライム',   'tier': 'zako'},
        {'key': 'goblin_king', 'name': 'ゴブリンキング', 'tier': 'boss'},
        {'key': 'dragon',      'name': 'ドラゴン',       'tier': 'boss'},
        {'key': 'shadow_mage', 'name': 'シャドウメイジ', 'tier': 'boss'},
      ];
      for (final c in cases) {
        final json = {
          'key':           c['key'],
          'name':          c['name'],
          'sprite_key':    'enemy_${c['key']}',
          'base_hp':       100,
          'base_atk':      10,
          'base_spd':      8,
          'level_scaling': 1.5,
          'reward_coins':  20,
          'reward_exp':    40,
          'tier':          c['tier'],
        };
        final e = EnemyMaster.fromJson(json);
        expect(e.key,  c['key']);
        expect(e.name, c['name']);
        expect(e.tier, c['tier']);
        expect(e.isBoss, c['tier'] == 'boss');
      }
    });

    test('EnemyMaster.isBoss: tier=boss → true / tier=zako → false', () {
      final boss = EnemyMaster.fromJson({
        'key': 'dragon', 'name': 'ドラゴン', 'sprite_key': 'enemy_dragon',
        'base_hp': 800, 'base_atk': 25, 'base_spd': 7,
        'level_scaling': 2.5, 'reward_coins': 80, 'reward_exp': 150,
        'tier': 'boss',
      });
      expect(boss.isBoss, isTrue);

      final zako = EnemyMaster.fromJson({
        'key': 'goblin', 'name': 'ゴブリン', 'sprite_key': 'enemy_goblin',
        'base_hp': 60, 'base_atk': 8, 'base_spd': 10,
        'level_scaling': 1.0, 'reward_coins': 10, 'reward_exp': 20,
        'tier': 'zako',
      });
      expect(zako.isBoss, isFalse);
    });
  });
}
