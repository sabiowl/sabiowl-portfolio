import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/dio_error_helper.dart';  // FEAT-402
import '../../../core/cache/cache_config.dart';  // FEAT-280
import '../../../core/cache/cache_service.dart';  // FEAT-280
import '../../../core/cache/connectivity_indicator.dart';  // FEAT-280
import '../../../core/providers/time_segment_provider.dart';  // FEAT-484
import '../../../core/services/time_segment.dart';  // FEAT-484 (TimeSegmentX.apiKey)
import '../models/habit.dart';
import '../models/player.dart';
import '../providers/habits_provider.dart';
import '../../social/providers/social_provider.dart';
import '../../sabi/providers/sabi_provider.dart';  // FEAT-484
import '../../sabi/models/sabi_message.dart';  // FEAT-484
import '../../free_memo/providers/free_memo_provider.dart';  // codebase-functional-review 20260725 対応 P1 #2
import '../../challenge/models/challenge.dart';  // 【20260729】PendingChallengeReward

// ── ホームブートストラップ ─────────────────────────────────────
//
// GET /api/home/ を 1 本叩いて player / habits / summary /
// unread_notif_count を一括取得し、各個別プロバイダーへ注入する。
//
// 効果: コールドスタート時のホーム到達が「最遅 1 本」→「単独 1 本」に縮む。
//       Singapore→JP RTT × 並列本数 → RTT × 1 で 200ms 圏内に収まる。
//
// FEAT-188: ゲスト基盤がサーバー側に移行したため、ゲスト分岐は撤廃。
// GuestTokenAuthentication により /api/home/ もゲストトークンで認証される。
//
// 【FEAT-280】StreamProvider に切替（FutureProvider → StreamProvider）。
// SWR パターンで「キャッシュ即時 yield → API 結果で差し替え」を実現する。
// AsyncValue インターフェースは互換のため、consumer 側 `.when(data:..., loading:..., error:...)` は無変更。
//
// ┌─────────────────────────────────────────────────────────────────────────┐
// │ 【運用ルール 2026-07-08 codebase_review 20260708 §2-2 対応】             │
// │ ホーム画面 (home_body.dart) に **新しい機能を追加するとき** は必ず        │
// │ 以下を判断し、判断根拠を PR / commit message に残すこと。                │
// │                                                                          │
// │ ┌─ 判断フロー ────────────────────────────────────────────────────┐     │
// │ │ Q1. その機能はホーム初回描画に必要か? (LCP に含めるか)                │     │
// │ │   YES → **/api/home/ の bootstrap payload に統合** する              │     │
// │ │        (Backend `HomeBootstrapView` に field 追加、Mobile は          │     │
// │ │         `homeBootstrapRawProvider` の同一 stream から派生 provider) │     │
// │ │   NO  → Q2 へ                                                      │     │
// │ │                                                                    │     │
// │ │ Q2. 独立 fetch が正当な理由があるか?                                │     │
// │ │   例: 「低頻度更新 (1 日 2 回程度) で autoDispose + キャッシュ戦略」 │     │
// │ │       「ユーザー操作起点で on-demand 発火」                         │     │
// │ │       「ホーム到達後の遅延許容 (Above-the-fold の下)」              │     │
// │ │   YES → **独立 FutureProvider.autoDispose で OK** (現状パターン)     │     │
// │ │        ただし docstring に「なぜ独立か」の理由を 1 行明記            │     │
// │ │   NO  → bootstrap 統合に戻す                                       │     │
// │ └──────────────────────────────────────────────────────────────────────┘     │
// │                                                                          │
// │ この判断ルールが導入される前 (〜2026-07-07) の実装は個別に判断されて     │
// │ おらず、home_body.dart には bootstrap 外の独立 fetch が 5-7 本混在する    │
// │ (puzzle_world / sabi_message / friend_gift / announcement / stats30d /  │
// │  timeline 等)。低速回線 / 高輻輳環境ではこれらの並列本数が「RTT × 1」の  │
// │ 設計原則を蝕むリスクがあるため、次回リファクタ機会で実測 (Flutter        │
// │ DevTools Network タブ) + 個別に本フローで再評価すること。               │
// └─────────────────────────────────────────────────────────────────────────┘

/// 【2026-07-02】private → public に変更。onboarding_page から直接 cache invalidate
/// できるようにするため。旧 `_kHomeBootstrapCacheKey` → `kHomeBootstrapCacheKey`。
const kHomeBootstrapCacheKey = 'home_bootstrap';

/// ブートストラップデータの生 JSON を保持する低レベルプロバイダー。
/// `keepAlive` で保持し、pull-to-refresh / +1 後の invalidate でのみ再フェッチ。
///
/// SWR フロー（FEAT-280）:
///   1. キャッシュあり → 即時 yield（白画面消し）
///   2. 並行で API fetch → 成功なら fresh yield + cache 更新 + ConnectivityIndicator.markOnline
///   3. API 失敗 → cache 維持 + ConnectivityIndicator.markOffline（既に cache を yield 済なら例外を投げない）
///   4. cache も無く API も失敗 → rethrow（呼出元 .when(error: ...) で「うまくいきませんでした」表示）
final homeBootstrapRawProvider =
    StreamProvider<Map<String, dynamic>>((ref) async* {
  ref.keepAlive();
  final service = ref.watch(habitsServiceProvider);
  final cache   = ref.read(cacheServiceProvider);
  final conn    = ref.read(connectivityProvider.notifier);

  // 1. キャッシュ即時表示（feature flag が OFF なら skip される）
  final cached = cache.getMap(kHomeBootstrapCacheKey);
  if (cached != null) {
    yield cached.data;
  }

  // 2. API fetch を試行（cache あれば「最新化中」、無ければ loading 経由）
  if (cached != null) conn.markFetching();
  // 【FEAT-484】time_segment を Bootstrap に含めて sabi_message を 1 本で取得。
  // ref.read: stream restart なしで現在値だけ取る (時間帯変化で stream 再起動しない設計)。
  final segment = ref.read(timeSegmentProvider);
  try {
    final fresh = await service.fetchHomeBootstrap(timeSegment: segment.apiKey);
    // FEAT-280 Pre-mortem #5: 同一内容なら yield をスキップして UI 瞬きを防ぐ。
    if (cached == null || !_mapsLooselyEqual(cached.data, fresh)) {
      yield fresh;
    }
    await cache.setMap(
      kHomeBootstrapCacheKey,
      fresh,
      ttl: CacheConfig.homeBootstrap,
    );
    conn.markOnline();
  } catch (e) {
    // 【FEAT-402】真のネットワーク系のみ markOffline、HTTP 4xx/5xx 等は
    // markOnline 維持 (サーバー応答あり = 実質オンライン)。
    // 旧実装は `e.toString()` で何でも markOffline → 「接続良いのに頻発」原因。
    if (isNetworkError(e)) {
      conn.markOffline(e.toString());
    } else {
      conn.markOnline();
    }
    // cached を既に yield 済なら例外を投げず終了（オフライン表示維持）。
    // cached も無い場合は呼出元のエラーハンドリングに委ねる。
    if (cached == null) rethrow;
  }
});

/// `Map<String, dynamic>` の浅い等価判定（UI 瞬き防止用）。
/// JSON encode 比較は重いため、最初に length 比較で早期 false、
/// その後 jsonEncode で深い比較する 2 段構成。
bool _mapsLooselyEqual(Map<String, dynamic> a, Map<String, dynamic> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  // 重い等価判定: keys 順序差を許容するため jsonEncode するキー昇順 map を使う。
  // 実用上、bootstrap payload は数十 KB なのでパフォーマンス問題なし。
  return _jsonStableEncode(a) == _jsonStableEncode(b);
}

String _jsonStableEncode(Object? o) {
  if (o is Map<String, dynamic>) {
    final keys = o.keys.toList()..sort();
    final buf = StringBuffer('{');
    for (var i = 0; i < keys.length; i++) {
      if (i > 0) buf.write(',');
      buf
        ..write('"')
        ..write(keys[i])
        ..write('":')
        ..write(_jsonStableEncode(o[keys[i]]));
    }
    buf.write('}');
    return buf.toString();
  } else if (o is List) {
    final buf = StringBuffer('[');
    for (var i = 0; i < o.length; i++) {
      if (i > 0) buf.write(',');
      buf.write(_jsonStableEncode(o[i]));
    }
    buf.write(']');
    return buf.toString();
  } else if (o is String) {
    return '"${o.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
  } else {
    return '$o';
  }
}

/// 【FEAT-280】write 操作後に呼ぶ。次回 watch で fresh fetch を強制する。
Future<void> invalidateHomeBootstrapCache(Ref ref) async {
  await ref.read(cacheServiceProvider).invalidate(kHomeBootstrapCacheKey);
  ref.invalidate(homeBootstrapRawProvider);
}

/// 【FEAT-530 (2026-08-29)】ホームが**今**ブートストラップを使っているか、
/// だけを表す標識。値に意味は無く、**element が生きているかどうか**が答えである。
///
/// `HomePage.build` が watch し、`autoDispose` なので HomePage が unmount した
/// 1 イベントループ後に element ごと消える。したがって
/// `ref.exists(homeIsLiveProvider)` は「ホームが今その値を使っているか」に追従する。
///
/// 🔴 **`homeBootstrapRawProvider` 自体に `exists` を使ってはいけない。**
/// あちらは非 autoDispose + `keepAlive()` なので、**一度ホームを開いたら以後
/// 永久に `exists == true` / `hasValue == true`** になる (FEAT-530 Pre-mortem #3
/// が現実になっている形)。それを判定に使うと、全画面バトルからの復帰でも
/// 「ホームは生きている」と誤判定し、`refresh()` が二度と走らなくなる ——
/// FEAT-295 が塞いだ「ホーム盾バッジが古いまま」の再発である。
///
/// 実測 (`battle_finish_refresh_test.dart` が縛っている):
///
/// | ホーム | `invalidate(homeBootstrapRawProvider)` の効果 |
/// |---|---|
/// | watch 中 | 即時再取得 → `setFromBootstrap` で player も更新される |
/// | 離脱後   | 再取得は走るが **player には伝わらない** (下の Provider が
/// |          | 誰にも listen されておらず再評価されないため) |
///
/// 下段があるので、ホーム不在時は `playerNotifierProvider.refresh()` が要る。
final homeIsLiveProvider = Provider.autoDispose<bool>((ref) => true);

/// bootstrap データを個別プロバイダーへ注入するコントローラー。
/// HomePage の build() 先頭で `ref.watch(homeBootstrapControllerProvider)` するだけ。
///
/// 各 Notifier の `setFromBootstrap` が state を直接上書きするため、
/// 個別プロバイダーの初期 API フェッチ（build()）を待たずに描画が始まる。
final homeBootstrapControllerProvider = Provider<void>((ref) {
  final raw = ref.watch(homeBootstrapRawProvider);
  raw.whenData((data) {
    // ① Player
    final playerJson = data['player'] as Map<String, dynamic>?;
    if (playerJson != null) {
      final player = Player.fromJson(playerJson);
      ref.read(playerNotifierProvider.notifier).setFromBootstrap(player);
    }

    // ② 習慣リスト【FEAT-474: has_more_habits 対応】
    final habitsJson = data['habits'] as List<dynamic>?;
    if (habitsJson != null) {
      final habits = habitsJson
          .map((e) => Habit.fromJson(e as Map<String, dynamic>))
          .toList();
      final hasMore = data['has_more_habits'] as bool? ?? false;
      ref.read(habitsNotifierProvider.notifier).setFromBootstrap(habits, hasMore: hasMore);
    }

    // ④ 未読通知数
    final unreadCount = data['unread_notif_count'] as int? ?? 0;
    ref.read(bootstrapUnreadCountProvider.notifier).state = unreadCount;

    // ⑤ 【2026-07-25 codebase-functional-review 20260725 対応 (P1 #2)】
    // 未 archive フリーメモ件数。旧 _FreeMemoSection の独立 fetch (全メモ本文
    // 取得) を廃止、bootstrap の整数 1 個だけで above-the-fold 描画する。
    final freeMemoCount = data['free_memo_count'] as int? ?? 0;
    ref.read(bootstrapFreeMemoCountProvider.notifier).state = freeMemoCount;

    // ⑥ 【FEAT-484】sabi_message (time_segment 指定時のみ Backend から返る)
    final sabiJson = data['sabi_message'] as Map<String, dynamic>?;
    if (sabiJson != null) {
      ref.read(bootstrapSabiMessageProvider.notifier).state =
          SabiMessage.fromJson(sabiJson);
    }

    // ⑦ 【20260729 v1.0.5 Option A】Challenge 期限切れ後の lazy 配布結果を Home
    // 経由で全 user に届ける。Backend `/api/home/` レスポンスに含まれる
    // `pending_challenge_rewards` を parse して home_listeners が listen する
    // StateProvider へ push、home_listeners で achieved_any=true の分のみ
    // Sabi 口調 SnackBar を発火する (challenge_page と同型の演出)。
    // 従来は Challenge 画面を開かない user には配布されない問題があった。
    // Backend が best-effort で例外は握り潰すため、パース失敗も try/catch。
    try {
      final rewardsJson = data['pending_challenge_rewards'] as List<dynamic>?;
      if (rewardsJson != null) {
        final rewards = rewardsJson
            .map((e) => PendingChallengeReward.fromJson(e as Map<String, dynamic>))
            .toList();
        ref.read(bootstrapPendingChallengeRewardsProvider.notifier).state = rewards;
      }
    } catch (_) {
      // parse 失敗は Home 表示を止めない (best-effort)
    }
  });
});

/// 【20260729 v1.0.5 Option A】Challenge lazy 報酬配布の bootstrap 経路。
/// Backend `/api/home/` の `pending_challenge_rewards` から parse された結果を
/// 保持、home_listeners で ref.listen し achieved_any=true の分のみ Sabi 口調
/// SnackBar 発火する。default 空 list、Home 起動ごとに fresh 上書きされる。
final bootstrapPendingChallengeRewardsProvider =
    StateProvider<List<PendingChallengeReward>>((ref) => const []);
