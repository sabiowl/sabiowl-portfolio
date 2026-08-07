"""【BUG-119 (2026-06-14)】GachaHistory.character FK 追加 (nullable)。

【経緯】
  ガチャ画面の最近の履歴で character 排出時に reward.name (例: 「マンスリーキャラ
  (SSR)」「レアキャラ (SSR)」) と汎用名で表示されており、実際に排出された
  キャラ名 (例: 「ルーン」「シアン」) が分からない問題。GachaStatusView の history
  serializer で h.reward.name を使っていたため、catalog エントリ名の文字列が出る。

【変更内容】
  GachaHistory に Character への nullable FK を追加し、character 型の reward を
  排出した時に具体的な Character を保存する。GachaStatusView.history では
  h.character.name を優先表示することで「キャラ名 (SSR)」表示を実現する。

【スキーマ変更のみ】
  on_delete=SET_NULL: Character が rename されても履歴は維持。Character 削除時
  (master/seed 例外条項適用の特殊ケース) でも履歴の構造的整合性を確保。
  null=True, blank=True: 既存履歴 + 非 character 型 reward の場合は null。

【既存データの backfill は行わない】
  既存履歴を遡って char_id を特定する手段がない (GachaReward.value=0 のキャラ
  ランダム排出だった場合、当時どのキャラだったか復元不能)。新規履歴のみ
  character FK が埋まる仕様で許容。既存表示は従来通り reward.name に fallback。

【全 FK 影響分析 (CLAUDE.md「master/seed data 例外条項」§2 準拠)】
  - GachaHistory.character → Character (新規 FK、SET_NULL)
  - 既存 FK (player, reward) は不変
"""
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0142_character_display_order'),
    ]

    operations = [
        migrations.AddField(
            model_name='gachahistory',
            name='character',
            field=models.ForeignKey(
                blank=True,
                null=True,
                on_delete=models.SET_NULL,
                related_name='gacha_histories',
                to='api.character',
                verbose_name='排出キャラ',
                help_text='character 型の reward 排出時のみ非 null',
            ),
        ),
    ]
