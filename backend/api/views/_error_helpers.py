"""【FEAT-475 (2026-07-03)】エラーレスポンス統一 helper。

エラー code 命名規約: <domain>_<action>_<state>
  例: gacha_pull_not_enough_tickets / habit_count_not_enough_charges

【Phase 3 TODO (v1.1)】全 view の旧形式エラーレスポンスを本形式に統一。
  CLAUDE.md「API 設計規則 > エラーレスポンス形式」参照。
"""
from rest_framework.response import Response


def error_response(
    *,
    code: str,
    message: str = '',
    fields: dict | None = None,
    status: int = 400,
    extra: dict | None = None,
):
    """統一エラー形式 {'error': {'code', 'message', 'fields'}} を返す。

    Args:
        code:    machine-readable エラー識別子 (<domain>_<action>_<state> 規約)
        message: user-facing サビ口調メッセージ (Flutter が default 表示)
        fields:  {'field_name': 'エラー文言'} (フォーム表示用、省略可)
        status:  HTTP status code (default 400)
        extra:   **top-level に併記する追加データ** (下記)

    ## `extra` が要る理由 (【FEAT-515 (2026-08-04)】追加)

    旧形式のエラーには、`error` と**並んで**表示に必要なデータを返すものがあった:

    ```python
    {'error': 'daily_battle_limit_reached',
     'message': '本日の上限です 🪶',
     'current_count': 10, 'limit': 13}     # ← ダイアログが数値を出すのに使う
    ```

    Mobile はこれを `data['limit']` のように **top-level から**読む
    (`battle_service.dart` の `DailyBattleLimitReachedException`)。
    `error` の中に畳むと読めなくなるので、top-level に残す。

    移行時にこれを見落とすと **例外も出さずに数値が 0 になる**。実際、本 helper に
    `extra` が無かったため 5 テストが KeyError で落ちて発覚した。

    `error` を上書きしないようガードする。
    """
    body: dict = {'error': {'code': code, 'message': message}}
    if fields:
        body['error']['fields'] = fields
    if extra:
        assert 'error' not in extra, 'extra で error を上書きしないこと'
        body.update(extra)
    return Response(body, status=status)
