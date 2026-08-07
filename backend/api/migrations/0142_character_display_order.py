"""【BUG-111 (2026-06-14)】Character.order を PM 指定の並び順に統一。

【経緯】
  キャラ選択画面の並び順を PM が手動指定。Character.order は migration 0015 / 0062
  / 0128 / 0138 で個別に order を割り当てていたが、後から追加されたキャラ (rune
  BUG-104、kyle/fia/irene/luna/aurum FEAT-428) との総合的な並び順が PM 想定と
  異なっていたため、本 migration で 14 体全ての order を一括更新。

【PM 指定並び順】
  上から左→右の 2 列 7 行レイアウト (キャラ選択画面 GridView crossAxisCount=2):
   0. sol      (ソウル)        — starter, 戦士
   1. aria     (アリア)        — starter, アサシン
   2. rune     (ルーン)        — 黒魔導士 (新キャラ、BUG-104)
   3. lucia    (ルシア)        — ヒーラー
   4. beatrix  (ベアトリス)   — ナイト
   5. faye     (フェイ)        — アーチャー
   6. cyan     (シアン)        — 青魔導士 (旧 rune、BUG-103 rename)
   7. zenon    (ゼノン)        — モンク
   8. noir     (ノワール)     — 闇魔導士
   9. luna     (ルナ)          — ガンナー
  10. kyle     (カイル)        — 魔法剣士
  11. fia      (フィア)        — 吟遊詩人
  12. aurum    (アウルム)     — 錬金術師
  13. irene    (イレーネ)     — ネクロマンサー

【CLAUDE.md「master/seed data 例外条項」適用】
  Character.order (master flag) の UPDATE のみで user-generated content を破壊しない。
  filter().update() で冪等性確保、再 apply 安全。

【全 FK 影響分析 (例外条項 §2)】
  - OwnedCharacter / PlayerProfile.active_character → 不変 (Character.id 不変)
  - Character.order は表示用 IntegerField、JOIN/lookup には使われない
"""
from django.db import migrations


_ORDER_MAP = {
    'sol':     0,
    'aria':    1,
    'rune':    2,
    'lucia':   3,
    'beatrix': 4,
    'faye':    5,
    'cyan':    6,
    'zenon':   7,
    'noir':    8,
    'luna':    9,
    'kyle':    10,
    'fia':     11,
    'aurum':   12,
    'irene':   13,
}


def _apply_order(apps, schema_editor):
    Character = apps.get_model('api', 'Character')
    updated = 0
    for key, order in _ORDER_MAP.items():
        count = Character.objects.filter(key=key).update(order=order)
        updated += count
    print(f'[migration 0142 BUG-111] Updated display order for {updated} characters')


def _noop_reverse(apps, schema_editor):
    """ロールバックは no-op (旧 order は migration 0015 / 0062 / 0128 / 0138 に
    分散しており、完全復元は無意味。reverse 実行時は手動で旧値に戻すか、
    本 migration 適用前の DB スナップショットを使う想定)。"""
    print('[migration 0142 BUG-111 reverse] No-op (旧 order は元 migration を参照)')


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0141_cyan_role_update'),
    ]

    operations = [
        migrations.RunPython(_apply_order, _noop_reverse),
    ]
