// 【2026-07-25 codebase-functional-review 20260725 再評価 §8-2】
// ホーム件数表示が「全メモ本文の GET」を発火させないことの契約テスト。
//
// 【背景 (P1 #2 の未達)】
//   FEAT-493 の _FreeMemoSection は当初 freeMemoNotifierProvider を直接 watch し、
//   「未整理のメモ (N)」という整数 1 個のために全メモ本文 (最大 500 字 × 件数) を
//   above-the-fold で取得していた。bootstrap に free_memo_count を統合して修正した
//   つもりだったが、中継役の freeMemoCountProvider が内部で
//   `ref.watch(freeMemoNotifierProvider)` を残していたため fetch は消えていなかった。
//
// 【原因】
//   Riverpod の `ref.watch` は未初期化 provider を「生成」する。watch した時点で
//   FreeMemoNotifier.build() が走り GET /free-memos/ が発火する。
//   「表示される値」は bootstrap 由来で正しかったため、目視では気づけなかった。
//
// 【本テスト】
//   ① ホーム経路 (freeMemoCountProvider の読み取り) が fetch を発火させないこと
//   ② メモ画面到達時は正しく fetch し、件数をホーム表示用の値へ push すること
//   ③ 作成 / 削除 / 失敗ロールバックで件数が一覧と乖離しないこと
//   将来 freeMemoCountProvider に notifier の watch を戻すリファクタが入ったら
//   ① が落ちて気づける。
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sabiowl/features/free_memo/models/free_memo.dart';
import 'package:sabiowl/features/free_memo/providers/free_memo_provider.dart';
import 'package:sabiowl/features/free_memo/services/free_memo_service.dart';

/// 呼び出し回数を数える fake service。
///
/// 非対象メソッド (updateMemo / deleteMemo / convertMemo) は本テストで呼ばれない
/// 前提で UnimplementedError を投げる (= 誤って触ったら test 失敗で気づく)。
class _CountingFreeMemoService implements FreeMemoService {
  _CountingFreeMemoService({List<FreeMemo>? memos}) : memos = memos ?? [];

  List<FreeMemo> memos;
  int fetchCalls = 0;
  int createCalls = 0;

  /// true にすると createMemo が失敗する (ロールバック検証用)。
  bool failCreate = false;

  /// 【FEAT-503 アクション8 (2026-07-26)】fetchMemos は record を返す。
  /// count provider テストでは has_more は false 固定で十分。
  @override
  Future<MemoListResult> fetchMemos() async {
    fetchCalls++;
    return (memos: List<FreeMemo>.from(memos), hasMore: false);
  }

  @override
  Future<FreeMemo> createMemo(String text) async {
    createCalls++;
    if (failCreate) throw Exception('network down');
    return _memo(9000 + createCalls, text);
  }

  @override
  Future<FreeMemo> updateMemo(int id, String text) => throw UnimplementedError();
  @override
  Future<void> deleteMemo(int id) => throw UnimplementedError();
  @override
  Future<int> convertMemo(int id, String type) => throw UnimplementedError();
  // 【FEAT-500 (2026-07-26)】trash 系メソッドは本 count provider テストで
  // 呼ばれないため throw で fail-fast (呼ばれたら test 意図と齟齬あり)。
  @override
  Future<FreeMemo> restoreMemo(int id) => throw UnimplementedError();
  @override
  Future<void> purgeMemo(int id) => throw UnimplementedError();
  // 【FEAT-498 §2.5 (2026-07-26) / FEAT-502 (2026-07-26)】pagination 版
  // fetchDeletedPage (旧 fetchArchivedPage) は trash 画面専用、本 count provider
  // テストでは呼ばれない。
  @override
  Future<MemoPage> fetchDeletedPage({int offset = 0}) =>
      throw UnimplementedError();
  // 【FEAT-498 §2.6 (2026-07-31)】trash 一括完全削除も trash 画面専用、本 count
  // provider テストでは呼ばれないため fail-fast 実装。
  @override
  Future<int> purgeAllArchivedMemos() => throw UnimplementedError();
}

FreeMemo _memo(int id, String text) {
  final now = DateTime(2026, 7, 25);
  return FreeMemo(id: id, text: text, createdAt: now, updatedAt: now);
}

ProviderContainer _containerWith(_CountingFreeMemoService svc) {
  final container = ProviderContainer(
    overrides: [freeMemoServiceProvider.overrideWithValue(svc)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('freeMemoCountProvider — ホーム件数表示の契約', () {
    test('① ホームで件数を読んでも全件 fetch を発火させない', () async {
      final svc = _CountingFreeMemoService(
        memos: [_memo(1, 'a'), _memo(2, 'b')],
      );
      final container = _containerWith(svc);

      // ホーム bootstrap が /api/home/ の free_memo_count を注入した状態を再現。
      container.read(bootstrapFreeMemoCountProvider.notifier).state = 7;

      // _FreeMemoSection が件数を読む。
      expect(container.read(freeMemoCountProvider), 7);

      // 非同期 build が走る余地を与えてから確認する。
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        svc.fetchCalls,
        0,
        reason: 'ホーム表示は bootstrap の整数 1 個だけで完結すべき。'
            'freeMemoCountProvider が freeMemoNotifierProvider を watch すると '
            '(= 未初期化 provider の生成) GET /free-memos/ が above-the-fold で発火する。',
      );
    });

    test('② メモ画面到達時のみ fetch し、件数をホーム表示用の値へ push する', () async {
      final svc = _CountingFreeMemoService(
        memos: [_memo(1, 'a'), _memo(2, 'b'), _memo(3, 'c')],
      );
      final container = _containerWith(svc);

      // メモ画面が一覧を watch した状態を再現。
      await container.read(freeMemoNotifierProvider.future);

      expect(svc.fetchCalls, 1, reason: 'メモ画面では実際に一覧を取得する');
      expect(
        container.read(freeMemoCountProvider),
        3,
        reason: '一覧 load 後はホーム表示用の件数も最新化されるべき',
      );
    });

    test('③ 作成 / 削除で件数が一覧と乖離しない', () async {
      final svc = _CountingFreeMemoService(
        memos: [_memo(1, 'a'), _memo(2, 'b')],
      );
      final container = _containerWith(svc);

      await container.read(freeMemoNotifierProvider.future);
      expect(container.read(freeMemoCountProvider), 2);

      final notifier = container.read(freeMemoNotifierProvider.notifier);

      await notifier.createMemo('新しいメモ');
      expect(container.read(freeMemoCountProvider), 3, reason: '作成で +1');

      notifier.optimisticRemove(1);
      expect(container.read(freeMemoCountProvider), 2, reason: '楽観的削除で -1');
    });

    test('④ 作成失敗のロールバックで件数も元に戻る', () async {
      final svc = _CountingFreeMemoService(memos: [_memo(1, 'a')]);
      final container = _containerWith(svc);

      await container.read(freeMemoNotifierProvider.future);
      expect(container.read(freeMemoCountProvider), 1);

      svc.failCreate = true;
      final notifier = container.read(freeMemoNotifierProvider.notifier);

      await expectLater(notifier.createMemo('失敗する'), throwsA(isA<Exception>()));

      expect(
        container.read(freeMemoCountProvider),
        1,
        reason: '楽観的 +1 はロールバックされ、件数も元に戻るべき',
      );
      expect(container.read(freeMemoNotifierProvider).valueOrNull?.length, 1);
    });
  });
}
