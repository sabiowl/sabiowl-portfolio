"""キャラクター role フィールドを FEAT-391 ジョブ名と統一。

【master/seed data 例外条項適用 (codebase_review 20260530 P1-3)】
対象: Character master data の role 表示名更新 (user-generated content 非対象)
条件 1: master/seed data のみ (Character テーブルの role CharField) ✅
条件 2: role は FK なし、CASCADE/PROTECT 影響なし ✅
条件 3: filter().update() で冪等性確保 ✅

変更内容:
- ゼノン (zenon): '雷術士' → 'モンク'
  migration 0062 で '雷術士' に変更されたが、FEAT-391 でジョブ名を 'monk (モンク)' に
  統一したため character 表示名も合わせる。
- ノワール (noir): '暗黒魔道士' → '闇魔導士'
  migration 0015 で '暗黒魔道士' と seed されたが、FEAT-391 のジョブ名 '闇魔導士' と
  統一する。
"""
from django.db import migrations


def _update_character_roles(apps, schema_editor):
    Character = apps.get_model('api', 'Character')
    # ゼノン: 雷術士 → モンク (migration 0062 で変更済の値を FEAT-391 統一名へ)
    Character.objects.filter(key='zenon').update(role='モンク')
    # ノワール: 暗黒魔道士 → 闇魔導士 (FEAT-391 ジョブ名と統一)
    Character.objects.filter(key='noir').update(role='闇魔導士')
    print('[migration 0114] Updated zenon role → モンク, noir role → 闇魔導士')


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0113_timeline_event_unique_constraint_source'),
    ]

    operations = [
        migrations.RunPython(
            _update_character_roles,
            reverse_code=migrations.RunPython.noop,
        ),
    ]
