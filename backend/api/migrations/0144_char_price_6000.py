"""【BUG-131 (2026-06-17)】非 starter キャラの購入価格を 1500 → 6000 ダイヤに変更。

【背景】
PM 判断: Monthly ガチャ (確定) + Weekly ガチャ (BUG-131 で 0.5% に削減) と
バランスを取るため、Shop ダイヤ購入経路の価格を引き上げて「課金/ガチャ運の
代替路としての重み」を強化する。1500 ダイヤは初期 seed (500) + 連続ログイン
(100 × 6 日 = 600) で 1 週間程度で到達可能だったが、6000 ダイヤは複数週の
継続を要求するため、Monthly 確定の価値が相対的に上がる。

【キャラ入手経路 (BUG-131 後)】
1. Monthly チケット (21 日達成 / 月、FEAT-433): 100% 確定 SSR character
2. Weekly チケット: 0.50% サプライズ (BUG-131、weight=1/200)
3. Shop ダイヤ購入: 6000💎 / 体 (本 migration)

【CLAUDE.md「master/seed data 例外条項」適用】
1. 対象は Character.price (master value) の UPDATE のみ、user-generated content
   (OwnedCharacter / Habit / PlayerProfile.diamonds 等) は破壊しない。
2. 全 FK 走査: Character への FK は OwnedCharacter.character (CASCADE) /
   PlayerProfile.active_character (FK) の 2 本のみ、UPDATE は Character.price
   のスカラ値変更で FK 連鎖なし。
3. 冪等性: filter(is_starter=False).update(price=6000) で再 apply 安全。

【ロールバック】
直前の BUG-107 (migration 0140) 値 1500 に戻す。1500 → 旧個別価格 (800-3000)
への完全復元は migration 0140 の reverse でカバー、本 migration は 0140 までの
ロールバックのみ担当。
"""
from django.db import migrations


def _set_char_price_6000(apps, schema_editor):
    Character = apps.get_model('api', 'Character')
    updated = Character.objects.filter(is_starter=False).update(price=6000)
    print(
        f'[migration 0144 BUG-131] Updated non-starter Character.price to 6000'
        f' ({updated} row(s) updated)'
    )


def _revert_to_1500(apps, schema_editor):
    """ロールバック: BUG-107 (migration 0140) 値 1500 に戻す。"""
    Character = apps.get_model('api', 'Character')
    Character.objects.filter(is_starter=False).update(price=1500)
    print('[migration 0144 reverse] Reverted non-starter Character.price to 1500')


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0143_gacha_history_character_fk'),
    ]

    operations = [
        migrations.RunPython(_set_char_price_6000, _revert_to_1500),
    ]
