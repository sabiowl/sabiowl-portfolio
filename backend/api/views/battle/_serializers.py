"""【2026-08-05】BattleFinishView の入力バリデーション。

## なぜ Serializer に切り出したか

`finish.py` の `post()` は 426 行あり、うち先頭 78 行が手動の入力パース
(`data.get()` × 9 + `_parse_used` クロージャの関数内定義) で占められていた。

DRF を使いながら入力検証に Serializer を使っていない状態で、
コードベース全体でも `is_valid()` は 5 箇所 / 手動 `data.get()` は 50 箇所
という偏りがあった。エラー返却が 153 箇所に散在している根本原因でもある。

## なぜ `serializers.py` ではなくここに置くか

`api/serializers.py` は既に 900 行超の単一ファイルで、追記すると肥大が進む。
本 Serializer は `BattleFinishView` 専用で他から再利用しないため、
view にコロケートする。`views/` 配下は既に `_error_helpers.py` /
`_helpers.py` という underscore 接頭辞の内部モジュール規約があり、それに従う。

## 挙動は 1 ミリも変えていない

移行前に characterization test
(`api/tests/test_battle_finish_validation_contract.py`、22 ケース) を書いて
現行実装に対して pass させ、移行後も同じ結果になることを確認している。

そのため、**現行実装の非対称性もそのまま保持している**:

  - potions 系 (`potions_used` 等) は `int()` で coerce する
    → 文字列 "2" を受け付ける
  - `duration_sec` は `isinstance(int)` で厳密判定する
    → 文字列 "10" を弾く

DRF の `IntegerField` は文字列を coerce するため、素直に使うと
`duration_sec` の挙動が変わってしまう。これを避けるために
`_StrictIntField` / `_CoercedIntField` を用意している。

統一するなら「リファクタのついで」ではなく単独の FEAT で行うこと。
一緒にやると、退行なのか意図した変更なのかが判別できなくなる。
"""
from rest_framework import serializers

from .start import (
    _MAX_NEW_POTIONS_PER_BATTLE,
    _MAX_POTIONS_PER_BATTLE,
)


# ── 現行挙動を保つための独自フィールド ──────────────────────────

class _StrictStringField(serializers.Field):
    """str 型のみ受け付ける。空文字も不正。

    DRF の `CharField` は int を str に coerce する (`12345` → `"12345"`) ため、
    「非文字列の token を弾く」現行挙動を再現できない。
    """

    def to_internal_value(self, data):
        if not isinstance(data, str) or not data:
            raise serializers.ValidationError('invalid')
        return data


class _StrictIntField(serializers.Field):
    """int 型のみ受け付ける (文字列を coerce しない)。負値も不正。

    `isinstance(x, int)` は `bool` も True になるが、現行実装が
    `isinstance(duration_sec, int)` を使っているためその挙動ごと保持する。
    """

    def to_internal_value(self, data):
        if not isinstance(data, int) or data < 0:
            raise serializers.ValidationError('invalid')
        return data


class _CoercedIntField(serializers.Field):
    """`int()` で coerce する。`None` / 未指定は 0 とみなす。

    範囲外は `range` という専用のエラーコードで区別する
    (呼び出し側が `invalid_x` と `x_out_of_range` を出し分けるため)。
    """

    def __init__(self, *, max_value: int, **kwargs):
        self.max_value = max_value
        kwargs.setdefault('required', False)
        # 【重要】現行実装は `data.get(field, 0)` が None を返したとき 0 扱いにする。
        # DRF は `allow_null` を `to_internal_value` より **前** に判定するため、
        # ここを False にすると null で「この項目は null にできません」になり
        # 挙動が変わる。null を受けたうえで 0 に正規化する。
        kwargs.setdefault('allow_null', True)
        super().__init__(**kwargs)

    def to_internal_value(self, data):
        if data is None:
            return 0
        try:
            value = int(data)
        except (TypeError, ValueError):
            raise serializers.ValidationError('invalid')
        if value < 0 or value > self.max_value:
            raise serializers.ValidationError('range')
        return value


class _TruncatedTextField(serializers.Field):
    """`None` を空文字に落とし、`max_length` で切り詰める (弾かない)。"""

    def __init__(self, *, max_length: int, **kwargs):
        self.max_length = max_length
        kwargs.setdefault('required', False)
        # `_CoercedIntField` と同じ理由で null を受ける (現行は `or ''` で空文字化)。
        kwargs.setdefault('allow_null', True)
        super().__init__(**kwargs)

    def to_internal_value(self, data):
        return (data or '')[:self.max_length]


# ── Serializer 本体 ──────────────────────────────────────────────

class BattleFinishSerializer(serializers.Serializer):
    """`POST /api/battle/finish/` の入力検証。

    エラーは `first_error()` で「現行実装と同じ 1 件」に畳んで返す。
    """

    # 【重要】token / result は required=True。
    # 現行実装は `data.get('token', '')` の既定値 '' を検証して
    # `invalid_token` / `invalid_result` を返していた。DRF は required=False の
    # フィールドを **検証せず素通り** させるため、required=False にすると
    # 「未指定なら通ってしまう」という挙動変化が起きる (contract test が検出済)。
    token        = _StrictStringField(required=True)
    result       = serializers.ChoiceField(
        choices=['win', 'lose', 'abandon'], required=True,
    )
    # duration_sec は未指定なら 0 で、0 は正当な値なのでエラーにしない。
    duration_sec = _StrictIntField(required=False)

    damage_dealt = serializers.IntegerField(required=False, default=0)
    damage_taken = serializers.IntegerField(required=False, default=0)
    rounds       = serializers.IntegerField(required=False, default=0)
    summary_text = _TruncatedTextField(max_length=5000, required=False)

    potions_used              = _CoercedIntField(max_value=_MAX_POTIONS_PER_BATTLE)
    recovery_potion_plus_used = _CoercedIntField(max_value=_MAX_NEW_POTIONS_PER_BATTLE)
    attack_potion_used        = _CoercedIntField(max_value=_MAX_NEW_POTIONS_PER_BATTLE)
    defense_potion_used       = _CoercedIntField(max_value=_MAX_NEW_POTIONS_PER_BATTLE)

    # 未指定時の既定値。現行実装の `data.get(key, default)` と同じ。
    _DEFAULTS = {
        'token': '',
        'result': '',
        'duration_sec': 0,
        'damage_dealt': 0,
        'damage_taken': 0,
        'rounds': 0,
        'summary_text': '',
        'potions_used': 0,
        'recovery_potion_plus_used': 0,
        'attack_potion_used': 0,
        'defense_potion_used': 0,
    }

    # 【重要】検証順序。現行実装は上から順に検査して **最初の 1 件だけ** 返す。
    # DRF は全フィールドを検証して辞書で返すため、ここで順序を明示的に復元する。
    # この順序を変えると、複数フィールドが同時に不正なリクエストで
    # 返る code が変わる (contract test が検出する)。
    _FIELD_ORDER = [
        'potions_used',
        'recovery_potion_plus_used',
        'attack_potion_used',
        'defense_potion_used',
        'token',
        'result',
        'duration_sec',
    ]

    # ポーション系フィールドのユーザー向けラベル (エラー文言に埋め込む)
    _POTION_LABELS = {
        'potions_used': '回復薬',
        'recovery_potion_plus_used': '上位回復薬',
        'attack_potion_used': '攻撃の薬',
        'defense_potion_used': '防御の薬',
    }

    # ポーション系以外の固定文言
    _SIMPLE_MESSAGES = {
        'token': ('invalid_token', '認証トークンが不正です 🪶'),
        'result': ('invalid_result', '戦闘結果が不正です 🪶'),
        'duration_sec': ('invalid_duration', '戦闘時間が不正です 🪶'),
    }

    def data_with_defaults(self) -> dict:
        """`validated_data` に未指定フィールドの既定値を補って返す。

        `allow_null=True` のフィールドは、DRF が `to_internal_value` を
        **呼ばずに** `None` をそのまま `validated_data` に載せる。
        現行実装は `None` を 0 / '' として扱っていたので、ここで正規化する
        (しないと `None` が DB まで届いて NOT NULL 制約違反になる)。
        """
        merged = dict(self._DEFAULTS)
        for key, value in self.validated_data.items():
            merged[key] = self._DEFAULTS[key] if value is None else value
        return merged

    def first_error(self) -> tuple[str, str]:
        """`(code, message)` を 1 件だけ返す。現行実装の検証順序を再現する。

        Returns:
            (code, message)。エラーが無い場合は呼ばれない想定。
        """
        for field in self._FIELD_ORDER:
            if field not in self.errors:
                continue

            if field in self._POTION_LABELS:
                label = self._POTION_LABELS[field]
                kind = str(self.errors[field][0])
                if kind == 'range':
                    limit = (
                        _MAX_POTIONS_PER_BATTLE
                        if field == 'potions_used'
                        else _MAX_NEW_POTIONS_PER_BATTLE
                    )
                    return (
                        f'{field}_out_of_range',
                        f'{label}は 0〜{limit} 個までですよ 🪶',
                    )
                return (f'invalid_{field}', f'{label}の使用数が不正です 🪶')

            if field in self._SIMPLE_MESSAGES:
                return self._SIMPLE_MESSAGES[field]

        # _FIELD_ORDER に載っていないフィールド (damage_dealt 等) のエラー。
        # 現行実装はこれらを検証していないため通常は到達しない。
        field = next(iter(self.errors))
        return (f'invalid_{field}', '入力値が不正です 🪶')
