"""
0038_character_image_path_update

Character.image_path を旧形式（/character_m_normal.png 等）から
識別子のみ（normal_1, archer 等）へ正規化する。

Flutter の CharacterAsset ユーティリティは
  assets/images/characters/character_{identifier}.png
というパスに解決するため、image_path には識別子のみを格納する。
"""

from django.db import migrations


# 旧パス → 新識別子 のマッピング
_PATH_TO_ID = {
    # 旧フルパス形式（/character_*.png）
    '/character_m_normal.png':           'normal_1',
    '/character_m_normal5.png':          'normal_5',
    '/character_normal_1.png':           'normal_1',
    '/character_normal_5.png':           'normal_5',
    '/character_archer.png':             'archer',
    '/character_archer_wear_glass.png':  'archer_wear_glass',
    '/character_mage.png':               'mage',
    '/character_monk.png':               'monk',
    '/character_healer.png':             'healer',
    '/character_knight_2.png':           'knight_2',
    '/character_darksorceress_2.png':    'darksorceress_2',
    # ファイル名のみ形式（先頭スラッシュなし）
    'character_normal_1.png':            'normal_1',
    'character_normal_5.png':            'normal_5',
    'character_archer.png':              'archer',
    'character_archer_wear_glass.png':   'archer_wear_glass',
    'character_mage.png':                'mage',
    'character_monk.png':                'monk',
    'character_healer.png':              'healer',
    'character_knight_2.png':            'knight_2',
    'character_darksorceress_2.png':     'darksorceress_2',
}

# 識別子として有効な値（変換不要なレコードを誤変換しないためのホワイトリスト）
_VALID_IDS = {
    'normal_1', 'normal_5', 'archer', 'archer_wear_glass',
    'mage', 'monk', 'healer', 'knight_2', 'darksorceress_2',
}


def normalize_image_paths(apps, schema_editor):
    Character = apps.get_model('api', 'Character')
    updated = 0
    for char in Character.objects.all():
        path = char.image_path or ''
        if path in _VALID_IDS:
            continue  # すでに正規化済み
        new_id = _PATH_TO_ID.get(path)
        if new_id:
            char.image_path = new_id
            char.save(update_fields=['image_path'])
            updated += 1
    print(f'[0038] Character.image_path normalized: {updated} records updated')


def reverse_normalize(apps, schema_editor):
    # ロールバックは image_path を /character_{id}.png 形式に戻す
    Character = apps.get_model('api', 'Character')
    for char in Character.objects.all():
        if char.image_path in _VALID_IDS:
            char.image_path = f'/character_{char.image_path}.png'
            char.save(update_fields=['image_path'])


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0037_habit_priority_due_date'),
    ]

    operations = [
        migrations.RunPython(normalize_image_paths, reverse_code=reverse_normalize),
    ]
