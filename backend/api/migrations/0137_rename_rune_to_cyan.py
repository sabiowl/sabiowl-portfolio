"""【BUG-103 (2026-06-14)】Character `rune` (ルーン) → `cyan` (シアン) リネーム。

変更内容:
  - Character.key:        'rune'  → 'cyan'
  - Character.name:       'ルーン' → 'シアン'
  - Character.image_path: 'rune'  → 'cyan'

【CLAUDE.md「master/seed data 例外条項 (codebase_review 20260530 P1-3 制定)」適用】

  本 migration は master/seed data (Character カタログ) の rename のみで、
  user-generated content (OwnedCharacter / PlayerProfile.active_character) を
  破壊しない (Character.id 不変、FK 整合性は維持される)。よって CLAUDE.md
  「破壊的データマイグレーション禁止」原則の対象外、`RunPython` UPDATE が許容される。

【全 FK 網羅 (例外条項 §2)】

  - `OwnedCharacter.character` (FK to Character, CASCADE)
    → Character.id 不変のため影響なし
  - `PlayerProfile.active_character` (FK to Character, nullable)
    → 同上、影響なし
  - `Character.job` (FK to Job, master data)
    → rune ↔ cyan rename と独立、影響なし

【冪等性 (例外条項 §3)】

  `filter(key='rune').update(...)` 形式で再 apply 安全。
  既に 'cyan' に更新済の場合は filter ヒット 0 件で no-op、競合なし。
  reverse (rollback) も同等の対称 update で安全。
"""
from django.db import migrations


def _rename_rune_to_cyan(apps, schema_editor):
    Character = apps.get_model('api', 'Character')
    Character.objects.filter(key='rune').update(
        key='cyan',
        name='シアン',
        image_path='cyan',
    )


def _rename_cyan_to_rune(apps, schema_editor):
    Character = apps.get_model('api', 'Character')
    Character.objects.filter(key='cyan').update(
        key='rune',
        name='ルーン',
        image_path='rune',
    )


class Migration(migrations.Migration):
    dependencies = [('api', '0136_exp_system_v1_0')]
    operations = [
        migrations.RunPython(_rename_rune_to_cyan, _rename_cyan_to_rune),
    ]
