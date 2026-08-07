"""【BUG-105 (2026-06-14)】Starter プールを 6 体 → 2 体 (sol / aria のみ) に縮小。

【変更内容】
  is_starter フラグを以下 4 キャラで False に変更:
    - faye    (アーチャー)
    - lucia   (ヒーラー)
    - cyan    (青魔導士、旧 rune)
    - beatrix (ナイト)

  維持される starter:
    - sol  (戦士)
    - aria (アサシン)

【動作影響】
  - 新規プレイヤーのオンボーディング: sol / aria の 2 択に縮小
  - faye/lucia/cyan/beatrix を欲しい新規ユーザー: ダイヤ購入 (800💎、SR-tier) 経路
  - **既存所持者 (OwnedCharacter 既存行) は影響なし** (FK by id、is_starter は master flag のみ)
  - CharacterSelectView (gamification.py:54) は is_starter=True のみ無料付与経路、
    is_starter=False 化されたキャラへの未所持 select は 403 を返すようになる

【CLAUDE.md「master/seed data 例外条項」適用】
  Character.is_starter (master flag) の UPDATE のみで user-generated content を破壊しない。
  filter().update() で冪等性確保、再 apply 安全。

【全 FK 影響分析 (例外条項 §2)】
  - OwnedCharacter.character (CASCADE) → 不変 (Character.id 不変)
  - PlayerProfile.active_character (FK) → 不変 (同上)
  - Character.job (FK to Job) → 本変更と独立

【スターター 2 体の選定理由 (PM 確定)】
  - sol  (戦士): 最も標準的・初心者向けの直球アタッカー
  - aria (アサシン): 高速行動でテンポよく戦える対比軸
  - 「直球 vs 機動」の対比により初期ジョブ理解を促進
"""
from django.db import migrations


_DEMOTED_STARTERS = ['faye', 'lucia', 'cyan', 'beatrix']


def _shrink_starter_pool(apps, schema_editor):
    Character = apps.get_model('api', 'Character')
    updated = Character.objects.filter(
        key__in=_DEMOTED_STARTERS,
    ).update(is_starter=False)
    print(
        f'[migration 0139 BUG-105] Demoted {updated} characters from starter pool'
        f' (target: {_DEMOTED_STARTERS})'
    )


def _restore_starter_pool(apps, schema_editor):
    Character = apps.get_model('api', 'Character')
    restored = Character.objects.filter(
        key__in=_DEMOTED_STARTERS,
    ).update(is_starter=True)
    print(
        f'[migration 0139 BUG-105 reverse] Restored {restored} characters to starter pool'
    )


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0138_add_black_mage_and_rune'),
    ]

    operations = [
        migrations.RunPython(_shrink_starter_pool, _restore_starter_pool),
    ]
