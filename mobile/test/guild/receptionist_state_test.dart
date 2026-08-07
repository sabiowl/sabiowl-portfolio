// 【FEAT-308 Phase 3】ReceptionistStateService の契約テスト 3 件 + 補助 1 件。
//
// 指示書 §2.5 シナリオ:
//   - A: Lv 14 → 15 で boss_unlocked 跨ぎ判定が成立する previousLevel を返す
//        (Lv.15 armored_knight 解禁直後の祝福経路)
//   - B: 同じ Lv で再度ギルド入場 → levelUp 再発火しない (二度祝福防止)
//   - C: Lv 10 → 11 (boss 閾値跨がず) で levelUp 発火 (lastLevelUpAt 非 null +
//        previousLevel 10)
//
// 補助: Pre-mortem #3 「端末リセット時 = SharedPreferences 空」→ null コンテキスト
//        (初回ギルド入場で誤発火しない)
//
// 注: 本テストは SharedPreferences の in-memory mock を使用、Backend 接続不要。

import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/features/guild/services/receptionist_state_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    // 各テスト前に SharedPreferences mock をクリーン状態にする。
    // Flutter test では `setMockInitialValues` で初期値を注入 (空 = 端末リセット相当)。
    SharedPreferences.setMockInitialValues({});
  });

  group('FEAT-308 ReceptionistStateService 契約', () {
    // ── シナリオ A ───────────────────────────────────────────────
    test('シナリオ A: Lv 14 → 15 で resolveLevelUpContext が previousLevel=14 を返す '
        '(boss_unlocked 跨ぎ判定の素材を提供)', () async {
      // 前回ギルド入場時 Lv.14 が保存されている状態を mock で再現
      SharedPreferences.setMockInitialValues({
        'lilia_last_seen_level': 14,
        'lilia_last_seen_level_at':
            DateTime(2026, 5, 25, 11, 55).toIso8601String(),
      });

      final service = ReceptionistStateService();
      final ctx = await service.resolveLevelUpContext(15);

      expect(ctx.previousLevel, 14,
          reason: '前回観測 Lv.14 を保持、ReceptionistService 側で 14<15<=15 跨ぎ判定');
      expect(ctx.lastLevelUpAt, isNotNull,
          reason: 'Lv UP 直後 (currentLevel > previousLevel) → 保存時刻が返る');
    });

    // ── シナリオ B ───────────────────────────────────────────────
    test('シナリオ B: 同じ Lv で再度入場 → lastLevelUpAt=null '
        '(同じ Lv の二度祝福防止)', () async {
      // 前回 Lv.15 で観測済 (markLevelSeen 後の状態)
      SharedPreferences.setMockInitialValues({
        'lilia_last_seen_level': 15,
        'lilia_last_seen_level_at': DateTime.now().toIso8601String(),
      });

      final service = ReceptionistStateService();
      final ctx = await service.resolveLevelUpContext(15); // 前回と同じ Lv

      expect(ctx.lastLevelUpAt, isNull,
          reason: '同 Lv (currentLevel <= previousLevel) → null '
              '(ReceptionistService 側で levelUp / bossUnlocked にマッチしない)');
      expect(ctx.previousLevel, 15,
          reason: 'previousLevel は値を返す (跨ぎ判定の素材として)');
    });

    // ── シナリオ C ───────────────────────────────────────────────
    test('シナリオ C: Lv 10 → 11 で levelUp 発火条件 '
        '(boss 閾値 15/25/35 を跨がず、純粋 levelUp)', () async {
      SharedPreferences.setMockInitialValues({
        'lilia_last_seen_level': 10,
        'lilia_last_seen_level_at':
            DateTime(2026, 5, 25, 11, 58).toIso8601String(),
      });

      final service = ReceptionistStateService();
      final ctx = await service.resolveLevelUpContext(11);

      expect(ctx.lastLevelUpAt, isNotNull);
      expect(ctx.previousLevel, 10,
          reason: 'ReceptionistService は previousLevel=10 → currentLevel=11 で '
              'threshold 15/25/35 を跨がないため levelUp 判定に落ちる');
    });

    // ── 補助 (Pre-mortem #3) ───────────────────────────────────────
    test('補助 Pre-mortem #3: SharedPreferences 空 (端末リセット直後) → '
        'null コンテキスト (初回ギルド入場で誤発火しない)', () async {
      // setUp で空にしているので追加 mock 不要
      final service = ReceptionistStateService();
      final ctx = await service.resolveLevelUpContext(5);

      expect(ctx.lastLevelUpAt, isNull,
          reason: '初回 = SharedPreferences 空 → null、levelUp 誤発火を防ぐ');
      expect(ctx.previousLevel, isNull,
          reason: 'previousLevel も null = bossUnlocked 跨ぎ判定も発火しない');
      // FEAT-305 既存の first_login 判定 (createdAt 24h 以内) が優先される設計。
    });

    // ── markLevelSeen の動作確認 ─────────────────────────────────
    test('markLevelSeen 後、resolveLevelUpContext が更新値を返す '
        '(セリフ表示 → 二度祝福防止の構造化)', () async {
      final service = ReceptionistStateService();

      // 1. Lv.20 で markLevelSeen
      await service.markLevelSeen(20);

      // 2. Lv.20 で resolve → 同 Lv = lastLevelUpAt null
      final ctx1 = await service.resolveLevelUpContext(20);
      expect(ctx1.lastLevelUpAt, isNull);
      expect(ctx1.previousLevel, 20);

      // 3. Lv.21 で resolve → Lv UP = lastLevelUpAt non-null
      final ctx2 = await service.resolveLevelUpContext(21);
      expect(ctx2.lastLevelUpAt, isNotNull);
      expect(ctx2.previousLevel, 20);
    });
  });
}
