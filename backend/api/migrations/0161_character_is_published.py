"""【2026-06-27】Character.is_published フラグ追加 + 初回リリース 6 体公開。

【背景】
ユーザー判断 (2026-06-27): キャラを 14 体実装しているが、初回リリースでは 6 体に絞り、
月に 1〜2 体ずつ段階公開していきたい。Django admin で公開/非公開を運営が制御。

【初回リリース構成 (PM 確定)】
  - Starter 2 体 (オンボーディング無料): sol (ソウル), aria (アリア)
  - 入手可能 4 体 (ガチャ・購入): rune (ルーン), lucia (ルシア), beatrix (ベアトリス), faye (フェイ)
  - 非公開 8 体 (キャラ一覧 / ガチャ / 購入経路から完全除外): その他

【変更内容】
  Step 1: AddField is_published (BooleanField default=False)
  Step 2: RunPython で上記 6 体 (sol/aria/rune/lucia/beatrix/faye) を is_published=True

【動作影響】
  - 非公開キャラ (8 体) は CharacterListView から消える (Mobile キャラ一覧非表示)
  - ガチャ抽選 `_pick_random_character_id` も is_published=True only に絞られる (BUG-131 系の整合)
  - 直接購入 (CharacterPurchaseView 等) も is_published=True ガード追加 (race 防御)
  - **既存所持者 (OwnedCharacter 既存行) は影響なし** (FK by id、is_published は master flag のみ)
  - active_character も影響なし (FK PROTECT、Player の active キャラ表示は維持)

【CLAUDE.md「master/seed data 例外条項」適用】
  Character (master data) の is_published flag UPDATE のみで user-generated content を破壊しない。
  filter().update() で冪等性確保、再 apply 安全。

【全 FK 影響分析 (例外条項 §2)】
  - OwnedCharacter.character (CASCADE) → 不変 (Character.id 不変)
  - PlayerProfile.active_character (FK PROTECT) → 不変 (同上)
  - Character.job (FK to Job, PROTECT) → 本変更と独立
  - Announcement.link_character (FK SET_NULL、2026-06-27 0160 で追加) → 不変

【段階公開の運用フロー (本 migration 後)】
  1. Django admin の Character 一覧で is_published を ON/OFF
  2. list_editable で一括編集可能
  3. Mobile は次回 API コール時に新しい公開リストを取得
  4. 非公開化したキャラは Mobile 一覧から消えるが、所有済ユーザーの active 状態は維持
"""
from django.db import migrations, models


_INITIAL_PUBLISHED_KEYS = [
    # Starter 2 体 (オンボーディング保護対象だが、明示的に is_published=True も付与)
    'sol',
    'aria',
    # ガチャ・購入で入手可能な 4 体
    'rune',
    'lucia',
    'beatrix',
    'faye',
]


def _publish_initial_six(apps, schema_editor):
    Character = apps.get_model('api', 'Character')
    updated = Character.objects.filter(
        key__in=_INITIAL_PUBLISHED_KEYS,
    ).update(is_published=True)
    print(
        f'[migration 0161] Published {updated} characters '
        f'(target: {_INITIAL_PUBLISHED_KEYS})'
    )


def _unpublish_all(apps, schema_editor):
    """reverse: 全キャラを is_published=False に戻す (RunPython.noop ではなく
    明示的に unpublish しておく、巻き戻し時の整合性確保)。"""
    Character = apps.get_model('api', 'Character')
    Character.objects.update(is_published=False)


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0160_new_character_announce'),
    ]

    operations = [
        migrations.AddField(
            model_name='character',
            name='is_published',
            field=models.BooleanField(
                default=False,
                help_text='False = 非公開 (一覧 / ガチャ / 購入から除外)。starter は本フラグに関わらず常時公開',
                verbose_name='公開フラグ',
            ),
        ),
        migrations.RunPython(_publish_initial_six, _unpublish_all),
    ]
