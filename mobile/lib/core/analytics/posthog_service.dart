import 'package:flutter/foundation.dart';
import 'package:posthog_flutter/posthog_flutter.dart';

/// PostHog プロダクトアナリティクスのラッパー（FEAT-200）。
///
/// 設計原則:
/// - **個人情報を送らない**: メール・名前・認証トークン等は capture しない
/// - **識別子は `PlayerProfile.id` のみ**: `player_<id>` 形式の distinct_id
/// - **セッションリプレイは無効**: ユーザー画面の録画はしない（プライバシー配慮）
/// - **API キーは --dart-define で注入**: リポジトリにコミットしない
///
/// 呼び出し方:
/// ```dart
/// // アプリ起動時
/// await PosthogService.instance.init();
///
/// // ユーザー識別（ゲスト初期化完了時 / 連携完了時）
/// await PosthogService.instance.identify(playerId, isGuest: true);
///
/// // イベント送信
/// await PosthogService.instance.capture('habit_created', properties: {
///   'category':   '学習',
///   'difficulty': 'easy',
/// });
///
/// // ログアウト・アカウント削除時
/// await PosthogService.instance.reset();
/// ```
///
/// 初期化失敗時（API キー未設定など）は no-op として動作し、アプリ機能には
/// 一切影響しない（best-effort design）。
class PosthogService {
  PosthogService._();
  static final PosthogService _instance = PosthogService._();
  static PosthogService get instance => _instance;

  bool _initialized = false;

  // 【FEAT-270】セッション内冪等性フラグ。同じ (playerId, isGuest) で呼び出された
  // 場合は識別 API を再送しない（playerNotifier 再ビルド毎の冗長な identify を抑制）。
  // reset() でクリアされる。
  int? _lastIdentifiedPlayerId;
  bool? _lastIdentifiedIsGuest;

  /// アプリ起動時に呼ぶ。
  ///
  /// API キーは `--dart-define=POSTHOG_API_KEY=phc_xxx` でビルド時に注入する。
  /// ホストも `--dart-define=POSTHOG_HOST=https://eu.i.posthog.com` で切替可。
  /// キーが空の場合は初期化をスキップし、以降の `capture` / `identify` は no-op。
  Future<void> init() async {
    if (_initialized) return;

    // ignore: do_not_use_environment
    const apiKey = String.fromEnvironment('POSTHOG_API_KEY');
    // ignore: do_not_use_environment
    const host = String.fromEnvironment(
      'POSTHOG_HOST',
      defaultValue: 'https://us.i.posthog.com',
    );

    if (apiKey.isEmpty) {
      if (kDebugMode) {
        debugPrint('[PostHog] POSTHOG_API_KEY 未設定のためアナリティクス無効');
      }
      return;
    }

    try {
      final config = PostHogConfig(apiKey)
        ..host = host
        // app_opened / app_backgrounded を SDK が自動 capture する
        ..captureApplicationLifecycleEvents = true
        // 【FEAT-200】セッションリプレイは無効。有効化する場合はユーザー同意取得が必要
        ..sessionReplay = false
        ..debug = kDebugMode;

      await Posthog().setup(config);
      _initialized = true;
      if (kDebugMode) {
        debugPrint('[PostHog] initialized (host=$host)');
      }
    } catch (e, st) {
      // 初期化失敗はアプリ動作を止めない（best-effort）
      debugPrint('[PostHog] init failed: $e\n$st');
    }
  }

  /// ユーザー識別子をセットする。
  ///
  /// - `playerId`: `PlayerProfile.id`（int）。`player_<id>` の形式で distinct_id にする
  /// - `isGuest`: ゲストセッションなら true、認証済みユーザーなら false
  ///
  /// ⚠️ user_properties にメール・名前を入れないこと。PII を送らない設計。
  Future<void> identify(int playerId, {bool isGuest = false}) async {
    if (!_initialized) return;
    // 【FEAT-270】同 (playerId, isGuest) なら再送しない（セッション内 1 回化）。
    if (_lastIdentifiedPlayerId == playerId &&
        _lastIdentifiedIsGuest == isGuest) {
      return;
    }
    try {
      await Posthog().identify(
        userId: 'player_$playerId',
        userProperties: {
          'is_guest': isGuest,
        },
      );
      _lastIdentifiedPlayerId = playerId;
      _lastIdentifiedIsGuest  = isGuest;
    } catch (e) {
      debugPrint('[PostHog] identify failed: $e');
    }
  }

  /// 識別子クリア（ログアウト・アカウント削除時に呼ぶ）。
  Future<void> reset() async {
    if (!_initialized) return;
    try {
      await Posthog().reset();
      // 【FEAT-270】識別キャッシュもクリアし、次の identify で必ず送信させる
      _lastIdentifiedPlayerId = null;
      _lastIdentifiedIsGuest  = null;
    } catch (e) {
      debugPrint('[PostHog] reset failed: $e');
    }
  }

  /// イベント送信。
  ///
  /// `properties` には PII を含めない（メール・名前・トークン等）。
  /// 値が null のキーは含めない（PostHog の集計から外れるため）。
  Future<void> capture(
    String event, {
    Map<String, Object>? properties,
  }) async {
    if (!_initialized) return;
    try {
      await Posthog().capture(
        eventName: event,
        properties: properties,
      );
    } catch (e) {
      debugPrint('[PostHog] capture($event) failed: $e');
    }
  }
}
