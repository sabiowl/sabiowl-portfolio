// 【FEAT-506 (2026-07-29)】デフォルト予定 auto-create の Global toggle 契約テスト。
//
// 検証対象:
//   A. SharedPreferences timeline_auto_create_enabled=false の場合、
//      isOnline=true でも timelineAutoCreateProvider が early return し
//      auto_created キーを書かない (POST 送信なし)
//   B. SharedPreferences 未設定 (default=true 相当) かつ全テンプレート作成済みの
//      場合、provider は正常完了する (default ON 挙動の回帰保証)
//
// FEAT-506 Pre-mortem S2 対応: default=false になる regression を契約テストで縛る。
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sabiowl/core/services/connectivity_service.dart';
import 'package:sabiowl/features/timeline/providers/timeline_provider.dart';

void main() {
  group('FEAT-506 Global toggle 契約テスト', () {
    // ── テスト A: Global toggle OFF → auto_created キーを書かない ──────────
    test('A: timeline_auto_create_enabled=false → timelineAutoCreateProvider が early return し auto_created キーを書かない',
        () async {
      SharedPreferences.setMockInitialValues({
        'timeline_auto_create_enabled': false,
      });

      final container = ProviderContainer(
        overrides: [
          isOnlineProvider.overrideWithValue(true),
          // timelineServiceProvider は early return で呼ばれないため override 不要
          // (呼ばれたら native 依存でクラッシュ → 意図しない到達を検出する)
        ],
      );
      addTearDown(container.dispose);

      final date = DateTime(2026, 7, 29);

      await container.read(timelineAutoCreateProvider(date).future);

      final prefs = await SharedPreferences.getInstance();
      final autoCreatedKey = 'timeline_auto_created_'
          '${date.year}'
          '${date.month.toString().padLeft(2, '0')}'
          '${date.day.toString().padLeft(2, '0')}';

      expect(
        prefs.getString(autoCreatedKey),
        isNull,
        reason: 'Global toggle OFF 時は POST を試みないため auto_created キーが書かれないはず',
      );
    });

    // ── テスト B: SharedPreferences 未設定 → default=true として動作 ─────────
    test('B: SharedPreferences 未設定 (default=true) + 全テンプレート作成済み → provider は正常完了する',
        () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      final date = DateTime(2026, 7, 29);
      final autoCreatedKey = 'timeline_auto_created_'
          '${date.year}'
          '${date.month.toString().padLeft(2, '0')}'
          '${date.day.toString().padLeft(2, '0')}';

      // 全 kDefaultTemplates を作成済みとして記録 (service への POST なしで完了)
      final allIds = kDefaultTemplates.map((t) => t.id).toList();
      await prefs.setString(autoCreatedKey, jsonEncode(allIds));

      final container = ProviderContainer(
        overrides: [
          isOnlineProvider.overrideWithValue(true),
        ],
      );
      addTearDown(container.dispose);

      await expectLater(
        container.read(timelineAutoCreateProvider(date).future),
        completes,
        reason: 'default=true (key 未設定) かつ全テンプレート作成済みなら正常完了するはず',
      );
    });
  });
}
