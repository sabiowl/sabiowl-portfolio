"""【FEAT-331 (2026-05-27)】連続ログイン報酬: PlayerProfile に streak 管理 2 フィールド追加。

ユーザー報告 (知人テスト): 「ダイヤがもっと欲しい、課金ページが欲しい」を受けて
v1.0 では **無料経路拡張** で応答 (案 Y、PM 推奨)。課金 (ダイヤ購入) は v1.1 計画
(`doc/design/monetization_v1_1.md` 案 B コインダイヤパック) で対応。

### 設計概要

- 連続ログイン 7 日達成で +10 ダイヤを付与
- アプリ起動時の PlayerProfile fetch (GET /api/player/) で発火 (ユーザー摩擦ゼロ)
- 既存 FEAT-314 の `award_diamond_for_battle_win` / `_streak_7days` / `_title_acquired`
  と同パターン (`diamond_service.py` 統一)

### 追加フィールド

| フィールド | 型 | 用途 |
|---|---|---|
| `last_login_diamond_at` | DateField (null=True) | 最終ログイン日 (連続判定基準) |
| `login_streak_days` | IntegerField (default=0) | 現在の連続ログイン日数 (0-7、7 達成で +10💎 + リセット) |

### 冪等性

- `last_login_diamond_at == today` なら当日処理済 → no-op
- `select_for_update()` で並列リクエスト保護
- 連続切れ判定: `(today - last_login_diamond_at).days > 1` で streak=1 リセット
"""
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0097_remove_duplicate_monk_m_character'),
    ]

    operations = [
        migrations.AddField(
            model_name='playerprofile',
            name='last_login_diamond_at',
            field=models.DateField(
                null=True, blank=True,
                help_text='FEAT-331: 連続ログイン報酬の最終ログイン日 '
                          '(連続判定基準)。null=未ログイン or リセット直後',
            ),
        ),
        migrations.AddField(
            model_name='playerprofile',
            name='login_streak_days',
            field=models.IntegerField(
                default=0,
                help_text='FEAT-331: 現在の連続ログイン日数 (0-7)。'
                          '7 達成で +10 ダイヤ付与 + リセット',
            ),
        ),
    ]
