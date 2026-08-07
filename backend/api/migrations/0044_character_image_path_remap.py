"""
0044_character_image_path_remap

migration 0042 のロジックバグを修正。
Character.key（旧ロールID）→ 新識別子 の明示的マッピングで image_path を正しく設定する。

【問題】
migration 0042 は char.key in _NEW_IDENTIFIERS を条件にしていたが、
実際の key は 'warrior_m', 'assassin_f' 等であり _NEW_IDENTIFIERS に含まれないため
0 件しか更新されなかった。

【修正方針】
key と新識別子の対応を明示的にハードコードし、
image_path を確実に正しい識別子へ上書きする。
"""
from django.db import migrations


# DB の key → Flutter のアセット識別子 マッピング
# migration 0015 の初期データ挿入時の key 値をベースに作成
_KEY_TO_IDENTIFIER = {
    'warrior_m':        'sol',
    'assassin_f':       'aria',
    'mage_m':           'rune',
    'healer_f':         'lucia',
    'monk_m':           'zenon',
    'knight_f':         'beatrix',
    'archer_m':         'faye',
    'dark_sorceress_f': 'noir',
}


def remap_image_paths(apps, schema_editor):
    Character = apps.get_model('api', 'Character')
    updated = 0
    for char in Character.objects.all():
        new_id = _KEY_TO_IDENTIFIER.get(char.key)
        if new_id and char.image_path != new_id:
            char.image_path = new_id
            char.save(update_fields=['image_path'])
            updated += 1
    print(f'[0044] Character.image_path remapped: {updated} records updated')


def reverse_remap(apps, schema_editor):
    # ロールバックは元の /character_*.png 形式に戻す
    Character = apps.get_model('api', 'Character')
    reverse_map = {v: f'/character_{v}.png' for v in _KEY_TO_IDENTIFIER.values()}
    for char in Character.objects.all():
        old_path = reverse_map.get(char.image_path)
        if old_path:
            char.image_path = old_path
            char.save(update_fields=['image_path'])


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0043_timelineevent_memo'),
    ]

    operations = [
        migrations.RunPython(remap_image_paths, reverse_remap),
    ]
