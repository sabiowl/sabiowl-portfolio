"""Character.key を Flutter 側のキー命名に統一する data migration（FEAT-182）

経緯:
- Flutter `mobile/lib/features/auth/pages/onboarding_page.dart` の `_starters` で
  使われているキャラ key（`aria`, `beatrix`, ...）と、
  バックエンド `Character.key`（`warrior_m`, `assassin_f`, ...）が完全不一致だった。
- `Character.image_path` には既に Flutter キーが入っているため（migration 0044）、
  これをそのまま新 key として採用すれば機械的にマップできる。
- 加えて、Flutter には存在するが DB に投入漏れだった `zenon`（雷術士）を新規 INSERT する
  （`0044_character_image_path_remap.py` で `monk_m → zenon` のマッピング行は
  あったが、`monk_m` レコード自体が DB に存在しないため zenon も未投入だった）。

FK 影響:
- `OwnedCharacter.character` / `PlayerProfile.active_character` は character_id（PK）
  参照のため、key 文字列の書き換えで FK は壊れない。再リンク処理不要。
"""

from django.db import migrations


# (旧 key, 新 key) のマッピング
_KEY_REMAP = [
    ('warrior_m',        'sol'),
    ('assassin_f',       'aria'),
    ('mage_m',           'rune'),
    ('healer_f',         'lucia'),
    ('knight_f',         'beatrix'),
    ('archer_m',         'faye'),
    ('dark_sorceress_f', 'noir'),
]


# 新規 INSERT する zenon の属性。
# 値は Flutter `onboarding_page.dart` の _starters エントリ
#   (key='zenon', name='ゼノン', role='雷術士',
#    description='疾風のごとく駆け抜け、目標を打ち砕く')
# と既存 starter 属性（price=1500, unlock_level=1, order=末尾）に整合させる。
_ZENON_DEFAULTS = {
    'name':         'ゼノン',
    'role':         '雷術士',
    'description':  '疾風のごとく駆け抜け、目標を打ち砕く',
    'is_starter':   True,
    'image_path':   'zenon',
    'price':        1500,
    'unlock_level': 1,
    'order':        7,
}


def forwards(apps, schema_editor):
    """Flutter キーへ統一する正方向の処理。"""
    Character = apps.get_model('api', 'Character')

    # ── 1. 既存 7 件をリネーム ──
    # key は unique=True のため 1 件ずつ update する。ループ順に処理することで
    # 一時的な重複（旧→新が他レコードの旧 key と衝突）を避ける構成だが、
    # 実マッピングは 1-to-1 で衝突しないため安全。
    for old_key, new_key in _KEY_REMAP:
        Character.objects.filter(key=old_key).update(key=new_key)

    # ── 2. zenon を新規 INSERT（既存なら何もしない） ──
    Character.objects.get_or_create(
        key='zenon',
        defaults=_ZENON_DEFAULTS,
    )


def backwards(apps, schema_editor):
    """ロールバック用の逆方向処理。"""
    Character = apps.get_model('api', 'Character')

    # ── 1. zenon を削除 ──
    # OwnedCharacter で参照されている場合は CASCADE で連鎖削除されるが、
    # この migration を巻き戻す状況では zenon は新規投入直後の前提のため実害なし。
    Character.objects.filter(key='zenon').delete()

    # ── 2. 既存 7 件を旧 key に戻す ──
    for old_key, new_key in _KEY_REMAP:
        Character.objects.filter(key=new_key).update(key=old_key)


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0061_drop_magic_link_models'),
    ]

    operations = [
        migrations.RunPython(forwards, backwards),
    ]
