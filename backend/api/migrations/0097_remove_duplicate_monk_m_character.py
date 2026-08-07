"""【FEAT-330 (2026-05-27)】Character 重複レコード `monk_m` を削除。

ユーザー報告:
> 「ホーム画面 > ステータス画面 > キャラ変更で『ゼノン』が二人いる。
>   『ゼノン 雷術士』のみ残し、コイン購入で解禁できるようにする」

### 真因 (migration 履歴調査結果)

| Character.key | name | role | image_path | 経緯 |
|---|---|---|---|---|
| `monk_m` | ゼノン | **モンク** | zenon | migration 0015 で初期 INSERT、migration 0062 で **リネーム漏れ** |
| `zenon`  | ゼノン | **雷術士** | zenon | migration 0062 で `get_or_create` で **新規 INSERT** |

migration 0062 (`_character_key_to_flutter_alignment`) の `_KEY_REMAP` table に
**`monk_m → zenon` のリネーム行が抜け落ちていた** ため、`monk_m` レコードがそのまま
残り、zenon が新規 INSERT で追加 = **2 レコード共存状態**。

過去 codebase_review でも未指摘の dead data 問題、ユーザー画面操作 (キャラ変更画面で
「ゼノン」が 2 つ表示) で発覚。

### 修正方針

1. `PlayerProfile.active_character` が monk_m を指していたら zenon に切替 (SET_NULL
   ではなく明示的に zenon に再代入、UX 継続性確保)
2. `OwnedCharacter` で monk_m を所持していたら:
   - 同 player が zenon も既所持 → monk_m owned レコード削除 (zenon を残す)
   - monk_m のみ所持 → character を zenon に切替 (UniqueConstraint 違反回避済)
3. `Character.objects.get(key='monk_m').delete()` 実行

### 結果として残るのは zenon (雷術士) のみ

- `is_starter=True` 維持 → キャラ変更画面で `locked=false` → 「購入して選択する」
  ボタン表示 (character_page.dart:325)
- `price=1500` 維持 → コイン購入で解禁可能 (既存購入フロー活用、コード変更不要)
- ユーザー要件「『ゼノン 雷術士』のみ残し、コイン購入で解禁できるようにする」
  完全達成

### reverse 関数の方針

monk_m は migration 0015 の初期データに依存する dead レコード。reverse 関数では
復元しない (no-op + WARN ログ)。万一 rollback が必要なら migration 0015 を再実行
すること。
"""
from django.db import migrations


def _delete_monk_m_duplicate(apps, schema_editor):
    """`monk_m` Character (ゼノン モンク) 重複レコードを削除し、zenon に統合。

    手順:
    1. PlayerProfile.active_character の指す先を monk_m → zenon に切替
    2. OwnedCharacter の monk_m 所持を zenon に統合 (UniqueConstraint 配慮)
    3. Character.key='monk_m' レコード削除
    """
    Character = apps.get_model('api', 'Character')
    PlayerProfile = apps.get_model('api', 'PlayerProfile')
    OwnedCharacter = apps.get_model('api', 'OwnedCharacter')

    try:
        monk = Character.objects.get(key='monk_m')
    except Character.DoesNotExist:
        print('[migration 0097] monk_m Character not found, skip (テスト DB 等)')
        return

    try:
        zenon = Character.objects.get(key='zenon')
    except Character.DoesNotExist:
        # zenon が存在しないのに monk_m が存在する状況は想定外。安全のため abort。
        print('[migration 0097] WARNING: zenon Character not found but monk_m exists. '
              'Skipping deletion to avoid data loss.')
        return

    # ── 1. PlayerProfile.active_character の付け替え ────────────────────────
    affected_active = PlayerProfile.objects.filter(active_character=monk).update(
        active_character=zenon,
    )
    if affected_active > 0:
        print(f'[migration 0097] {affected_active} players active_character: '
              f'monk_m → zenon')

    # ── 2. OwnedCharacter の統合 ────────────────────────────────────────────
    # UniqueConstraint (player, character) 違反を避けるため、両方所持なら monk_m
    # owned を削除し、monk_m のみなら character を zenon に切替。
    monk_owned_records = OwnedCharacter.objects.filter(character=monk)
    deleted_count = 0
    migrated_count = 0
    for owned in monk_owned_records:
        if OwnedCharacter.objects.filter(player=owned.player, character=zenon).exists():
            # 両方所持: monk_m owned を削除 (zenon を残す、UX として「ゼノンを所持」継続)
            owned.delete()
            deleted_count += 1
        else:
            # monk_m のみ所持: character を zenon に切替 (UniqueConstraint 安全)
            owned.character = zenon
            owned.save(update_fields=['character'])
            migrated_count += 1

    if deleted_count > 0:
        print(f'[migration 0097] {deleted_count} OwnedCharacter records deleted '
              f'(both monk_m and zenon owned, monk_m removed)')
    if migrated_count > 0:
        print(f'[migration 0097] {migrated_count} OwnedCharacter records migrated '
              f'(monk_m → zenon)')

    # ── 3. monk_m Character レコード削除 ────────────────────────────────────
    monk.delete()
    print('[migration 0097] monk_m Character record deleted '
          '(FEAT-330 ゼノン重複問題 解消、migration 0062 のリネーム漏れバグ修正)')


def _restore_monk_m_noop(apps, schema_editor):
    """rollback: monk_m 復元は no-op (warning のみ出力)。

    monk_m は migration 0015 の初期データに依存する dead レコードで、再 INSERT する
    意義がない (migration 0044/0062 の歪んだ状態に戻すだけ)。万一 rollback が必要
    なら migration 0015 を再実行すること。
    """
    print('[migration 0097 reverse] WARNING: monk_m restoration is no-op. '
          'Re-run migration 0015 if monk_m record is actually needed (dead data).')


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0096_boss_enemies_unlock_level'),
    ]

    operations = [
        migrations.RunPython(_delete_monk_m_duplicate, _restore_monk_m_noop),
    ]
