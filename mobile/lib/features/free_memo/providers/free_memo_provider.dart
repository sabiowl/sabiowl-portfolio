// 【FEAT-493 (2026-07-25)】フリーメモ Riverpod プロバイダー。
// 新規 feature のため @riverpod を採用 (CLAUDE.md 規則準拠)。
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/analytics/posthog_service.dart';
import '../../../core/api/api_client.dart';
import '../models/free_memo.dart';
import '../services/free_memo_service.dart';

part 'free_memo_provider.g.dart';

@riverpod
FreeMemoService freeMemoService(Ref ref) {
  return FreeMemoService(ref.watch(apiClientProvider));
}

// ── 未 archive メモ件数の単一保持先 ────────────────────────────────
// 【2026-07-25 codebase-functional-review 20260725 対応 (P1 #2)】
// 書き込み経路は 2 つだけ:
//   ① homeBootstrapControllerProvider が /api/home/ の free_memo_count を注入
//      (ホーム初回描画、above-the-fold)
//   ② FreeMemoNotifier._setMemos がメモ一覧の増減を push
//      (メモ画面での作成 / 削除 / 変換 / refresh)
final bootstrapFreeMemoCountProvider = StateProvider<int>((ref) => 0);

// ── 未 archive フリーメモ件数 (ホーム表示用) ──────────────────────
// 【2026-07-25 再評価 §8-2 対応】
// ⚠️ **freeMemoNotifierProvider を watch してはならない**。
// Riverpod の `ref.watch` は未初期化 provider を「生成」するため、watch した
// 時点で FreeMemoNotifier.build() が走り GET /free-memos/ (全メモ本文、最大
// 500 字 × 件数) が above-the-fold で発火してしまう。
// 旧実装はまさにこれで、「表示は整数 1 個」になっていたが fetch は消えて
// おらず、bootstrap 統合の目的 (ホームの fetch 本数削減) が未達だった。
//
// 正しい設計: 本 provider は bootstrap 値を読むだけの受動的な参照点とし、
// メモ画面での増減は FreeMemoNotifier 側から push してもらう (上記 ②)。
//
// この契約は目視で壊れていないことを確認できないため、
// test/features/free_memo/free_memo_count_provider_test.dart で恒久的に縛る。
final freeMemoCountProvider = Provider<int>((ref) {
  return ref.watch(bootstrapFreeMemoCountProvider);
});

// ── 通常一覧の has_more (200 件上限で打切りあり) ──────────────────────
// 【FEAT-503 アクション8 (2026-07-26)】backend FreeMemoListCreateView は 200 件
// 上限 + has_more を返すが、従来クライアントは has_more を捨てていた。
// FreeMemoNotifier が fetch/refresh 時に本 provider へ push、memo_page が
// 一覧末尾の「古いメモは表示していません 🪶」1 行表示の判定に使う
// (freeMemoCountProvider と同じ「notifier → StateProvider push」設計)。
final freeMemoHasMoreProvider = StateProvider<bool>((ref) => false);

// 【FEAT-500 (2026-07-26) / FEAT-498 §2.5 (2026-07-26)】trash (削除メモ) 一覧
// controller。
//
// Pagination 対応 (§2.5): 200 件超えの trash で「もっと読み込む」button 経由
// で offset を累積して追加取得、内部 state に append する pattern。
//
// State: (memos: 累積 memos リスト, hasMore: 次 page 存在, isLoadingMore: fetch 中)
// Methods:
//   - refresh(): offset=0 から再取得 (invalidate 相当、restore/purge 後に呼ぶ)
//   - loadMore(): 次 page を追加取得 (hasMore が true の時のみ意味あり)
//
// autoDispose で trash 画面を閉じるとキャッシュ破棄 (メモリ効率、fresh 保証)。

class TrashState {
  final List<FreeMemo> memos;
  final bool hasMore;
  final bool isLoadingMore;
  const TrashState({
    required this.memos,
    required this.hasMore,
    required this.isLoadingMore,
  });
  TrashState copyWith({List<FreeMemo>? memos, bool? hasMore, bool? isLoadingMore}) =>
      TrashState(
        memos: memos ?? this.memos,
        hasMore: hasMore ?? this.hasMore,
        isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      );
}

class DeletedMemosController extends StateNotifier<AsyncValue<TrashState>> {
  DeletedMemosController(this._ref) : super(const AsyncValue.loading()) {
    refresh();
  }
  final Ref _ref;
  int _nextOffset = 0;

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    _nextOffset = 0;
    try {
      final page = await _ref.read(freeMemoServiceProvider).fetchDeletedPage();
      _nextOffset = page.nextOffset;
      state = AsyncValue.data(TrashState(
        memos: page.memos,
        hasMore: page.hasMore,
        isLoadingMore: false,
      ));
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  /// 【FEAT-503 アクション6 (2026-07-26)】trash からの楽観的除去。
  /// 復元 / 完全削除の直後に該当 id を state.memos から即座に外し、シート全体の
  /// spinner (refresh() → AsyncValue.loading()) を出さずにその item だけ消す。
  /// hasMore / isLoadingMore / スクロール位置 / load-more 済ページは維持する。
  /// active 側 (FreeMemoNotifier.optimisticRemove) と同型 = 機能内の非対称を解消。
  void optimisticRemove(int id) {
    final cur = state.valueOrNull;
    if (cur == null) return;
    state = AsyncValue.data(
      cur.copyWith(memos: cur.memos.where((m) => m.id != id).toList()),
    );
  }

  /// 【FEAT-498 §2.6 (2026-07-31)】trash 一括完全削除 (すべて完全削除)。
  ///
  /// Backend の DELETE /api/free-memos/trash/purge-all/ を叩いて deleted_at IS NOT
  /// NULL の全 memo を hard delete。state は全消去 (memos=[], hasMore=false)。
  /// UI 側で BUG-138 準拠 confirm dialog を経てから呼ぶ前提 (Pre-mortem S4)。
  ///
  /// Returns: 削除件数 (Backend response header X-Purged-Count)。
  /// 失敗時は例外 rethrow (呼び出し側で SnackBar 表示)。
  Future<int> purgeAllArchived() async {
    final count =
        await _ref.read(freeMemoServiceProvider).purgeAllArchivedMemos();
    // 楽観的更新: state を空 trash に置換 (Backend で全 hard delete 済のため
    // refresh() で再 fetch すると 0 件 = 同じ結果、round-trip 節約)。
    state = const AsyncValue.data(TrashState(
      memos: [],
      hasMore: false,
      isLoadingMore: false,
    ));
    _nextOffset = 0;
    return count;
  }

  /// hasMore が true の時のみ意味がある。button 側で hasMore check してから呼ぶ。
  Future<void> loadMore() async {
    final cur = state.valueOrNull;
    if (cur == null || !cur.hasMore || cur.isLoadingMore) return;
    state = AsyncValue.data(cur.copyWith(isLoadingMore: true));
    try {
      final page =
          await _ref.read(freeMemoServiceProvider).fetchDeletedPage(offset: _nextOffset);
      _nextOffset = page.nextOffset;
      state = AsyncValue.data(TrashState(
        memos: [...cur.memos, ...page.memos],
        hasMore: page.hasMore,
        isLoadingMore: false,
      ));
    } catch (_) {
      // 失敗時は isLoadingMore=false に戻す (button 再表示、user が再試行可)
      state = AsyncValue.data(cur.copyWith(isLoadingMore: false));
      rethrow;
    }
  }
}

final deletedMemosProvider = StateNotifierProvider.autoDispose<
    DeletedMemosController, AsyncValue<TrashState>>(
  (ref) => DeletedMemosController(ref),
);

@riverpod
class FreeMemoNotifier extends _$FreeMemoNotifier {
  @override
  Future<List<FreeMemo>> build() async {
    final result = await ref.read(freeMemoServiceProvider).fetchMemos();
    // await 後 = build の同期フェーズ外なので、他 provider への書き込みは安全。
    _syncCount(result.memos.length);
    _syncHasMore(result.hasMore);
    return result.memos;
  }

  /// 【2026-07-25 再評価 §8-2 対応】メモ一覧の唯一の書き込み経路。
  ///
  /// `state = AsyncValue.data(...)` を直接書かず必ず本メソッドを通すことで、
  /// ホーム表示用の件数 (bootstrapFreeMemoCountProvider) が一覧と乖離しない
  /// ことを構造的に保証する。件数更新を各 mutation に散らすと、1 箇所の
  /// 書き漏れがサイレントな件数ズレになるため。
  void _setMemos(List<FreeMemo> memos) {
    state = AsyncValue.data(memos);
    _syncCount(memos.length);
  }

  void _syncCount(int count) {
    ref.read(bootstrapFreeMemoCountProvider.notifier).state = count;
  }

  /// 【FEAT-503 アクション8】通常一覧の has_more を StateProvider へ push。
  /// fetch / refresh / restore (= backend から一覧を取り直す経路) で更新。
  /// 楽観的な作成 / 削除は has_more を変えない (200 件窓の外の存在有無は不変)。
  void _syncHasMore(bool hasMore) {
    ref.read(freeMemoHasMoreProvider.notifier).state = hasMore;
  }

  /// 【2026-07-25 codebase-functional-review 20260725 対応 (要素 A)】
  /// 楽観的作成: 一時 id (負値マーカー) で即 state 更新 → API 確定後に実 id で
  /// 差し替え → 失敗時は前 state にロールバック + rethrow (呼出元 SnackBar 表示)。
  /// 「思いついた瞬間の低摩擦キャプチャ」機能中核価値のため、API 往復を待たせない。
  Future<void> createMemo(String text, {String entryPoint = 'home_fab'}) async {
    final prev = state.valueOrNull ?? [];
    final tempId = -DateTime.now().microsecondsSinceEpoch; // 負値 = 未確定マーカー
    final now = DateTime.now();
    final optimistic = FreeMemo(
      id: tempId,
      text: text,
      createdAt: now,
      updatedAt: now,
    );
    _setMemos([optimistic, ...prev]);
    try {
      final saved = await ref.read(freeMemoServiceProvider).createMemo(text);
      final cur = state.valueOrNull ?? [];
      _setMemos(cur.map((m) => m.id == tempId ? saved : m).toList());
    } catch (e) {
      _setMemos(prev);
      rethrow;
    }
    // 【FEAT-493】メモ作成イベント (best-effort、user 体感パスから外す)
    unawaited(PosthogService.instance.capture('free_memo_created', properties: {
      'text_length': text.length,
      'entry_point': entryPoint,
    }));
  }

  /// 楽観的削除: UI から即座に除去、実際の API 呼び出しは後で行う。
  void optimisticRemove(int id) {
    final prev = state.valueOrNull ?? [];
    _setMemos(prev.where((m) => m.id != id).toList());
  }

  /// 【2026-07-25 update】旧 `restoreLocal(FreeMemo)` は削除 undo 機能撤去に
  /// 伴い削除 (memo_page.dart の 2 秒 undo Timer 撤廃、user 報告
  /// 「戻せない状態で誤解を招く」への対応)。

  /// 実際の API 削除 (楽観削除後に呼び出す)。
  Future<void> deleteMemo(int id, {int? daysSinceCreated}) async {
    try {
      await ref.read(freeMemoServiceProvider).deleteMemo(id);
      // 【FEAT-493】メモ削除イベント (best-effort、user 体感パスから外す)
      final props = <String, Object>{'memo_id': id};
      if (daysSinceCreated != null) props['days_since_created'] = daysSinceCreated;
      unawaited(PosthogService.instance.capture('free_memo_deleted', properties: props));
    } catch (_) {
      // 【FEAT-503 アクション9 (2026-07-26)】既に UI から除去済みのため state は
      // 復旧しない (楽観削除、rollback は驚きになる)。ただし soft delete 化で約束が
      // 「ゴミ箱から戻せる」に変わったのに API 失敗で一覧・trash 両方から消えるのは
      // 不誠実なため、rethrow して呼出元 (memo_page._handleSwipeDelete) で SnackBar
      // 通知する。次回 refresh で戻ることを暗黙に許容。
      rethrow;
    }
  }

  /// 【FEAT-500 → FEAT-502 (2026-07-26)】trash からの復元。deleted_at=null にして
  /// 通常一覧に戻す。呼出後に active 一覧 + trash 一覧の両方を invalidate 推奨
  /// (画面側で ref.invalidate(deletedMemosProvider) + refresh() 経由で自動更新)。
  Future<void> restoreMemo(int id) async {
    try {
      await ref.read(freeMemoServiceProvider).restoreMemo(id);
      // 復元後: メモ一覧を再取得 (先頭挿入せず sort 順を backend 真実値に委ねる)
      final result = await ref.read(freeMemoServiceProvider).fetchMemos();
      _setMemos(result.memos);
      _syncHasMore(result.hasMore);
      unawaited(PosthogService.instance.capture('free_memo_restored',
          properties: {'memo_id': id}));
    } catch (_) {
      // 失敗時は何もしない (画面側で SnackBar 案内)
      rethrow;
    }
  }

  /// 【FEAT-500 (2026-07-26)】完全削除 (hard、復元不可)。UI 側で確認 dialog
  /// を経てから呼び出す前提。呼出後は trash 側の一覧を invalidate 必要 (画面側)。
  Future<void> purgeMemo(int id) async {
    try {
      await ref.read(freeMemoServiceProvider).purgeMemo(id);
      unawaited(PosthogService.instance.capture('free_memo_purged',
          properties: {'memo_id': id}));
    } catch (_) {
      rethrow;
    }
  }

  /// メモを type に変換 (API 呼び出し + 楽観的 UI 削除)。
  Future<int> convertMemo(int id, String type, {int? daysSinceCreated}) async {
    final expGain =
        await ref.read(freeMemoServiceProvider).convertMemo(id, type);
    optimisticRemove(id);
    // 【FEAT-493】変換イベント (best-effort、user 体感パスから外す = 変換完了
    // SnackBar 表示が計測往復ぶん遅れないように、await せず fire-and-forget)
    final props = <String, Object>{'to_type': type};
    if (daysSinceCreated != null) props['days_since_created'] = daysSinceCreated;
    unawaited(PosthogService.instance.capture('free_memo_converted', properties: props));
    return expGain;
  }

  Future<void> refresh() async {
    // 【20260729 review §3 A-1 対応】旧実装は先頭で state = AsyncValue.loading()
    // で body 全体を CircularProgressIndicator に差し替えていたため、
    // RefreshIndicator の spinner と二重表示 + FEAT-508 で追加した検索窓 +
    // ヒット中リストが一度消失していた。trash 側 (FEAT-503 アクション6) の楽観
    // 更新パターンを一覧本体にも横展開: 旧データを保持したまま fetch、失敗時は
    // copyWithPrevious(state) で直前 data を error と共に維持する。
    // 【FEAT-503 アクション8】fetchMemos が record を返すようになったため
    // AsyncValue.guard + state 直代入は不可。try/catch で memos/hasMore を分離。
    try {
      final result = await ref.read(freeMemoServiceProvider).fetchMemos();
      _setMemos(result.memos); // state = data + 件数 sync
      _syncHasMore(result.hasMore);
    } catch (e, st) {
      // 失敗時 (AsyncError) は件数 / has_more を触らない = 直前の値を維持する。
      // copyWithPrevious で旧 data を保持 → RefreshIndicator 完了後に
      // error 表示だが list は残る (FEAT-508 検索窓と併存)。
      state = AsyncValue<List<FreeMemo>>.error(e, st).copyWithPrevious(state);
    }
  }

  /// 【2026-07-25】メモテキスト更新 (楽観的 UI 更新 + API 呼び出し)。
  /// 失敗時は前状態にロールバック。
  Future<void> updateMemo(int id, String text) async {
    final prev = state.valueOrNull ?? [];
    final target = prev.firstWhere(
      (m) => m.id == id,
      orElse: () => throw StateError('memo id $id not found'),
    );
    // 楽観的 UI: text 更新後の memo を先頭 (created_at 順維持) or 元の位置に置く。
    // 一覧順序は変えない (元の位置で in-place 更新)。
    final optimistic = FreeMemo(
      id: target.id,
      text: text,
      createdAt: target.createdAt,
      updatedAt: DateTime.now(),
      deletedAt: target.deletedAt,
    );
    _setMemos(prev.map((m) => m.id == id ? optimistic : m).toList());
    try {
      final updated =
          await ref.read(freeMemoServiceProvider).updateMemo(id, text);
      // Backend から返ってきた最新値で置換 (updated_at 等を正確化)
      final latest = state.valueOrNull ?? [];
      _setMemos(latest.map((m) => m.id == id ? updated : m).toList());
    } catch (e) {
      // 失敗時はロールバック
      _setMemos(prev);
      rethrow;
    }
  }
}
