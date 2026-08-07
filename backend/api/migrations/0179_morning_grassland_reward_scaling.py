"""【FEAT-479 v1 gameplay_review 20260708 対応】morning_grassland (目覚めの山頂)
の完成報酬を 1/10 スケールに調整。

## 背景

migration 0178 で morning_grassland の piece_count を 30 → 3 に変更したが、
reward_exp (1000) と reward_diamonds (500) は 30 ピース想定のまま据え置きだった。
gameplay_review 20260708 P1 指摘:

> 「3 日間の努力で 1 ヶ月級 (Challenge Gold tier と同額) の報酬」という数値の
> 不整合。仕様ピボットの過程で報酬額の同期が漏れた「仕様変更の途中で数値だけが
> 取り残される」構造的パターンの再演。

## 意思決定

当初 first_light 案 (migration 0177 撤回済) の docstring に明記された意図
「本編の 1/10 スケール、small win を祝いつつバランス保持」に揃える。

PM 判断 (2026-07-08 gameplay_review 対応セッション):
- 案 A: 1/10 スケール (100 EXP / 30 ダイヤ) ← **採用**
- 案 B: 現状維持 + welcome gift として doc 明記
- 案 C: 中間案 (500 EXP / 100 ダイヤ)

案 A を採用理由: 当初設計意図と整合、Challenge Gold tier との経済的整合性向上、
新規ユーザーへの「small win を祝う」体験を維持しつつ本編報酬とのバランス確保。

## 変更

- reward_exp:      1000 → 100  (1/10 スケール)
- reward_diamonds:  500 →  30  (1/10 スケール)

## 影響範囲

- **新規ユーザー**: 目覚めの山頂完成時の報酬が 100 EXP / 30 ダイヤに減額。
  Challenge Gold tier (1000 EXP、通常 1 ヶ月級継続で獲得) との数値不整合を解消。
- **既存の完成済ユーザー**: 影響なし。PlayerPuzzleWorldHistory に保存済の
  `reward_exp_gained` / `reward_diamonds_gained` は変更されず、
  過去付与額の遡及調整もしない (`try_grant_quest_piece` の完成時付与ロジックが
  最新の reward_exp / reward_diamonds を参照するのは "これから完成する場合" のみ)。

## CLAUDE.md master/seed data 例外条項適用

3 条件を満たす:
1. **対象が master/seed data のみ**: PuzzleWorldScene の 1 レコード update のみ、
   user-generated content (PlayerPuzzleWorld / Progress / History) は無傷。
2. **FK 網羅**: key='morning_grassland' 参照 3 FK は全て key ベースで reward 値に
   依存しない = FK 無影響。
3. **冪等性**: filter().update() で再 apply 安全。
"""
from django.db import migrations


def apply_reward_scaling(apps, schema_editor):
    Scene = apps.get_model('api', 'PuzzleWorldScene')
    Scene.objects.filter(key='morning_grassland').update(
        reward_exp=100,
        reward_diamonds=30,
    )


def revert_reward_scaling(apps, schema_editor):
    Scene = apps.get_model('api', 'PuzzleWorldScene')
    Scene.objects.filter(key='morning_grassland').update(
        reward_exp=1000,
        reward_diamonds=500,
    )


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0178_morning_grassland_rename_sunrise'),
    ]

    operations = [
        migrations.RunPython(apply_reward_scaling, revert_reward_scaling),
    ]
