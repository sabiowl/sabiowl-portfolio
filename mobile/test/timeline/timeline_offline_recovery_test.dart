// 【FEAT-370 (2026-05-28)】BUG-70 構造解消: offline → online 復帰時の重複防止テスト。
//
// 検証対象:
//   A. offline 時は timelineAutoCreateProvider が SharedPreferences へのキー書き込みを
//      スキップ (= POST は送られない = 重複の種が作られない)。
//   B. 全テンプレート作成済み (SharedPreferences に全 id 記録済み) なら
//      timelineAutoCreateProvider はサービス呼び出しなしで即座に完了する。
//   C. isOnlineProvider が ConnectivityResult.none ストリームを受け取ったとき
//      false を返す (connectivity_service.dart の論理テスト)。
//
// テスト方針:
//   - isOnlineProvider を直接 overrideWithValue で制御 (native plugin 不要)
//   - SharedPreferences.setMockInitialValues を使い test isolation 保証
//   - timelineServiceProvider は全テンプレート作成済みテストでは呼ばれないため
//     mock 不要 (toCreate が空のとき service は ref.read されない)
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sabiowl/core/services/connectivity_service.dart';
// timeline_models.dart は timeline_provider.dart から re-export されるため直接 import 不要
import 'package:sabiowl/features/timeline/providers/timeline_provider.dart';

void main() {
  group('FEAT-370 BUG-70 構造解消: offline → online 復帰時の重複防止', () {
    // ──────────────────────────────────────────────────────────────────
    // テスト A: offline 時は SharedPreferences キーを書かない
    // ──────────────────────────────────────────────────────────────────
    test('A: isOnline=false → timelineAutoCreateProvider は SharedPreferences に auto_created キーを書かない',
        () async {
      SharedPreferences.setMockInitialValues({});

      final container = ProviderContainer(
        overrides: [
          // isOnlineProvider を直接 false に override (connectivity_plus native 不要)
          isOnlineProvider.overrideWithValue(false),
        ],
      );
      addTearDown(container.dispose);

      final date = DateTime(2026, 6, 15);

      // Provider を実行して完了まで待つ
      await container.read(timelineAutoCreateProvider(date).future);

      // offline 時は SharedPreferences.getInstance() 自体を呼ばず early return するため
      // auto_created キーが書き込まれていないことを確認
      final prefs = await SharedPreferences.getInstance();
      final autoCreatedKey = 'timeline_auto_created_'
          '${date.year}'
          '${date.month.toString().padLeft(2, '0')}'
          '${date.day.toString().padLeft(2, '0')}'; // timeline_auto_created_20260615
      expect(
        prefs.getString(autoCreatedKey),
        isNull,
        reason: 'offline 時は POST を試みないため auto_created キーが書かれないはず',
      );
    });

    // ──────────────────────────────────────────────────────────────────
    // テスト B: 全テンプレート作成済みなら service を呼ばずに即座に return
    // ──────────────────────────────────────────────────────────────────
    test('B: 全テンプレート作成済み → timelineAutoCreateProvider は toCreate=空で service を呼ばない',
        () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      final date = DateTime(2026, 6, 15);
      final autoCreatedKey = 'timeline_auto_created_'
          '${date.year}'
          '${date.month.toString().padLeft(2, '0')}'
          '${date.day.toString().padLeft(2, '0')}';

      // 全 kDefaultTemplates の id を「作成済み」として事前記録
      final allIds = kDefaultTemplates.map((t) => t.id).toList();
      await prefs.setString(autoCreatedKey, jsonEncode(allIds));

      final container = ProviderContainer(
        overrides: [
          isOnlineProvider.overrideWithValue(true),
          // timelineServiceProvider は toCreate が空のため呼ばれない。
          // override しないことで「呼ばれたら未設定 native 依存でクラッシュ」が
          // 意図しない service 呼び出しを検出するフェイルセーフになる。
        ],
      );
      addTearDown(container.dispose);

      // 全テンプレート作成済み → service.createEvent は呼ばれない → 正常完了するはず
      await expectLater(
        container.read(timelineAutoCreateProvider(date).future),
        completes,
        reason: '全テンプレート作成済みなら service を呼ばず正常完了するはず',
      );

      // SharedPreferences のキーは「全 id」のまま変わらない
      final stored = prefs.getString(autoCreatedKey);
      expect(stored, isNotNull);
      final storedList = jsonDecode(stored!) as List<dynamic>;
      expect(
        storedList.length,
        kDefaultTemplates.length,
        reason: '作成済み id の数は変わらないはず',
      );
    });

    // ──────────────────────────────────────────────────────────────────
    // テスト C: isOnlineProvider の connectivity_plus ロジックテスト
    //           ConnectivityResult.none ストリーム → false を返す
    // ──────────────────────────────────────────────────────────────────
    test('C: ConnectivityResult.none ストリーム → isOnlineProvider は false', () async {
      final container = ProviderContainer(
        overrides: [
          // connectivityStatusProvider を none 固定の同期ストリームで override
          connectivityStatusProvider.overrideWith(
            (ref) => Stream.fromFuture(
              Future.value([ConnectivityResult.none]),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      // 初期状態: ストリームが emit する前は loading (orElse = true)
      expect(
        container.read(isOnlineProvider),
        isTrue,
        reason: '初期 loading 状態では orElse により true を返すはず',
      );

      // ストリームが emit するまで待つ (pumpEventQueue で Dart イベントループを消化)
      await pumpEventQueue();

      // ストリーム emit 後: [ConnectivityResult.none] → false
      expect(
        container.read(isOnlineProvider),
        isFalse,
        reason: 'ConnectivityResult.none のみのリスト → isOnline=false のはず',
      );
    });
  });
}
