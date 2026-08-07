"""【FEAT-389 (2026-05-30)】Character.price をコイン → ダイヤ価格に更新。

旧: コイン 1500/3000、新: ダイヤ 800-1500 (案 X 緩めグラデーション)。
スターター 2 体 (sol/aria) は price=0 維持。

【RunPython 採用理由】
データ更新のみ (スキーマ変更なし)、既存 Character row の price を update。
CLAUDE.md「破壊的データマイグレーション禁止」原則の **更新系は許可** に該当
(削除系のみ管理コマンド必須、本件は値更新で破壊性なし)。

【FEAT-389】Character.price フィールドの意味論変更 (コイン → ダイヤ)。
フィールド名は backwards-compat のため維持。

【注意】character key は migration 0062 でリネーム済み (mage_m→rune 等)。
本 migration は現行キーで更新する。
"""
from django.db import migrations

# 現行キー (migration 0062 以降の名前) でダイヤ価格を指定
_CHARACTER_PRICE_UPDATE = {
    'rune':    800,    # 魔法使い  800💎
    'lucia':   1000,   # ヒーラー 1000💎
    'faye':    1000,   # アーチャー 1000💎
    'zenon':   1200,   # モンク   1200💎
    'beatrix': 1200,   # ナイト   1200💎
    'noir':    1500,   # 暗黒魔道士 1500💎 (Lv.20 解禁)
}


def _update_character_prices(apps, schema_editor):
    Character = apps.get_model('api', 'Character')
    updated_count = 0
    for key, price in _CHARACTER_PRICE_UPDATE.items():
        updated = Character.objects.filter(key=key).update(price=price)
        if updated:
            print(f'[migration 0110] {key} price -> {price} diamonds')
            updated_count += updated
        else:
            print(f'[migration 0110] {key} not found (skip)')
    print(f'[migration 0110] 更新完了: {updated_count} 件')


def _revert_character_prices(apps, schema_editor):
    """rollback: 旧価格 (コイン 1500/3000) に戻す。"""
    Character = apps.get_model('api', 'Character')
    for key in ['rune', 'lucia', 'faye', 'zenon', 'beatrix']:
        Character.objects.filter(key=key).update(price=1500)
    Character.objects.filter(key='noir').update(price=3000)


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0109_enemy_griffin_seed'),
        # 【SEC-14 (2026-05-30)】旧: BUG-76 branch merge 結合点として
        # ('api', '0101_timeline_event_unique_constraint_source') を依存していたが、
        # 0101_source は 0113_timeline_event_unique_constraint_source にリネームされ
        # 0112 依存の線形チェーン末尾に統合された (SEC-14 指示書参照)。
        # 0113 は 0110→0111→0112 より後になるため、0110 側で依存する必要はない。
    ]

    operations = [
        migrations.RunPython(_update_character_prices, _revert_character_prices),
    ]
