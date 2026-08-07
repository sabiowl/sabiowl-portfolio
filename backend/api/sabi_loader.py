"""sabi_dialogue.yaml + DB (SabiMessage) を統合してサビセリフを返すユーティリティ。

## レイヤー設計 (2026-06-26 拡張)

1. **YAML を読み込み** (初期化時 1 回) → 全プール構造の base
2. **DB の SabiMessage から SQL クエリ** (60s TTL Django cache)
3. **DB に対象プールの有効レコードが 1 件以上ある場合**、YAML の該当プールを
   DB content で **完全上書き**
4. **DB が空のプールは YAML 値をそのまま使う** (フォールバック)

これにより:
- 管理画面 (`/admin/api/sabimessage/`) からプール単位で編集・追加・無効化可能
- YAML を初期 seed として保持 (migration 0158 で投入)
- 構造化プール (greetings / streak / knowledge) は YAML 専用のまま (現状維持)
- post_save / post_delete signal で cache 即時 invalidate

## キャッシュ

Django 標準 `django.core.cache` を使い 60 秒 TTL でメモリ保持。テストや
admin 更新時には [clear_cache] で明示的に消す。
"""
import yaml
from pathlib import Path

from django.core.cache import cache

_YAML_CACHE: dict | None = None
_MERGED_CACHE_KEY    = 'sabi_dialogue_merged_v1'
_MERGED_CACHE_KEY_EN = 'sabi_dialogue_merged_en_v1'  # 【FEAT-489 Phase 4】
_MERGED_CACHE_TTL = 60  # seconds

# DB プール名 (e.g., 'home_no_habits') から YAML 上の位置 (path, key) へのマップ。
# DB に 1 件以上 active レコードがあるプールは YAML の該当キーを上書きする。
_POOL_TO_YAML_PATH = {
    # home pools
    'home_no_habits':         (('home',), 'no_habits'),
    'home_all_done':          (('home',), 'all_done'),
    'home_partial':           (('home',), 'partial'),
    'home_none_done':         (('home',), 'none_done'),
    'home_high_level':        (('home',), 'high_level'),
    'home_early_level':       (('home',), 'early_level'),
    'home_pun':               (('home',), 'pun'),
    'home_knowledge_general': (('home',), 'knowledge_general'),
    # contexts
    'context_rest_day':  (('contexts',), 'rest_day'),
    'context_comeback':  (('contexts',), 'comeback'),
    'context_default':   (('contexts',), 'default'),
    'context_undo':      (('contexts',), 'undo'),
    # time_segment
    'time_early_morning': (('time_segment',), 'early_morning'),
    'time_morning':       (('time_segment',), 'morning'),
    'time_noon':          (('time_segment',), 'noon'),
    'time_evening':       (('time_segment',), 'evening'),
    'time_night':         (('time_segment',), 'night'),
    'time_late_night':    (('time_segment',), 'late_night'),
}


def _load_yaml() -> dict:
    """YAML をプロセス内 1 回だけロード (構造化プール用、変更頻度極小)。"""
    global _YAML_CACHE
    if _YAML_CACHE is None:
        path = Path(__file__).parent / 'sabi_dialogue.yaml'
        with open(path, encoding='utf-8') as f:
            _YAML_CACHE = yaml.safe_load(f)
    return _YAML_CACHE


def _fetch_db_pools(locale: str = 'ja') -> dict:
    """DB の SabiMessage (is_active=True) をプール別に集計。【FEAT-489 Phase 4】locale 対応。

    locale='en': content_en が空でなければ en を返し、空なら ja に fallback。
    返り値: { pool_key: [text1, text2, ...] }
    DB アクセス失敗時 (migration 前 / テスト初期化等) は空 dict で安全側。
    """
    try:
        from .models import SabiMessage  # 遅延 import (circular 回避)
        pools: dict[str, list[str]] = {}
        for msg in (
            SabiMessage.objects
            .filter(is_active=True)
            .order_by('pool', 'sort_order', 'id')
            .values('pool', 'content', 'content_en')
        ):
            if locale == 'en':
                text = (msg.get('content_en') or '').strip() or msg['content']
            else:
                text = msg['content']
            pools.setdefault(msg['pool'], []).append(text)
        return pools
    except Exception:
        # migration 未適用 / content_en column 未作成 / テスト用 raw DB アクセス等の早期 fallback
        return {}


def _merge_yaml_with_db(yaml_data: dict, db_pools: dict) -> dict:
    """YAML をベースに、DB の各プールが空でなければ YAML 値を上書き。

    in-place 書き換えではなく shallow copy を返す (テスト純粋性のため)。
    """
    if not db_pools:
        return yaml_data

    # shallow copy + 必要箇所のみ deep update
    result = dict(yaml_data)
    for pool_key, messages in db_pools.items():
        if not messages or pool_key not in _POOL_TO_YAML_PATH:
            continue
        (path_tuple, leaf_key) = _POOL_TO_YAML_PATH[pool_key]
        # path_tuple をたどって leaf の dict を取得 (なければ作成)
        node = result
        for segment in path_tuple:
            node = dict(node.get(segment, {}))
            # 親も copy で構造を保ったまま差し替え (deep mutate 回避)
        # 親への参照を作り直し
        parent_chain = [result]
        for segment in path_tuple:
            new_node = dict(parent_chain[-1].get(segment, {}))
            parent_chain.append(new_node)
        # leaf 上書き
        parent_chain[-1][leaf_key] = list(messages)
        # 親チェーンを result に再接続
        for i in range(len(path_tuple) - 1, -1, -1):
            parent_chain[i][path_tuple[i]] = parent_chain[i + 1]
    return result


def load_sabi_dialogue(locale: str = 'ja') -> dict:
    """YAML + DB を統合したセリフ辞書を返す (60s TTL Django cache)。【FEAT-489 Phase 4】locale 対応。"""
    cache_key = _MERGED_CACHE_KEY if locale == 'ja' else _MERGED_CACHE_KEY_EN
    cached = cache.get(cache_key)
    if cached is not None:
        return cached

    yaml_data = _load_yaml()
    db_pools = _fetch_db_pools(locale=locale)
    merged = _merge_yaml_with_db(yaml_data, db_pools)
    cache.set(cache_key, merged, _MERGED_CACHE_TTL)
    return merged


def clear_cache():
    """cache invalidate: SabiMessage の save / delete 等で呼ぶ。"""
    cache.delete(_MERGED_CACHE_KEY)
    cache.delete(_MERGED_CACHE_KEY_EN)  # 【FEAT-489 Phase 4】en cache も invalidate
