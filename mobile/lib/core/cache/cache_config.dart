/// 【FEAT-280】オフラインキャッシュ feature flag + TTL 定数集約。
///
/// ロールバック手順:
///   `flutter build apk --dart-define=CACHE_ENABLED=false`
///   → `enabled` が false になり、すべての SWR 経路で素通し（FutureProvider と同等）。
///
/// この設計の理由:
///   - リリース直後にキャッシュ起因の重大バグが発覚した場合、
///     コード変更なしの hotfix リリースで即座に旧挙動へ復帰できる。
///   - SWR のサイレント失敗（古いデータが正常表示として固定される等）が見つかった場合、
///     Service 層は flag 判定で完全 skip し、API 直叩きに戻す。
class CacheConfig {
  CacheConfig._();

  /// 起動時に環境変数で注入する feature flag。
  /// `--dart-define=CACHE_ENABLED=false` でビルドすると false。
  static const bool enabled = bool.fromEnvironment(
    'CACHE_ENABLED',
    defaultValue: true,
  );

  // ── TTL 定数 ───────────────────────────────────────────────────────
  //
  // 各 TTL は「stale-while-revalidate のキャッシュ寿命」を意味する。
  // TTL を過ぎてもキャッシュは保持され、online 失敗時のフォールバックとして
  // 表示される（古いデータでもエラー画面よりマシ、というポリシー）。

  /// ホーム bootstrap（player / habits / todos / rest_day）。
  /// 頻繁に変わらないため長め。
  static const Duration homeBootstrap = Duration(hours: 24);

  /// タイムラインイベント — 当日 / 未来。
  /// ユーザーが今日の予定を頻繁に追加・編集するため短め。
  static const Duration timelineToday = Duration(minutes: 5);

  /// タイムラインイベント — 過去。
  /// 過去の予定は基本的に変わらないため長め。
  static const Duration timelinePast = Duration(days: 7);

  /// カレンダー bootstrap — 当月。
  /// 当月は習慣ログが追加されて更新されるため中庸。
  static const Duration calendarCurrentMonth = Duration(hours: 1);

  /// カレンダー bootstrap — 過去月。
  /// 過去月は履歴閲覧のみで安定しているため長め。
  static const Duration calendarPastMonth = Duration(days: 30);

  /// GC 起動時の閾値: TTL × この倍数を過ぎたエントリは「絶対に古い」として削除。
  /// 例: TTL 5 分 → 15 分後の起動で完全削除。
  static const int hardExpiryTtlMultiplier = 3;

  /// 容量上限（GC が古い順に削除して以下に抑える）。
  static const int maxCacheBytes = 5 * 1024 * 1024; // 5 MB
}
