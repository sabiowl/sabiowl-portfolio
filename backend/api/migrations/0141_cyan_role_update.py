"""【BUG-110 (2026-06-14)】Character.role 更新: cyan の role を '魔法使い' → '青魔導士'。

【経緯】
  migration 0015 で旧 mage_m (= rune、後の cyan) の role は '魔法使い' で seed。
  FEAT-299 / FEAT-391 (migration 0086 / 0112) で job = blue_mage (青魔導士) に
  整備されたが、Character.role フィールドの更新は migration 0114 で zenon/noir
  分のみ実施され、cyan は取り残されていた (FEAT-391 移行時の見落とし)。
  詳細シートで「魔法使い」と表示される不整合の真因。

【変更内容】
  - Character.key = 'cyan' の role を '魔法使い' → '青魔導士' に更新
  (job_name と一致、Mobile onboarding_page.dart の starter 定義とも一致)

【CLAUDE.md「master/seed data 例外条項」適用】
  Character.role (master flag) の UPDATE のみで user-generated content を破壊しない。
  filter().update() で冪等性確保、再 apply 安全。

【全 FK 影響分析 (例外条項 §2)】
  - OwnedCharacter / PlayerProfile.active_character → 不変 (Character.id 不変)
  - Character.role は表示用 String、JOIN/lookup には使われない
"""
from django.db import migrations


def _update_cyan_role(apps, schema_editor):
    Character = apps.get_model('api', 'Character')
    updated = Character.objects.filter(key='cyan').update(role='青魔導士')
    print(f'[migration 0141 BUG-110] Updated cyan role -> 青魔導士 ({updated} row(s) updated)')


def _revert_cyan_role(apps, schema_editor):
    Character = apps.get_model('api', 'Character')
    Character.objects.filter(key='cyan').update(role='魔法使い')
    print('[migration 0141 BUG-110 reverse] Restored cyan role -> 魔法使い')


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0140_unify_char_price_and_demote_zenon'),
    ]

    operations = [
        migrations.RunPython(_update_cyan_role, _revert_cyan_role),
    ]
