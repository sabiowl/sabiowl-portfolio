"""【FEAT-478 Phase 2a (2026-07-04)】PlayerProfile 4 分割の CreateModel migration。

arch_review 20260702 §優先度トップ10 #10「PlayerProfile 30+ field 肥大 + 責務混在」
の段階的解消。本 migration は **schema only** = CreateModel × 4 のみで、破壊操作
(RunPython データ移行 / RemoveField) は一切含まない。

### 分割設計 (指示書 FEAT-478 §3.1)

    PlayerProfile (基本)
    ├── PlayerEconomyState (経済系: diamonds / coins / character_exchange_tickets 等)
    ├── PlayerBattleState  (バトル系: level / exp / battle_charges 等)
    ├── PlayerStreakState  (ストリーク系: streak / login / daily counters)
    └── PlayerSettings     (設定系: all_private / week_start_day 等)

### deploy 安全性

本 migration:
- 破壊操作なし → rollback 可能 (RemoveModel × 4 で復元)
- PlayerProfile field は無変更 → 既存コード無影響
- 新モデル行は Phase 2a 時点で存在せず、`PlayerProfile.economy` 等の proxy が
  `get_or_create` で初回アクセス時に自動作成 (PlayerProfile 現状値を defaults)。

### 後続 migration の計画 (指示書 §3.3、v1.0.x-late 実施)

- Migration 0170: (**廃止**) — data 移行は management command
  `python manage.py migrate_player_profile_v2 --confirm` に一本化。
  理由: CLAUDE.md「破壊的データマイグレーションの禁止」+ 指示書 §S6
  「Render Shell 利用可のため management command 経路推奨」。
  【2026-08-07】`migrate_player_profile_v2` は **削除済**。2026-07-06 に Phase 2c として本番で実行完了しており、
  State 行が無い環境 (test / fresh setup) では models/player.py の proxy が `get_or_create` で
  自動作成するため、本コマンドは不要になった。復元が要るなら:
      git log --diff-filter=D -- backend/api/management/commands/migrate_player_profile_v2.py
- Migration 0171-0174: 経済/バトル/残系/dead field の RemoveField (段階的、
  Phase 2b の 152 places rewrite 完了後、grep で `player.diamonds` 等ゼロ確認後)。
"""
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0168_tutorial_image'),
    ]

    operations = [
        migrations.CreateModel(
            name='PlayerEconomyState',
            fields=[
                ('player', models.OneToOneField(
                    to='api.playerprofile',
                    on_delete=models.deletion.CASCADE,
                    primary_key=True,
                    serialize=False,
                    related_name='economy_state',
                    verbose_name='プレイヤー',
                )),
                ('diamonds',       models.IntegerField(default=0, verbose_name='ダイヤモンド残高')),
                ('diamonds_total', models.IntegerField(default=0, verbose_name='累計獲得ダイヤ')),
                ('bonus_coins',    models.IntegerField(default=0, verbose_name='クエスト報酬コイン')),
                ('coins_spent',    models.IntegerField(default=0, verbose_name='使用コイン合計')),
                ('diamond_bonus_date', models.DateField(
                    null=True, blank=True, verbose_name='最終ダイヤボーナス日',
                )),
                ('character_exchange_tickets', models.PositiveIntegerField(
                    default=0, verbose_name='キャラ交換券',
                )),
                ('streak_protection_count', models.IntegerField(
                    default=0, verbose_name='ストリーク保護 在庫',
                )),
                ('streak_protection_auto_enabled', models.BooleanField(
                    default=False, verbose_name='自動保護 ON/OFF',
                )),
                ('streak_protection_pending', models.BooleanField(
                    default=False, verbose_name='ストリーク保護 予約中',
                )),
                ('last_streak_protection_used_at', models.DateField(
                    null=True, blank=True, verbose_name='直近保護発動日',
                )),
                ('xp_boost_active_until', models.DateTimeField(
                    null=True, blank=True, verbose_name='XPブースト有効期限',
                )),
            ],
            options={
                'verbose_name':        'プレイヤー経済状態',
                'verbose_name_plural': 'プレイヤー経済状態',
            },
        ),
        migrations.CreateModel(
            name='PlayerBattleState',
            fields=[
                ('player', models.OneToOneField(
                    to='api.playerprofile',
                    on_delete=models.deletion.CASCADE,
                    primary_key=True,
                    serialize=False,
                    related_name='battle_state',
                    verbose_name='プレイヤー',
                )),
                ('level',              models.IntegerField(default=1,   verbose_name='レベル')),
                ('current_exp',        models.IntegerField(default=0,   verbose_name='現在EXP')),
                ('max_exp',            models.IntegerField(default=100, verbose_name='最大EXP')),
                ('allocatable_points', models.IntegerField(default=0,   verbose_name='割り振りポイント')),
                ('battle_charges', models.IntegerField(
                    default=0,
                    help_text='FEAT-295/406/410: 出陣チケット、3 で 1 戦、上限 30 = 10 戦分、日次リセット',
                )),
                ('battle_charges_date', models.DateField(
                    null=True, blank=True, verbose_name='バトルチャージ最終リセット日',
                )),
                ('daily_exp_count',      models.IntegerField(default=0, verbose_name='本日 EXP 獲得回数')),
                ('daily_exp_count_date', models.DateField(
                    null=True, blank=True, verbose_name='本日 EXP カウントの起点日',
                )),
                ('daily_battle_count',      models.IntegerField(default=0, verbose_name='本日のバトル出陣回数')),
                ('daily_battle_count_date', models.DateField(
                    null=True, blank=True, verbose_name='本日バトルカウントの起点日',
                )),
                ('daily_battle_limit_bonus', models.PositiveIntegerField(
                    default=0, verbose_name='クエスト受注枠 ボーナス',
                )),
                ('daily_battle_limit_purchase_count', models.PositiveIntegerField(
                    default=0, verbose_name='クエスト枠拡張 累計購入回数',
                )),
            ],
            options={
                'verbose_name':        'プレイヤーバトル状態',
                'verbose_name_plural': 'プレイヤーバトル状態',
            },
        ),
        migrations.CreateModel(
            name='PlayerStreakState',
            fields=[
                ('player', models.OneToOneField(
                    to='api.playerprofile',
                    on_delete=models.deletion.CASCADE,
                    primary_key=True,
                    serialize=False,
                    related_name='streak_state',
                    verbose_name='プレイヤー',
                )),
                ('last_battle_diamond_at', models.DateField(
                    null=True, blank=True, verbose_name='最終バトル勝利ダイヤ付与日',
                )),
                ('last_streak_diamond_day', models.IntegerField(
                    default=0, verbose_name='最終ストリークダイヤ付与 streak 日',
                )),
                ('last_login_diamond_at', models.DateField(
                    null=True, blank=True, verbose_name='最終ログインダイヤ付与日',
                )),
                ('login_streak_days', models.IntegerField(default=0, verbose_name='連続ログイン日数')),
                ('daily_task_count',  models.IntegerField(default=0, verbose_name='当日タスク完了数')),
                ('daily_task_count_date', models.DateField(
                    null=True, blank=True, verbose_name='当日タスク完了数 基準日',
                )),
                ('last_friend_gift_popup_date', models.DateField(
                    null=True, blank=True, verbose_name='フレンドプレゼント popup 最終表示日',
                )),
                ('last_achievement_check_at', models.DateTimeField(
                    null=True, blank=True, verbose_name='最終実績チェック日時',
                )),
            ],
            options={
                'verbose_name':        'プレイヤーストリーク状態',
                'verbose_name_plural': 'プレイヤーストリーク状態',
            },
        ),
        migrations.CreateModel(
            name='PlayerSettings',
            fields=[
                ('player', models.OneToOneField(
                    to='api.playerprofile',
                    on_delete=models.deletion.CASCADE,
                    primary_key=True,
                    serialize=False,
                    related_name='settings_state',
                    verbose_name='プレイヤー',
                )),
                ('all_private', models.BooleanField(default=False, verbose_name='全習慣非公開')),
                ('week_start_day', models.IntegerField(
                    default=0, verbose_name='週起点曜日',
                    help_text='0=月, 1=火, 2=水, 3=木, 4=金, 5=土, 6=日',
                )),
                ('month_reset_day', models.IntegerField(
                    default=1, verbose_name='月次リセット日', help_text='1〜28',
                )),
                ('fcm_token',        models.TextField(blank=True, default='', verbose_name='FCMトークン')),
                ('reminder_enabled', models.BooleanField(default=False, verbose_name='リマインダー有効')),
                ('reminder_time',    models.TimeField(null=True, blank=True, verbose_name='通知時刻')),
                ('mode', models.CharField(
                    max_length=10, default='training', verbose_name='プレイモード',
                    help_text='training=鍛錬, adventure=冒険',
                )),
                ('gcal_push_enabled', models.BooleanField(
                    default=False,
                    help_text='FEAT-257/263: Sabiowl の予定を Google カレンダーに書き出す',
                )),
                ('timeline_uncompleted_reminder_enabled', models.BooleanField(
                    default=False,
                    help_text='FEAT-273: タイムライン予定の +15 分後未完了通知',
                )),
            ],
            options={
                'verbose_name':        'プレイヤー設定',
                'verbose_name_plural': 'プレイヤー設定',
            },
        ),
    ]
