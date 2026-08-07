"""【FEAT-479 v1 hotfix (2026-07-07)】morning_grassland scene の rename +
piece_count 3 化 + first_light 撤回。

## 背景

眠る世界の 1 番目のシーン (旧「朝の草原」) を **「目覚めの山頂」** に rename、
合わせて Mobile 側の asset ファイルを `world_morning_grassland*.png` →
`world_sunrise*.png` に rename したため、`background_key` も `sunrise` に同期。
さらに、新規ユーザーの 3 日以内成功体験のため **piece_count を 30 → 3** に
変更 (30 ピース版は Ver2+ の景色として再導入検討)。

## 保持

- `key='morning_grassland'` は **不変** (既存 PlayerPuzzleWorld.active_scene FK
  参照 + PlayerPuzzleSceneProgress.scene FK 参照 の永続保護のため、DB 主 key は
  絶対に触らない)
- 既存 user の progress / active / displayed 状態は全て継承される
  (piece_states 長さ調整は puzzle_world_service._get_or_init_progress で lazy
  実施、本 migration では触らない = 破壊的データ操作を回避)

## 変更

- `morning_grassland`:
    `name`:           '朝の草原'          → '目覚めの山頂'
    `background_key`: 'morning_grassland' → 'sunrise'
    `piece_count`:    30                  → 3
- `first_light` (2026-07-07 早朝 pivot 前の別チュートリアルシーン計画): 削除
    (本番 DB には存在しない想定だが、local dev DB で 0177 旧版を適用済の
    可能性があるため safety net として delete)

## CLAUDE.md master/seed data 例外条項適用

3 条件を満たす:

1. **対象が master/seed data のみ**: PuzzleWorldScene の 1 レコード (`morning_grassland`)
   update + 別 1 レコード (`first_light`) delete のみ。user-generated content
   (`PlayerPuzzleWorld` / `PlayerPuzzleSceneProgress` / `PlayerPuzzleWorldHistory`)
   は無傷。
2. **FK 網羅**: `key='morning_grassland'` 参照 3 FK (PlayerPuzzleWorld /
   Progress / History) は全て `key` ベースで `name`/`background_key`/`piece_count`
   は参照されないため FK 無影響。`first_light` は本 pivot 前に seed される
   はずだった master data で、prod 未反映 (0177 no-op 化 済) + local dev の場合
   もまだ user 参照 (PlayerPuzzleWorld.active_scene) は存在しない (Onboarding
   経由の user 選択が発生していないため)。
3. **冪等性**:
   - `filter().update()` で再 apply 安全
   - `first_light` delete も `filter().delete()` で行が無ければ no-op
"""
from django.db import migrations


def apply_pivot(apps, schema_editor):
    Scene = apps.get_model('api', 'PuzzleWorldScene')
    # morning_grassland を rename + 3 ピース化
    Scene.objects.filter(key='morning_grassland').update(
        name='目覚めの山頂',
        background_key='sunrise',
        piece_count=3,
    )
    # first_light (pivot 前計画の別チュートリアルシーン) を削除。存在しなければ no-op。
    # 【安全性】0177 旧版が local dev DB に適用済の可能性のみ考慮。prod では 0177
    # no-op 化により first_light は seed されていない。0177 旧版 apply 済でも
    # user が Onboarding で first_light 選択済でない前提 (silent auto-activate 経路の
    # active_scene FK 発生も本 migration 直前で切替済なので発生しない)。
    Scene.objects.filter(key='first_light').delete()


def revert_pivot(apps, schema_editor):
    Scene = apps.get_model('api', 'PuzzleWorldScene')
    Scene.objects.filter(key='morning_grassland').update(
        name='朝の草原',
        background_key='morning_grassland',
        piece_count=30,
    )
    # first_light の revert は行わない (旧 0177 seed 定義に依存するため。手動で
    # 必要なら旧 SEED_SCENE dict を復元して update_or_create すること)


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0177_first_light_tutorial_scene'),
    ]

    operations = [
        migrations.RunPython(apply_pivot, revert_pivot),
    ]
