"""
0042_character_image_path_sync_to_key

Character.image_path が旧識別子（normal_1, archer 等）のまま残っているレコードを
Character.key の値（zenon, aria, beatrix 等）に同期する。

Flutter の CharacterAsset は新識別子のみを認識するため、
image_path が旧識別子の場合は全キャラがフォールバック画像（zenon）になる。
"""
from django.db import migrations


_NEW_IDENTIFIERS = {
    'zenon', 'aria', 'beatrix', 'faye', 'faye_wear_glass', 'lucia', 'noir', 'rune', 'sol',
}


def sync_image_paths(apps, schema_editor):
    Character = apps.get_model('api', 'Character')
    updated = 0
    for char in Character.objects.all():
        # image_path が新識別子でなく、かつ key が新識別子と一致する場合のみ同期
        if char.image_path not in _NEW_IDENTIFIERS and char.key in _NEW_IDENTIFIERS:
            char.image_path = char.key
            char.save(update_fields=['image_path'])
            updated += 1
    print(f'[0042] Character.image_path synced from key: {updated} records updated')


def reverse_sync(apps, schema_editor):
    # ロールバックは image_path を復元できないため no-op
    pass


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0041_timelineevent_start_time_nullable'),
    ]

    operations = [
        migrations.RunPython(sync_image_paths, reverse_sync),
    ]
