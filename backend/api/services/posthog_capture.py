"""【FEAT-408 (2026-06-01)】Backend → PostHog Cloud イベント capture サービス。

FEAT-200 の Flutter PostHog SDK 統合に加え、Backend 判定イベントを直接 PostHog Cloud
に送信する経路を追加する。EXP スロットル / バトル上限 / ダイヤ収支など、Backend 側でのみ
正確に判定できるイベントを計測する。

設計方針:
  - 環境変数 POSTHOG_API_KEY (プロジェクト公開 API キー = Flutter --dart-define と同じ値)
    が未設定の場合は完全 no-op（ローカル開発・テスト環境で PostHog に繋がない）
  - capture 呼出はすべて try/except で best-effort 化 (Pre-mortem S2)
    PostHog 外部 HTTP 失敗でメイン処理 (バトル完了 / 習慣達成 等) をブロックしない
  - 【FEAT-524 Phase 1 (2026-08-08)】送信は `transaction.on_commit` 経由。
    try/except は「失敗」を吸収するが「遅延」は止めないため、atomic ブロックの内側
    から送ると行ロックを保持したまま外部 HTTP を待つことになる。送信をコミット後に
    逃がすことで、ロック保持時間から外部 I/O を完全に切り離す。
    → **`TestCase` は既定で on_commit を実行しない。** capture が出ることを検証する
      テストは `self.captureOnCommitCallbacks(execute=True)` で包むこと
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
from django.db import transaction

_logger = logging.getLogger(__name__)

# 【FEAT-524 Phase 1 (2026-08-08)】TCP + TLS ハンドシェイクを毎回やり直さないための
# Session 再利用。**import 時には接続を張らない** (最初の post まで遅延される) ため、
# gunicorn の fork 前に接続が確立されることはない (Pre-mortem #2)。
#
# ⚠️ `requests.Session` は公式に thread-safe を保証していない。現状 `render.yaml` の
#    startCommand は `--workers` / `--threads` を指定しておらず **sync worker
#    (1 プロセス 1 スレッド)** なので単一スレッドから触られる。**`--threads` を足す
#    なら Session の共有をやめる**こと (thread local 化 or 都度生成)。
_session = requests.Session()

# 計測イベントに 5 秒は長い。on_commit でリクエスト経路の外に出したうえで、
# 接続を溜めない意味で (connect, read) を詰める。
#
# 【2026-08-08 PM レビューで connect を 1.0 → 2.0 に】Render は Singapore、PostHog は
# US。RTT ~180ms に対し TLS ハンドシェイクは 2-3 RTT 必要で、**connect 1.0s は
# worker 起動直後 / keep-alive 切れ後の 1 本目が入らないことがある** (Session 再利用が
# 効くのは 2 本目以降)。「たまに初回イベントだけ欠ける」計測を避けるため広げた。
# 合計 4.0s は旧 `timeout=5` より短いままなので、詰める意図は保たれている。
_CAPTURE_TIMEOUT = (2.0, 2.0)


def _post(host: str, api_key: str, event: str, distinct_id: str, properties: dict) -> None:
    """実際の HTTP 送信。`capture()` から `transaction.on_commit` 経由でのみ呼ばれる。

    Pre-mortem S2 対応: try/except で包み、PostHog 外部 HTTP 失敗でもメイン処理が継続。
    """
    try:
        _session.post(
            f'{host}/capture/',
            json={
                'api_key':     api_key,
                'event':       event,
                'distinct_id': distinct_id,
                'properties':  properties,
            },
            timeout=_CAPTURE_TIMEOUT,
        )
    except Exception as exc:  # noqa: BLE001
        # Best-effort: 失敗してもメイン処理は継続
        _logger.warning(
            'PostHog capture failed (best-effort, ignored): %s | event=%s distinct_id=%s',
            exc, event, distinct_id,
        )


def capture(event: str, distinct_id: str, properties: dict | None = None) -> None:
    """PostHog にイベントを best-effort で送信する。**送信はコミット後**。

    【FEAT-524 Phase 1 (2026-08-08)】`transaction.on_commit` に逃がす。

    従来は `apply_count_change` の `with transaction.atomic():` の**内側**から
    同期 POST が出ており、`PlayerProfile` の行ロック (および
    `increment_challenge_progress` が取る `Challenge` の**全ユーザー共有**行ロック)
    を保持したまま SG → US の往復を待っていた。`try/except` は**失敗**を吸収するが
    **遅延**は止めない、というのが FEAT-408 Pre-mortem S2 に欠けていた軸。

    atomic ブロックの外から呼ばれた場合、`on_commit` は即時実行されるので
    **呼び出し側の分岐は不要** (呼び出し側 8 ファイルは無改造)。

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
        # (on_commit を登録すらしないので、コールバックも溜まらない)
        return

    # ロールバックされた場合は送信しない = 「起きなかったこと」を計測しない副次効果。
    props = properties or {}
    transaction.on_commit(
        lambda: _post(host, api_key, event, distinct_id, props)
    )


def capture_for_player(player, event: str, properties: dict | None = None) -> None:
    """プレイヤー向け capture convenience wrapper。

    distinct_id は 'player_{player.pk}' 形式 (Flutter PosthogService.identify と統一)。
    """
    capture(event, f'player_{player.pk}', properties)
