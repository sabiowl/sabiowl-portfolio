"""【FEAT-408 (2026-06-01)】Backend → PostHog Cloud イベント capture サービス。

FEAT-200 の Flutter PostHog SDK 統合に加え、Backend 判定イベントを直接 PostHog Cloud
に送信する経路を追加する。EXP スロットル / バトル上限 / ダイヤ収支など、Backend 側でのみ
正確に判定できるイベントを計測する。

設計方針:
  - 環境変数 POSTHOG_API_KEY (プロジェクト公開 API キー = Flutter --dart-define と同じ値)
    が未設定の場合は完全 no-op（ローカル開発・テスト環境で PostHog に繋がない）
  - capture 呼出はすべて try/except で best-effort 化 (Pre-mortem S2)
    PostHog 外部 HTTP 失敗でメイン処理 (バトル完了 / 習慣達成 等) をブロックしない
  - distinct_id は 'player_<id>' 形式 (Flutter PosthogService.identify と統一)
  - POSTHOG_HOST も既存 FEAT-245 の _delete_posthog_identity と同じ env var を利用

Render 設定 (CLAUDE.md「Render 環境変数」に追記済):
  POSTHOG_API_KEY: phc_xxx... (PostHog Project API Key)
    ← Flutter ビルドの --dart-define=POSTHOG_API_KEY と同じ値
  POSTHOG_HOST: https://us.i.posthog.com (既存)

計測イベント一覧 (FEAT-408 追加):
  - daily_exp_throttle_reached: EXP スロットル閾値 25 件到達時
  - daily_battle_limit_reached: バトル日次 10 回上限到達時
  - diamond_earned:             ダイヤ取得時 (source プロパティで経路識別)
  - diamond_spent:              ダイヤ消費時 (sink プロパティで経路識別)

計測イベント一覧 (FEAT-465/466 月次カテゴリチャレンジ):
  - challenge_progress_incremented: 進捗 +1 加算時 (1 日 1 回ガード通過時)
  - challenge_reward_granted:   tier 報酬配布時。【FEAT-466】tier='bronze'/
                                 'silver'/'gold' プロパティ必須、3 段階全達成時は
                                 challenge_reward_service._award_challenge_exp が
                                 tier ごとに 3 イベント送信する (集計時に
                                 tier 別件数を素直に COUNT できる設計)。
  - challenge_resolved_not_achieved: lazy 配布で未達 (gold 未到達) 扱いになった時
"""
import logging
import os

import requests

_logger = logging.getLogger(__name__)


def capture(event: str, distinct_id: str, properties: dict | None = None) -> None:
    """PostHog にイベントを best-effort で送信する。

    Pre-mortem S2 対応: try/except で包み、PostHog 外部 HTTP 失敗でもメイン処理が継続。

    Args:
        event:       PostHog イベント名 (例: 'daily_exp_throttle_reached')
        distinct_id: プレイヤーの識別子 (例: 'player_42', Flutter PosthogService と統一)
        properties:  イベントプロパティ dict (None の場合は空 dict として送信)
    """
    # 関数呼び出し時に env var を読む (テスト時のモック injection を容易にするため)
    api_key = os.environ.get('POSTHOG_API_KEY', '').strip()
    host = os.environ.get('POSTHOG_HOST', 'https://us.i.posthog.com').rstrip('/')

    if not api_key:
        # API キー未設定 = ローカル開発 or テスト → no-op
        return

    try:
        requests.post(
            f'{host}/capture/',
            json={
                'api_key':     api_key,
                'event':       event,
                'distinct_id': distinct_id,
                'properties':  properties or {},
            },
            timeout=5,
        )
    except Exception as exc:  # noqa: BLE001
        # Best-effort: 失敗してもメイン処理は継続
        _logger.warning(
            'PostHog capture failed (best-effort, ignored): %s | event=%s distinct_id=%s',
            exc, event, distinct_id,
        )


def capture_for_player(player, event: str, properties: dict | None = None) -> None:
    """プレイヤー向け capture convenience wrapper。

    distinct_id は 'player_{player.pk}' 形式 (Flutter PosthogService.identify と統一)。
    """
    capture(event, f'player_{player.pk}', properties)
