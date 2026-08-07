"""【FEAT-513 v1.1 hotfix 4 follow-up (2026-07-31)】Enemy.background_image_path を
'.png' → '.webp' に一括置換 (FEAT-510 Phase 1 catch-up)。

【背景】
FEAT-510 Phase 1 (2026-07-30、Flutter commit 204a12f) で mobile/assets を
WebP に一括変換した際、Backend の Enemy.background_image_path DB 値 (migration
0108/0109/0119 で '.png' path を seed 済) の更新は当時 scope 外だった。

結果、Flutter で Image.asset(enemy.backgroundImagePath) が 404 → errorBuilder
→ SizedBox.shrink → puzzle scene が透過表示するバグが発生 (user 報告 2026-07-31、
FEAT-513 hotfix 4 = commit f4b97f3)。

hotfix 4 は Flutter 側 API boundary で `.replaceAll('.png', '.webp')` を
BattleStartResponse.fromJson / EnemyMaster.fromJson の 2 箇所に注入する
「client fallback shim」として対応した (即時解決、Backend deploy 不要)。

【本 migration の目的】
Backend DB を実 asset (WebP) と整合させ、shim を不要にする恒久対応。
本 migration deploy 後、Flutter 側 shim (`.replaceAll('.png', '.webp')`) は
削除可能 (idempotent なので削除は次 Flutter release で実施予定)。

【master data 例外条項 (FEAT-391) 3 条件充足】
- ✅ master data のみ: Enemy master 24 体の string field のみ更新、user data 無影響
- ✅ FK 網羅: 対象 field は非 FK (CharField)、参照整合性影響なし
- ✅ 冪等性: `endswith('.png')` filter → 該当のみ '.webp' 化、再 run 時は 0 件 update

【design】
- 全 Enemy を走査、`.png` で終わる `background_image_path` を対応 `.webp` に置換
- 空文字 ('') / 既 `.webp` / 他拡張子 は無視 (defense-in-depth)
- rollback で逆変換 ('.webp' → '.png') = migration 前状態に完全復元可能

【deploy 順序】
1. Backend commit merge → develop deploy → dev DB で値変更確認
2. release merge → prod deploy → prod DB 更新
3. その後 Flutter 側 shim 削除 (次 release、hotfix 4 の逆操作)
"""
from django.db import migrations


def _normalize_png_to_webp(apps, schema_editor):
    """Enemy.background_image_path の '.png' 末尾を '.webp' に一括置換 (冪等)。"""
    Enemy = apps.get_model('api', 'Enemy')
    updated = 0
    for enemy in Enemy.objects.exclude(background_image_path=''):
        path = enemy.background_image_path
        if path.endswith('.png'):
            enemy.background_image_path = path[:-4] + '.webp'
            enemy.save(update_fields=['background_image_path'])
            updated += 1
    print(f'[migration 0197] FEAT-510 catch-up: '
          f'{updated} Enemy.background_image_path normalized (.png → .webp)')


def _rollback_webp_to_png(apps, schema_editor):
    """rollback: '.webp' → '.png' に戻す (migration 0108/0109/0119 seed の状態)。"""
    Enemy = apps.get_model('api', 'Enemy')
    updated = 0
    for enemy in Enemy.objects.exclude(background_image_path=''):
        path = enemy.background_image_path
        if path.endswith('.webp'):
            enemy.background_image_path = path[:-5] + '.png'
            enemy.save(update_fields=['background_image_path'])
            updated += 1
    print(f'[migration 0197 rollback] {updated} paths reverted (.webp → .png)')


class Migration(migrations.Migration):
    dependencies = [
        ('api', '0196_player_settings_preferred_language'),
    ]
    operations = [
        migrations.RunPython(_normalize_png_to_webp, _rollback_webp_to_png),
    ]
