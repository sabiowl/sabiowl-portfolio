"""【BUG-106/107/108 (2026-06-14)】キャラ価格統一 + zenon starter 撤去 + SSR 判定基準変更。

【BUG-106】zenon を starter から除外:
  migration 0062 で is_starter=True で INSERT されていたが、Mobile onboarding は
  FEAT-322 で starter pool から除外する一方、Backend は is_starter=True のままだった。
  結果としてキャラ画面で「選択する」(無料解放) として表示される不整合が残っていた。
  本 migration で BUG-105 (faye/lucia/cyan/beatrix demote) に zenon を追加する形で
  is_starter=False に更新。

【BUG-107】全 non-starter キャラの価格を 1500 に統一:
  PM 判断: キャラ間の価格差 (旧 800-3000💎) は v1.0 ではコンセプト的に意味を失った
  (SR/SSR 区別を廃止し「全キャラ SSR 扱い」に統一する方針)。価格を一律 1500💎 に
  揃え、「全キャラ価値同等」の設計に揃える。

【BUG-108】SSR 判定基準を price >= 3000 → is_starter=False に変更 (gacha.py 側):
  本 migration の直接対応ではなく、gacha.py / gamification.py のコード変更で対処。
  価格 1500 統一により price 基準の SSR proxy が機能しなくなるため、判定基準を
  「starter かどうか」に切り替える (non-starter = 全て SSR 扱い)。

【CLAUDE.md「master/seed data 例外条項」適用】
  Character.is_starter / Character.price (master flag/value) の UPDATE のみで
  user-generated content を破壊しない。filter().update() で冪等性確保、再 apply 安全。

【全 FK 影響分析 (例外条項 §2)】
  - OwnedCharacter.character (CASCADE) → 不変 (Character.id 不変)
  - PlayerProfile.active_character (FK) → 不変
  - Character.job (FK to Job) → 本変更と独立
"""
from django.db import migrations


def _unify_price_and_demote_zenon(apps, schema_editor):
    Character = apps.get_model('api', 'Character')

    # ── Step 1: zenon を starter から外す (BUG-106) ──
    zenon_updated = Character.objects.filter(key='zenon').update(is_starter=False)
    print(
        f'[migration 0140 BUG-106] Demoted zenon from starter pool'
        f' ({zenon_updated} row(s) updated)'
    )

    # ── Step 2: 全 non-starter キャラの価格を 1500 に統一 (BUG-107) ──
    # 注意: Step 1 で zenon を demote した後に実行することで zenon の価格も
    #       1500 に揃う (旧 1200 → 1500)。
    price_updated = Character.objects.filter(is_starter=False).update(price=1500)
    print(
        f'[migration 0140 BUG-107] Unified non-starter character prices to 1500'
        f' ({price_updated} row(s) updated)'
    )


def _restore_pre_unification(apps, schema_editor):
    """ロールバック: 旧個別価格 + zenon starter に戻す。

    完全な値復元はできない (各キャラの旧価格は migration 0110/0128 が真実値)。
    最小限の対称復元として:
      - zenon: is_starter=True に戻す + price=1200 (migration 0110 値)
      - 他キャラ: migration 0110/0128 の値に部分復元 (cyan/rune は本来 800 だが
        BUG-103/104 で rename/追加されているため復元コードからは省略)
    """
    Character = apps.get_model('api', 'Character')

    # zenon: starter に戻す + 1200 復元
    Character.objects.filter(key='zenon').update(is_starter=True, price=1200)

    # 他キャラ: 旧価格に部分復元 (migration 0110 ベース)
    _PRE_UNIFY_PRICES = {
        'lucia':   1000,
        'faye':    1000,
        'beatrix': 1200,
        'noir':    1500,
        'cyan':    800,   # 旧 rune → cyan (BUG-103)
        'rune':    800,   # 新キャラ (BUG-104)
        'kyle':    3000, 'fia':    3000, 'irene':  3000,
        'luna':    3000, 'aurum':  3000,
    }
    for key, price in _PRE_UNIFY_PRICES.items():
        Character.objects.filter(key=key).update(price=price)

    print('[migration 0140 reverse] Restored pre-unification prices + zenon starter')


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0139_starter_pool_2chars'),
    ]

    operations = [
        migrations.RunPython(_unify_price_and_demote_zenon, _restore_pre_unification),
    ]
