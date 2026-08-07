"""【FEAT-479 v1 hotfix (2026-07-07)】方針転換により no-op 化。

## 経緯

- 当初 (2026-07-07 早朝): 新規ユーザーの 3 日以内成功体験用に **別チュートリアル
  シーン `first_light` を追加** する設計を採用し、本 migration で seed する予定
  だった。
- PM 判断 (同日午後): **チュートリアル用の別シーンは追加せず、既存の
  `morning_grassland` シーン自体を piece_count=3 に変更 + 新規ユーザーの
  silent auto-activate 対象** に戻す方針に転換 (下記理由)。

## 転換理由

- 「別シーン (first_light)」+「本編シーン (morning_grassland)」の 2 段階は
  ユーザー体験としては 1 シーン多い認知負荷。
- morning_grassland (新名称「目覚めの山頂」) を **そのまま 3 ピースで完成する
  ライトウェイトなスタート景色** に位置付けし直せば、SceneSelectionPage で
  最初から 3 シーン提示可能、first_light を hide する複雑な filter も不要。
- 既存ユーザーへの影響は piece_states の長さ調整のみ (lazy 実施、下記参照)。

## 実際の変更は次 migration に移譲

- 0178 (morning_grassland rename + piece_count 変更 + first_light 削除)
- puzzle_world_service.py の `_get_or_init_progress` に piece_states 長さ
  自動調整 (完成済 → `[2,2,2]`、未完成 → `[0,0,0]`) を追加

## 本 migration は no-op

本ファイルは削除せず no-op として残す (migration graph の破壊回避)。migration
番号を欠番にすると別環境で「未適用 migration がある」誤検知が起きる可能性が
あるため、docstring で経緯を明記した空 operations として存置する。
"""
from django.db import migrations


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0176_puzzlescene_is_tutorial'),
    ]

    operations = []
