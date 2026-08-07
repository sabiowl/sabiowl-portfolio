import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';
import '../../../core/providers/time_segment_provider.dart';
import '../../../core/services/time_segment.dart'; // TimeSegmentX extension (apiKey)
import '../models/sabi_message.dart';
import '../services/sabi_service.dart';

export '../models/sabi_message.dart';
export '../services/sabi_service.dart' show SabiResponse;

// BUG-I: SabiService は apiClientProvider を watch するため、ログアウト→再ログインで
// 新インスタンスが作られるが、autoDispose でないと旧インスタンスが GC されない。
// SabiService はトークン検証・ログアウト境界を越えるべきではないため autoDispose 化する。
final sabiServiceProvider = Provider.autoDispose<SabiService>((ref) {
  return SabiService(ref.watch(apiClientProvider));
});

/// 【新規 (2026-06-26)】ホーム画面の pull-to-refresh 用カウンタ。
///
/// 0 初期値 (= 初回ロード、現状互換: 1 日 1 メッセージ)、refresh の度に +1
/// インクリメント。[sabiMessageProvider] が watch しており、値が変わると
/// 自動で再フェッチが走る (nonce として Backend に送信され、異なるセリフが
/// 返る)。アプリ再起動で 0 にリセット (StateProvider non-persisted)。
final sabiRefreshCounterProvider = StateProvider<int>((_) => 0);

/// 【FEAT-484】bootstrap 経由で注入される sabi メッセージ。
/// `homeBootstrapControllerProvider` が `data['sabi_message']` を受け取ったとき
/// ここに書き込む。`sabiMessageProvider` が nonce==0 の場合にこの値を先読みする。
/// ログアウト時は `ref.invalidate(sabiMessageProvider)` と合わせて null リセット。
final bootstrapSabiMessageProvider = StateProvider<SabiMessage?>((ref) => null);

/// ホーム画面用メッセージ（autoDispose: ホーム画面離脱でキャッシュをクリア）
/// timeSegmentProvider と [sabiRefreshCounterProvider] を watch することで、
/// 時間帯変化 or pull-to-refresh で再取得される。
/// [SabiMessage.isRestDay] / [SabiMessage.emotion] を含むフル情報を返す。
///
/// 【FEAT-484】nonce==0 (初回ロード) かつ bootstrap が既に sabi_message を
/// 注入済み ([bootstrapSabiMessageProvider] が非 null) の場合、独立 HTTP
/// リクエストを発行せずその値をそのまま返す（ホーム mount 時の HTTP -1 本）。
/// pull-to-refresh (nonce>0) は通常経路で /sabi/message/ を叩く。
final sabiMessageProvider = FutureProvider.autoDispose<SabiMessage>((ref) {
  final segment = ref.watch(timeSegmentProvider);
  final nonce   = ref.watch(sabiRefreshCounterProvider);
  // nonce==0 かつ bootstrap 注入済み → ネットワークリクエスト不要
  if (nonce == 0) {
    final bootstrapped = ref.watch(bootstrapSabiMessageProvider);
    if (bootstrapped != null) {
      return Future.value(bootstrapped);
    }
  }
  return ref.watch(sabiServiceProvider).fetchMessage(
    timeSegment: segment.apiKey,
    nonce:       nonce,  // 0 のとき SabiService 側で送信スキップ (互換)
  );
});

// ═══════════════════════════════════════════════════════════════════════════
// 【2026-08-02】以下 2 provider は **現在どこからも呼ばれていない**
//
// `grep -rn` を lib + test 全体にかけて、定義箇所と本コメント以外に参照が無い
// ことを確認済 (20260802 functional review §4 C-1、PM が独立に再確認)。
// この 2 つが `/sabi/message/` に `context` を送る唯一の経路なので、Backend の
// `SabiMessageView` の context 分岐 5 種と、YAML の `knowledge` / `streak`
// プールも同時に到達不能である。
//
// **i18n の対象外**: `knowledge` / `streak` プールは `_POOL_TO_YAML_PATH`
// (backend/api/sabi_loader.py) に登録されておらず `SabiMessage` テーブルにも
// 入っていないため、そもそも英訳の投入経路に乗っていない。native reviewer に
// 到達不能な文言の翻訳費を払う対象ではない。
//
// 残してあるのは「達成時にサビが知識を語る」を将来復活させる可能性があるため。
// 削除する場合は git history から復元可能である旨を 1 行残すこと
// (FEAT-506 で `_buildTimelineSettingsSection` を消したときと同じ作法)。
// ═══════════════════════════════════════════════════════════════════════════

/// 習慣達成時メッセージ（context=achievement）
/// パラメータ: (habitCategory, habitName) タプル
/// 使用例: ref.read(sabiAchievementMessageProvider(('学習', '読書')))
final sabiAchievementMessageProvider =
    FutureProvider.autoDispose.family<SabiMessage, (String, String)>(
  (ref, params) {
    final (habitCategory, habitName) = params;
    return ref.watch(sabiServiceProvider).fetchAchievementMessage(
      habitCategory: habitCategory,
      habitName:     habitName,
    );
  },
);

/// 連続記録マイルストーンメッセージ（context=streak）
/// パラメータ: streak 日数
/// 使用例: ref.read(sabiStreakMessageProvider(7))
final sabiStreakMessageProvider =
    FutureProvider.autoDispose.family<SabiMessage, int>(
  (ref, streak) {
    return ref.watch(sabiServiceProvider).fetchStreakMessage(streak: streak);
  },
);
