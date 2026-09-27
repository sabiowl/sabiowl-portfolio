from django import forms
from django.contrib import admin, messages
from django.contrib.auth import get_user_model
from django.contrib.auth.admin import UserAdmin as DjangoUserAdmin
from django.contrib.auth.forms import UserChangeForm as DjangoUserChangeForm
from django.db.models import Sum  # 【2026-06-29 hotfix】Subquery annotate 撤回で OuterRef/Subquery/IntegerField は不要に
from django.http import HttpResponseRedirect
from django.shortcuts import get_object_or_404, render
from django.urls import path, reverse
from django.utils import timezone
from django.utils.html import format_html, format_html_join
# 【2026-08-07】権限 override (`return False` × 29 箇所) を mixin に集約。
# mixin は必ず admin.ModelAdmin より左に置くこと (右だと無言で効かない)。
# 権限マトリクスは tests/test_admin_permission_mixins.py が lock。
from .admin_mixins import (
    NoAddAdminMixin, NoChangeAdminMixin, NoDeleteAdminMixin,
    NoBulkDeleteAdminMixin, ReadOnlyAdminMixin,
)
# 【2026-08-07】CharacterStat.max_exp の逆算は game 側の計算式なので
# services/exp_service.py (apply_stat_level_up_step の隣) に移設した。
from .services.exp_service import stat_max_exp_at_level
# 【FEAT-535 (2026-08-29)】プレイヤー戦闘能力の Dart ミラー。
# 🔴 真実値は Dart 側。詳細は battle_stats_preview.py の module docstring。
from .services.battle_stats_preview import (
    baseline_atk_for_enemy_table,
    compute_player_battle_stats,
)
# 【FEAT-538 (2026-08-29)】プレイヤー Lv -> max_exp の単一真実値。
# 直書き (level * 100 等) 禁止、CharacterStat 側の stat_max_exp_at_level と対。
from .constants import GameBalance

User = get_user_model()
# 【FEAT-538 (2026-08-29)】「1 人 1 装備」の手続き。view と admin で共有する
# (複製すると書き込み経路が増えるたびに同じ穴が空く。BUG-79 / FEAT-528 の型)。
from .services.weapon_equip import equip_exclusively
from .models import (
    AccountSuspensionLog,  # 【FEAT-541 (2026-09-06)】停止履歴
    PlayerProfile, CharacterStat, Habit, HabitLog,
    Announcement, PlayerAnnouncementRead,  # 【FEAT-458】お知らせ機能
    MaintenanceConfig,  # 【FEAT-463】緊急メンテナンスモード
    AppUpdateConfig,  # 【FEAT-543】バージョンアップ告知
    Challenge, ChallengeParticipation,  # 【FEAT-465】月次カテゴリチャレンジ
    SabiMessage,  # 【新規 (2026-06-26)】サビセリフ admin 編集対応
    Character,    # 【2026-06-27】新キャラ追加機能 (tagline / release_date 編集用)
    GachaReward, PlayerGachaStatus, GachaHistory,  # 【2026-06-29】ガチャ報酬 admin 編集対応
    TaskSuggestion,  # 【FEAT-467 (2026-07-02)】タスク候補 Backend 化
    WeaponMaster, PlayerWeapon,  # 【2026-07-09】武器 / プレイヤー武器 admin 編集対応
    PlayerItem,  # 【2026-07-09】プレイヤー所持アイテム admin 編集対応
    PlayerEconomyState,  # 【2026-07-09】プレイヤー経済状態 (coin / diamond) admin 編集対応
    PlayerBattleState, PlayerStreakState, PlayerSettings,  # 【2026-07-09 Phase A】state 3 種 (Level/EXP、streak、設定) の admin 編集対応
    IAPReceipt,  # 【2026-07-09 Phase A】RevenueCat 課金領収書 (view-only、監査 / 返金対応)
    AccountDeletionFeedback,  # 【2026-07-09 Phase A】退会理由フィードバック (view-only、プロダクト改善指標)
    Enemy,  # 【2026-07-09 Phase B】敵マスタ (balance 調整)
    Friendship, Message, Notification,  # 【2026-07-09 Phase B】社交機能 (通報対応 / 「通知届いてない」対応)
    OwnedCharacter,  # 【2026-07-09 Phase B】所持キャラ (補償対応)
    PendingDuplicateReward,  # 【2026-07-09 Phase B】重複報酬待ち (30 日期限監視)
    PlayerStatsMatrix,  # 【2026-07-09】プレイヤーステータス pivot ビュー用 proxy model
)


# 【2026-07-09 拡張】PlayerProfile 詳細画面から経済状態 (ダイヤ / コイン) を
# inline 編集可能にする。標準の `list_editable` (list 一覧) / 単体 admin
# (PlayerEconomyStateAdmin の詳細画面) に加え、「A さんのプロファイルを
# 見ながら残高を触る」最も自然な動線 (support 補償対応で頻度が高い) を提供。
#
# can_delete=False: OneToOne(primary_key=True) の削除禁止 (property の
# get_or_create で空 state が新規生成 → diamonds_total / coins_spent の
# 累計履歴が消失するリスク回避、単体 admin と同じ方針)。
class PlayerEconomyStateInline(admin.StackedInline):
    model = PlayerEconomyState
    can_delete = False
    max_num = 1
    verbose_name        = 'プレイヤー経済状態'
    verbose_name_plural = 'プレイヤー経済状態'
    fieldsets = (
        ('残高 (現在値、補償対応で直接編集可)', {
            'fields': ('diamonds', 'bonus_coins', 'character_exchange_tickets'),
            'description': (
                '<strong>diamonds</strong> = 現在ダイヤ残高、'
                '<strong>bonus_coins</strong> = 現在コイン残高。<br>'
                '補償対応でここを直接編集して save すると即時反映される。'
            ),
        }),
        ('累計 / 統計 (通常は触らない)', {
            'fields': ('diamonds_total', 'coins_spent', 'diamond_bonus_date'),
            'description': (
                'diamonds_total = 総取得ダイヤ累計 (leaderboard / milestone 集計用)。<br>'
                'coins_spent = Shop 消費コイン累計 (集計用)。<br>'
                '<em>補償で diamonds を増やした場合、統計整合のため diamonds_total も同額増やすかは運用判断。</em>'
            ),
            'classes': ('collapse',),
        }),
        ('ストリーク保護', {
            'fields': (
                'streak_protection_count',
                'streak_protection_auto_enabled',
                'streak_protection_pending',
                'last_streak_protection_used_at',
            ),
            'classes': ('collapse',),
        }),
        ('XP boost', {
            'fields': ('xp_boost_active_until',),
            'description': 'XP boost item の有効期限。null = 未使用。',
            'classes': ('collapse',),
        }),
    )


# 【2026-07-09 Phase A】PlayerBattleState (Level / EXP / battle_charges 等) を
# PlayerProfile 詳細画面から inline 編集可能に。support 補償対応で頻繁に触るため、
# PlayerEconomyStateInline と同じ StackedInline パターンを踏襲。
class PlayerBattleStateInline(admin.StackedInline):
    model = PlayerBattleState
    can_delete = False
    max_num = 1
    verbose_name        = 'プレイヤーバトル状態'
    verbose_name_plural = 'プレイヤーバトル状態'
    # 【FEAT-538 (2026-08-29)】max_exp は level から自動再計算されるので触れなくする。
    # 再計算は PlayerProfileAdmin.save_formset (inline 経由はそこを通る)。
    # 🔴 readonly だけ / 自動計算だけ ではダメで、両方要る ——
    #    readonly が無いと「画面で編集できるのに保存すると黙って上書きされる」
    #    最悪の UX になり、自動計算が無いと編集欄が無いまま drift が残る。
    readonly_fields = ('max_exp',)
    fieldsets = (
        ('レベル / EXP (support 補償で直接編集可)', {
            'fields': ('level', 'current_exp', 'max_exp', 'allocatable_points'),
            'description': (
                'レベルダウン救済 / EXP 補償 / ステ振り追加ポイント配布。<br>'
                '<em>max_exp は readonly。level を save すると '
                '<code>level_to_max_exp(level)</code> から自動で追従する '
                '(FEAT-538)。</em><br>'
                '<em>current_exp は自動調整しない。Lv を下げると '
                'current_exp &gt; max_exp になりうるが、補償で意図的に入れた EXP を'
                '黙って削らないための仕様。</em>'
            ),
        }),
        ('バトルチャージ / 日次スロットル', {
            'fields': (
                'battle_charges', 'battle_charges_date',
                'daily_battle_count', 'daily_battle_count_date',
                'daily_exp_count', 'daily_exp_count_date',
            ),
            'description': (
                'battle_charges = 出陣チケット (3 で 1 戦、上限 30)。<br>'
                'daily_battle_count = 本日出陣数 (上限 10 で当日打止)。<br>'
                '_date fields = 日次リセットの基準日 (null / 過去日で自動リセット発火)。'
            ),
            'classes': ('collapse',),
        }),
        ('クエスト枠拡張 (FEAT-429 累進価格)', {
            'fields': ('daily_battle_limit_bonus', 'daily_battle_limit_purchase_count'),
            'classes': ('collapse',),
        }),
    )


# 【2026-07-09 Phase A】PlayerStreakState (login streak / daily counters) を inline 化。
# 「通信障害で streak 途切れた」救済で頻繁に触る領域。
class PlayerStreakStateInline(admin.StackedInline):
    model = PlayerStreakState
    can_delete = False
    max_num = 1
    verbose_name        = 'プレイヤーストリーク状態'
    verbose_name_plural = 'プレイヤーストリーク状態'
    fieldsets = (
        ('最終アクティブ (FEAT-540)', {
            'fields': ('last_achievement_check_at',),
            'description': (
                'support が最初に見る値。**「まだ使っているか」**を測っている。<br>'
                '🔴 <strong>「ログイン」ではない。</strong> DRF の Token 認証は '
                '<code>User.last_login</code> を更新しないので、'
                'Django 既定の User 画面に出ている「最終ログイン」は'
                '<strong>全員 なし</strong>である (FEAT-540 §1)。<br>'
                '更新経路は 3 つ: 習慣 / ToDo のカウント、チェックリストのチェック、'
                '実績画面を開いたとき (60 秒スロットル)。<br>'
                '⚠️ <strong>タイムライン予定の完了だけでは動かない。</strong>'
                'タイムラインしか使っていないユーザーは休眠に見えるので、'
                '判断する前に <code>DailyAchievement</code> (日次達成記録) も見ること。'
            ),
        }),
        ('連続達成 (FEAT-539)', {
            'fields': (
                'login_streak_days', 'best_task_streak_days', 'last_login_diamond_at',
            ),
            'description': (
                '🔴 <strong>login_streak_days / best_task_streak_days は キャッシュ であり、'
                '真実値ではありません</strong>。真実値は <code>DailyAchievement</code> の行です '
                '(FEAT-539)。<br>'
                'ここを手で書き換えると <code>manage.py check_daily_achievement_consistency</code> '
                'が不一致として報告し、<code>--fix</code> で<strong>行の値に戻されます</strong>。<br>'
                '救済で連続日数を伸ばしたい場合は、キャッシュではなく '
                '<code>DailyAchievement</code> の行を足してください。<br>'
                '⚠️ <strong>last_login_diamond_at は「ログイン」で動きません。</strong>'
                '<strong>その日の初回タスク達成</strong>で更新される冪等性キーです '
                '(BUG-122 が発火条件を変えた際、名前だけ据え置かれた)。<br>'
                '今日の日付をここに書くと、本日は追加付与されません。<br>'
                '🔵 改名しないのは <code>diamond_service.py</code> が'
                '冪等性キーとして依存しているためです。<strong>名前ではなく説明で解いています。</strong>'
            ),
        }),
        ('ダイヤ付与冪等性 (誤操作抑止)', {
            'fields': ('last_battle_diamond_at', 'last_streak_diamond_day'),
            'classes': ('collapse',),
        }),
        ('日次カウンタ / popup 判定', {
            'fields': (
                'daily_task_count', 'daily_task_count_date',
                'last_friend_gift_popup_date',
            ),
            'classes': ('collapse',),
        }),
        ('パズル世界 (FEAT-479)', {
            'fields': ('last_task_piece_date', 'last_quest_piece_date'),
            'classes': ('collapse',),
        }),
    )


# 【2026-07-09 Phase A】PlayerSettings (通知 / privacy / mode / gcal) を inline 化。
# support で「通知届いてない」「モード切替できない」等の問い合わせに即対応可能。
# fcm_token は device-specific なので readonly 表示のみ (admin 編集で書き換えると
# push 通知が届かなくなる → 意図しない障害の温床)。
class PlayerSettingsInline(admin.StackedInline):
    model = PlayerSettings
    can_delete = False
    max_num = 1
    verbose_name        = 'プレイヤー設定'
    verbose_name_plural = 'プレイヤー設定'
    readonly_fields     = ('fcm_token',)
    fieldsets = (
        ('プライバシー / モード', {
            'fields': ('all_private', 'mode'),
            'description': (
                'all_private = True で全習慣を非公開 (フレンドから見えない)。<br>'
                'mode = training (鍛錬) / adventure (冒険) の切替。'
            ),
        }),
        ('通知 (support で頻出)', {
            'fields': ('reminder_enabled', 'reminder_time', 'fcm_token'),
            'description': (
                'reminder_enabled + reminder_time = local reminder 通知。<br>'
                '<strong>fcm_token</strong> は Mobile 側で自動更新される値。admin から編集禁止 '
                '(書き換えると push が届かなくなる)、確認用のみ。'
            ),
        }),
        ('リセットタイミング', {
            'fields': ('week_start_day', 'month_reset_day'),
            'classes': ('collapse',),
        }),
        ('Google カレンダー連動 (FEAT-257/263/273)', {
            'fields': (
                'gcal_push_enabled',
                'timeline_uncompleted_reminder_enabled',
            ),
            'classes': ('collapse',),
        }),
    )


# 【2026-07-09 Phase C】PlayerGachaStatus (チケット枚数 / 天井 / redo 状態) を
# PlayerProfile 詳細画面で inline 編集可能に。support 補償「A さんに Weekly
# ticket +1 配布」等の頻度が高い操作を 3-4 クリック → 1 セル編集に短縮。
# 天井 (pity) / redo 状態も同一画面で把握できるため、ガチャ関連 support の
# 視線移動を PlayerEconomyStateInline と同レベルまで低減。
class PlayerGachaStatusInline(admin.StackedInline):
    model = PlayerGachaStatus
    can_delete = False
    max_num = 1
    verbose_name        = 'プレイヤーガチャ状態'
    verbose_name_plural = 'プレイヤーガチャ状態'
    fieldsets = (
        ('チケット枚数 (補償対応で直接編集可)', {
            'fields': (
                'daily_tickets', 'weekly_tickets', 'monthly_tickets',
            ),
            'description': (
                'daily = デイリーガチャ、weekly = ウィークリー、'
                'monthly = マンスリー (SSR 確定) チケット。<br>'
                '補償対応で本セクションを直接編集して save すると即時反映される。'
            ),
        }),
        ('天井カウンター (誤操作抑止)', {
            'fields': ('daily_pity', 'weekly_pity', 'monthly_pity'),
            'description': (
                'BUG-93 で天井は全廃止済のため、通常触ることはない '
                '(後方互換維持のため field は残置)。'
            ),
            'classes': ('collapse',),
        }),
        ('付与日履歴 (Backend 自動更新、通常触らない)', {
            'fields': (
                'daily_last_granted',
                'weekly_last_granted_week',
                'monthly_last_granted_month',
            ),
            'classes': ('collapse',),
        }),
        ('redo 機能 (FEAT-374、直近ガチャの引き直し)', {
            'fields': (
                'last_pull_id', 'last_pull_at', 'last_pull_pool', 'redo_used',
            ),
            'description': (
                'FEAT-374: 直近ガチャ 24h 以内なら 💎 50 で 1 度だけ引き直し可能。<br>'
                '<strong>redo_used=True</strong> = 既に引き直し済み。手動で False に'
                '戻すと再度の redo が可能になる (救済経路)。'
            ),
            'classes': ('collapse',),
        }),
    )


# ──────────────────────────────────────────────────────────────────────────────
# 【BUG-152 / BUG-153 (2026-09-06)】プレイヤーごとの削除で巻き添えを許す model
# ──────────────────────────────────────────────────────────────────────────────
#
# 🔴 【BUG-153】BUG-152 は「`NoDeleteAdminMixin` を付けた 5 つ」と数えたが、
#    **`ReadOnlyAdminMixin` 経由でも `has_delete_permission` は `False` になる**。
#    片方の mixin だけを grep したせいで 3 model 漏れていた。
#
#    しかも Django の `get_deleted_objects` は `perms_needed` に
#    **実際に行が存在する model だけ**を入れるので、症状は「1 個直すと次が出る」
#    という形で小出しに現れる —— チャレンジ未参加なら 5 件、参加者なら 6 件目、
#    課金ユーザーなら 7 件目。**手で数え直すやり方では終わらない。**
#
#    `test_every_blocking_cascade_model_is_classified` が
#    `PlayerProfile` から CASCADE を BFS で辿って**発見**し、この列挙を検算する。
#
# ⚠️ 名前から `STATE` を外した。`IAPReceipt` / `ChallengeParticipation` は
#    「state 行」ではない。名前が実態とズレると、次に足す人が
#    「これは state じゃないから対象外だ」と判断して**また漏れる**。
#
# 🔴 **ここは明示列挙のまま維持する。** 走査で自動導出しない ——
#    将来 `NoDeleteAdminMixin` を別の目的 (監査ログ等) で使ったとき、
#    消してはいけないものまで消えるため (BUG-152 の判断)。
#    **発見はテストの仕事、決定は人間の仕事。**
CASCADE_DELETABLE_MODELS = (
    # ── FEAT-478 の state 分割 5 兄弟 (BUG-152) ──────────────────────────
    PlayerEconomyState,
    PlayerBattleState,
    PlayerStreakState,
    PlayerSettings,
    PlayerGachaStatus,
    # ── 読み取り専用 admin だが、プレイヤーに従属するもの (BUG-153) ──────
    ChallengeParticipation,   # 月次チャレンジの per-user 進捗
    IAPReceipt,               # 課金領収書 (下の注記を読むこと)
    PendingDuplicateReward,   # 重複報酬待ち。player が消えたら意味を持たない
)

# ⚠️ `IAPReceipt` を通してよいのか —— 本 BUG 唯一の判断ポイント。
#
#   - `IAPReceipt.player` の FK は **`CASCADE`** である。
#     つまり **DB 設計としてすでに「プレイヤーが消えたら消える」**。
#   - アプリの正規経路 (設定 → アカウント削除) は `request.user.delete()` /
#     `player.delete()` を呼ぶので、**実ユーザーの退会でも今この瞬間に
#     領収書は消えている** (`views/player.py`)。
#
#   → 本 BUG は**新しい破壊を許可していない**。admin の確認画面が、
#     既に起きていることを表示していただけである。
#
# ⚠️ 「返金対応で領収書を残したい」なら、それは `on_delete` の設計論
#    (`SET_NULL` にして player を切り離す等) であって本 BUG ではない。
#    **migration を伴う設計変更を、削除ボタンを直すついでにやらない。**

# 「プレイヤー削除を意図的に止める」model を置く場所。
#
# 🔵 空の箱をわざわざ置いているのは、上の網羅性テストが fail したときに
#    逃げ道が「除外リストに足す」しか無いと、**考えずに足す**圧力がかかるため。
#    2 つの箱を用意して**どちらかに入れることを強制する**と、
#    「止めたいのか / 通したいのか」を必ず 1 回考えることになる。
#
# ⚠️ ここに足すときは、**なぜ止めるのかを 1 行で書くこと。**
#    理由の書かれていない行は、次の人には「fail を黙らせた跡」にしか見えない。
#
# ⚠️ 空のまま維持できているうちは、admin から人を消せる状態が保たれている。
CASCADE_BLOCKING_INTENTIONAL: tuple = ()


@admin.register(PlayerProfile)
class PlayerProfileAdmin(NoBulkDeleteAdminMixin, admin.ModelAdmin):
    # 🔴 【BUG-152 (2026-09-06)】`NoBulkDeleteAdminMixin` を**同時に**足している。
    #
    # 本 BUG の修正 (`get_deleted_objects` で `perms_needed` を削る) は、
    # 個別削除だけでなく**一覧の一括削除も同時に解禁する**。
    # 修正前は 5 state の `has_delete_permission=False` が
    # 「消せない」という形で一括削除も塞いでいた ——
    # つまり**この BUG が偶然の防護柵になっていた**。
    #
    # 本 BUG の目的は「テストユーザーを 1 人ずつ掃除できるようにする」ことで、
    # 「checkbox の全選択ミスでプレイヤーが一斉に消せるようにする」ことではない。
    # しかも一括削除の確認画面は `delete_view` を通らないので、
    # 下の警告メッセージも出ない。個別削除だけを開ける。
    # 【FEAT-478 Phase 2 最終 (2026-07-06)】level / current_exp は
    # PlayerBattleState に移動済のため、callable 経由で表示。
    # 【2026-07-09】diamonds / bonus_coins は PlayerEconomyState に移動済のため、
    # list 表示は callable 経由 (list 概観、header クリックで並び替え可)、
    # 詳細画面での編集は PlayerEconomyStateInline (StackedInline) で提供。
    list_display = ('name', 'get_level', 'get_current_exp',
                    'get_diamonds', 'get_coins',
                    'gender', 'created_at', 'get_last_active')
    # 【2026-07-09】PlayerWeapon / PlayerItem admin から autocomplete_fields で
    # 参照可能にするため search_fields を追加。name (プレイヤー名) / friend_id
    # (12 桁 ID) / user__email (連携済ユーザーの email) をキーに検索できる。
    search_fields = ('name', 'friend_id', 'user__email')
    # 【2026-07-09 Phase A → Phase C】詳細画面に 5 state を inline 表示・編集。
    # 順序: 経済 (最頻)、バトル (次点)、streak (救済)、gacha (補償)、settings (問合せ)
    # にすることで、support 対応の視線移動を最小化。
    inlines = [
        PlayerEconomyStateInline,
        PlayerBattleStateInline,
        PlayerStreakStateInline,
        PlayerGachaStatusInline,  # 【Phase C】追加
        PlayerSettingsInline,
    ]

    @admin.display(description='レベル', ordering='battle_state__level')
    def get_level(self, obj):
        return obj.battle.level

    @admin.display(description='現在EXP', ordering='battle_state__current_exp')
    def get_current_exp(self, obj):
        return obj.battle.current_exp

    @admin.display(description='💎ダイヤ', ordering='economy_state__diamonds')
    def get_diamonds(self, obj):
        return obj.economy.diamonds

    @admin.display(description='🪙コイン', ordering='economy_state__bonus_coins')
    def get_coins(self, obj):
        return obj.economy.bonus_coins

    # ── 【FEAT-540 (2026-09-06)】最終アクティブ ────────────────────────────
    @admin.display(
        description='最終アクティブ',
        ordering='streak_state__last_achievement_check_at',
    )
    def get_last_active(self, obj):
        """実体は `PlayerStreakState.last_achievement_check_at`。

        🔴 **`User.last_login` ではない。** DRF の `TokenAuthentication` は
        `last_login` を更新せず、`django.contrib.auth.login()` の呼び出しも
        0 件なので、**あちらは常に None である** (FEAT-540 §1、実測で User
        3 件中 0 件)。一見もっとも素直な選択肢が実は全員 None という形なので、
        `test_last_active_column_does_not_read_last_login` が走査で縛っている。

        ⚠️ **「ログイン」ではなく「タスク達成」を測っている。**
        更新経路は 3 つ —— 習慣 / ToDo のカウント、チェックリストのチェック、
        実績画面を開いたとき (60 秒スロットル)。
        **アプリを開いただけ・バトルしただけでは動かない。**

        ⚠️ **既知の穴: タイムライン予定の完了だけでは動かない。**
        `views/timeline.py` は `check_achievements` を呼ばないため。
        タイムラインしか使っていないユーザーは休眠に見える。
        `DailyAchievement` (FEAT-539) なら 4 経路すべてを拾えるが、
        **日単位**になるうえ prod の backfill 前は全員空になるので、
        v1.1.3 では精度と即応性を採って本フィールドにした。

        🔵 `obj.streak` (shim) ではなく `obj.streak_state` を読む。
        shim は中で `get_or_create` するので `select_related` が効かない。
        """
        state = getattr(obj, 'streak_state', None)
        return state.last_achievement_check_at if state is not None else None

    # ── 【FEAT-535 (2026-08-29)】バトルステータス個票 ──────────────────────
    #
    # v1.1 §5.2 の観測期間 (10/3-10/29) に「なぜ healer の勝率が 25% なのか」を
    # 見るための個票。集計は PostHog (FEAT-531) の仕事で、admin は個票に徹する。
    #
    # 🔴 **これは Flutter 側の式のミラーである。** Backend はプレイヤーの攻撃力 /
    # HP を 1 つも持っておらず、実際の戦闘値は端末が計算している。
    # 式の drift は mobile/test/battle/battle_display_formula_contract_test.dart が
    # 縛っており、係数を変えると Dart のテストが battle_stats_preview.py を
    # 名指しで落とす。
    #
    # ⚠️ **list_display には入れない。** 1 行ごとに CharacterStat 6 件 +
    # PlayerWeapon + Character + Job を引くので、一覧に出すと N+1 になる。
    # 詳細画面 1 件なら 4 本 (CharacterStat 6 件を 1 本 / PlayerWeapon /
    # PlayerBattleState / WeaponMaster) で、`test_detail_render_query_count` が
    # その本数を縛っている。
    #
    # ⚠️ read-only の計算列なので **list_editable には絶対に入れない** ——
    # admin.E121 で `manage.py check` が落ち、build.sh の migrate が止まって
    # デプロイ不能になる (EnemyAdmin に前例あり)。
    readonly_fields = ('battle_stats_preview',)

    def save_formset(self, request, form, formset, change):
        # 【FEAT-538 (2026-08-29)】🔴 **inline 経由は `save_model` を通らない。**
        # PlayerBattleStateInline から level を編集したときに max_exp を追従
        # させるのはここ。前例は PlayerStatsMatrixAdmin.save_formset
        # (CharacterStat の max_exp を同じ形で追従させている)。
        #
        # ⚠️ current_exp は触らない。Lv を下げると current_exp > max_exp に
        # なりうるが、support が補償として意図的に高い EXP を入れている場合が
        # あり、勝手に切り詰めると**運営の意図を壊す**。
        #
        # ⚠️ 他の inline (economy / streak / gacha / settings) は必ず super()
        # に流すこと。分岐を書き忘れると、その inline が**保存されなくなる**。
        if formset.model is PlayerBattleState:
            instances = formset.save(commit=False)
            for instance in instances:
                instance.max_exp = GameBalance.level_to_max_exp(instance.level)
                instance.save()
            for obj in formset.deleted_objects:
                obj.delete()
            formset.save_m2m()
        else:
            super().save_formset(request, form, formset, change)

    def get_queryset(self, request):
        # 個票が読む `active_character.job` を 1 本にまとめる。
        #
        # ⚠️ `battle_state` はここに足しても効かない。`player.battle` は
        # FEAT-478 の @property shim (`get_or_create` + instance キャッシュ) で、
        # `select_related` が張った逆参照ディスクリプタを見ないため。
        # 効かないものを書くと「効いている」と誤読されるので足さない。
        #
        # 🔵 【FEAT-540 (2026-09-06)】**`streak_state` は効く。読み方が違うため。**
        #    実測 (player 3 件):
        #
        #        plain          + `obj.streak`         4 本
        #        select_related + `obj.streak`         4 本   ← 効かない
        #        select_related + `obj.streak_state`   1 本   ← 効く
        #        plain          + `obj.streak_state`   4 本
        #
        #    上の警告が正しいのは **shim (`obj.streak`) を読む場合**である。
        #    `get_last_active` は**逆参照ディスクリプタそのもの**
        #    (`obj.streak_state`) を読むので、JOIN が効いて 1 行も増えない。
        #    `test_last_active_adds_no_query_per_row` がこれを縛っている。
        return super().get_queryset(request).select_related(
            'active_character__job', 'streak_state',
        )

    # ── 【BUG-152 (2026-09-06)】プレイヤーごとの削除を通す ──────────────────
    @classmethod
    def cascade_deletable_verbose_names(cls) -> set:
        """`perms_needed` から取り除く `verbose_name` の集合。

        🔴 **日本語のリテラルで書かないこと。** `perms_needed` の中身は
        `opts.verbose_name` (日本語の文字列) だが、ここで文字列を直書きすると
        **`verbose_name` を変えた瞬間に静かに効かなくなる** ——
        例外も警告も出ず、ただ削除できなくなる。
        `test_source_does_not_subtract_by_japanese_literal` が走査で縛っている。
        """
        return {model._meta.verbose_name for model in CASCADE_DELETABLE_MODELS}

    def get_deleted_objects(self, objs, request):
        """プレイヤーごとの削除だけ通す (BUG-152)。

        ## なぜ止まっていたか

        `NoDeleteAdminMixin` を付けた 5 つの state admin は
        `has_delete_permission` が**ハードコードで `False`** である。
        Django の `get_deleted_objects` はカスケード対象すべてについて
        これを呼ぶので、**権限テーブルを見ずに `perms_needed` へ入り、
        superuser でも親の削除が 403 になる**。

        ## 何を変えて、何を変えないか

        🔴 **各 state admin の `has_delete_permission` は `False` のまま維持する。**
        塞ぎたいのは「state 行だけ消えて、property の `get_or_create` で
        累計 0 の新しい行が生える」ケースであって、
        「プレイヤーごと消えて state も一緒に消える」ケースではない。
        後者は ORM の cascade として正しく、アカウント削除 API
        (`views/player.py`) が現にそれに依存している。

        ⚠️ **除くのは 5 model 分だけ。** `NoDeleteAdminMixin` の有無で
        自動導出しない —— 将来この mixin を別の目的 (監査ログ等) で使ったとき、
        **消してはいけないものまで消える**。

        ⚠️ **`protected` は触らない。** `PROTECT` な FK は別の仕組みで、
        これは**正しく止めるべきもの**である。返すのは `super()` のまま。
        """
        to_delete, model_count, perms_needed, protected = super().get_deleted_objects(
            objs, request,
        )
        return (
            to_delete,
            model_count,
            perms_needed - self.cascade_deletable_verbose_names(),
            protected,
        )

    def delete_view(self, request, object_id, extra_context=None):
        """⚠️ 削除確認画面に「実ユーザーの退会には使わない」注意を出す。

        admin の削除は**アカウント削除 API が行っている付随処理を飛ばす**:

          - PostHog identity の削除 (2-step)
          - 退会フィードバックの保存
          - Firebase Auth 側の best-effort 削除

        BUG-152 §6 の残るリスクそのものなので、押す前に見える位置に出す。
        """
        if request.method == 'GET':
            self.message_user(
                request,
                'この削除はテストユーザーの掃除用です。'
                '実ユーザーの退会には使わないでください —— '
                'admin からの削除は PostHog identity の削除 / 退会フィードバックの保存 / '
                'Firebase Auth 側の削除を飛ばします。'
                '正規経路はアプリの「設定 → アカウント削除」です。',
                level=messages.WARNING,
            )
        return super().delete_view(request, object_id, extra_context)

    @staticmethod
    def _edit_link(url, label):
        """【FEAT-538 Phase 4】個票から編集画面への導線 1 本。

        ⚠️ `url` は必ず `reverse()` 由来を渡すこと (`ADMIN_URL` は環境変数)。
        """
        return format_html(
            '<a href="{}" style="margin-left:10px;font-size:11px;">{} →</a>',
            url, label,
        )

    @admin.display(description='バトルステータス (Flutter 式のミラー)')
    def battle_stats_preview(self, obj):
        """入力と結果の両方を出す。**結果だけだと、なぜその数字なのかが読めない。**"""
        if obj is None or obj.pk is None:
            return '—（保存後に表示されます）'

        data = compute_player_battle_stats(obj)
        i, st = data['inputs'], data['stats']

        # ── フォールバックは必ず画面に出す (Pre-mortem #6) ──────────────
        # 黙って 10 を出すと「武器を装備している」と誤読される。
        if i['weapon_missing']:
            weapon_text = '⚠️ 未装備 → 10 で計算 (starter_sword 相当)'
        else:
            weapon_text = f"{i['weapon'].name} (atk_bonus {i['weapon_atk']})"

        if i['job_missing']:
            job_text = (
                '⚠️ ジョブ未解決 → modifier 1.0 で計算'
                '（active_character 未設定 or Character.job が null）'
            )
        else:
            job_text = (
                f"{i['job'].job_name} ({i['job'].job_id}) — "
                f"攻撃力 ×{i['attack_power_modifier']} / "
                f"ATB ×{i['atb_speed_modifier']}"
            )

        char_text = (
            i['active_character'].name if i['active_character'] is not None
            else '⚠️ 未設定'
        )

        lv = i['stat_levels']
        stat_text = ' / '.join(f'{k} {v}' for k, v in lv.items())
        if i['missing_stats']:
            stat_text += (
                f"　⚠️ 未作成 {'・'.join(i['missing_stats'])} は 0 として計算"
            )

        # ── 【FEAT-538 Phase 4 (2026-08-29)】編集画面への導線 ──────────
        #
        # 閲覧は本個票に集約されたのに、編集は 4 画面に散っている。入力の隣に
        # その入力を触れる画面へのリンクを置く。
        #
        # ⚠️ **URL をハードコードしないこと。** admin のマウント先は
        # `ADMIN_URL` 環境変数で差し替わる (Render で予測困難なパスにしている)。
        # `/admin/...` と直書きすると dev か prod のどちらかで 404 になる。
        # `reverse()` は DB を引かないので、クエリ本数は増えない
        # (`test_detail_render_query_count` が 4 本を縛っている)。
        #
        # アクティブキャラ / ジョブは本ページ内で編集できるのでリンク不要。
        level_link = self._edit_link(
            reverse('admin:api_playerbattlestate_change', args=[obj.pk]),
            'Lv を編集',
        )
        stats_link = self._edit_link(
            reverse('admin:api_playerstatsmatrix_change', args=[obj.pk]),
            '6 ステータスを編集',
        )
        weapon_link = self._edit_link(
            reverse('admin:api_playerweapon_changelist')
            + f'?player__id__exact={obj.pk}',
            '所持武器を編集',
        )

        rows = [
            ('入力', 'レベル', format_html('{}{}', i['level'], level_link)),
            ('入力', '6 ステータス', format_html('{}{}', stat_text, stats_link)),
            ('入力', '装備武器', format_html('{}{}', weapon_text, weapon_link)),
            ('入力', 'アクティブキャラ', char_text),
            ('入力', 'ジョブ', job_text),
            ('結果', 'ATK', st['atk']),
            ('結果', 'maxHP', st['max_hp']),
            ('結果', 'SPD', f"{st['spd']}（MVP 固定）"),
            ('結果', 'ATB 倍率', f"{st['atb_modifier']:.2f}x"),
            ('結果', '毎ターン回復', f"{st['hp_regen_per_turn']} HP"),
            ('結果', 'クリ率', f"{st['crit_rate'] * 100:.1f}%"),
            ('結果', '被ダメ軽減', f"{st['damage_reduction'] * 100:.1f}%"),
        ]

        body = format_html_join(
            '',
            '<tr><td style="padding:2px 10px;color:#888;">{}</td>'
            '<td style="padding:2px 10px;white-space:nowrap;">{}</td>'
            '<td style="padding:2px 10px;"><b>{}</b></td></tr>',
            rows,
        )
        return format_html(
            '<table style="border-collapse:collapse;">{}</table>'
            '<p style="margin-top:8px;color:#888;">'
            '🔴 これは Flutter 側の計算式のミラーです。'
            '<b>実際の戦闘値は端末が計算しています。</b><br>'
            '表示されるのは常に<b>「今の値」</b>で、'
            '過去の戦闘時点の値ではありません'
            '（Battle は敵側の初期値しか保存していないため）。'
            '</p>',
            body,
        )


# 【2026-07-09】「ステータス個別編集」admin。
# model の verbose_name を「キャラクターステータス」→「ステータス個別編集」に
# 変更 (migration 0182)、long-format (1 行 = 1 player × 1 stat) の位置付けを
# 「support で 1 stat をピンポイント修正する導線」に明確化。
# cross-player 比較 / 一覧は新規 PlayerStatsMatrix admin で提供 (下記)。
@admin.register(CharacterStat)
class CharacterStatAdmin(admin.ModelAdmin):
    list_display        = ('player', 'name', 'level', 'current_exp', 'max_exp')
    list_filter         = ('name',)
    list_editable       = ('level', 'current_exp')
    search_fields       = ('player__name', 'player__friend_id', 'player__user__email')
    autocomplete_fields = ('player',)
    ordering            = ('player__name', 'name')
    # 【2026-07-09 レビュー §2 P1 対応】max_exp は level から自動再計算 (下記 save_model 参照)、
    # support が手動編集して drift する経路を潰す。
    readonly_fields     = ('max_exp',)

    def save_model(self, request, obj, form, change):
        # 【2026-07-09 レビュー §2 P1 対応】list_editable / 詳細編集の両経路で
        # level を触った場合に max_exp を強制再計算 (compound int() 再現)。
        # 「level=6 に上げたけど max_exp を Lv5 のまま残す」等の drift を構造的に不可。
        # 計算式の真実値は services/exp_service.stat_max_exp_at_level。
        obj.max_exp = stat_max_exp_at_level(obj.level)
        super().save_model(request, obj, form, change)


# 【2026-07-09 Phase C】HabitAdmin: 検索 / autocomplete / list_display 拡充。
# 従来は search_fields / autocomplete / ordering がなく support 対応 (「A さんの
# Habit を確認したい」) で dropdown / scroll しかできなかった。frequency /
# reset_cycle / difficulty も list_display に追加、Habit 種別を一覧で読める。
@admin.register(Habit)
class HabitAdmin(admin.ModelAdmin):
    list_display  = (
        'name', 'player', 'category', 'frequency', 'reset_cycle',
        'difficulty', 'streak', 'total_count', 'is_active', 'created_at',
    )
    list_filter   = ('category', 'is_active', 'frequency', 'difficulty', 'habit_type')
    list_editable = ('is_active',)
    search_fields = (
        'name', 'player__name', 'player__friend_id', 'player__user__email',
    )
    autocomplete_fields = ('player',)
    date_hierarchy = 'created_at'
    ordering = ('-created_at',)


# 【2026-07-09 Phase C】HabitLogAdmin: date_hierarchy + search + autocomplete。
# 30,000 行級に膨れる想定の log table で search が皆無 = 実質不可用だった問題を解消。
# get_player callable で habit → player を 1 列に展開、cross-table 探索性 UP。
@admin.register(HabitLog)
class HabitLogAdmin(admin.ModelAdmin):
    list_display   = ('date', 'habit', 'get_player', 'count', 'exp_gained')
    list_filter    = ('habit__category',)  # date は date_hierarchy に移譲
    search_fields  = (
        'habit__name', 'habit__player__name', 'habit__player__friend_id',
    )
    autocomplete_fields = ('habit',)
    date_hierarchy = 'date'
    ordering       = ('-date', '-id')
    list_per_page  = 50

    @admin.display(description='プレイヤー', ordering='habit__player__name')
    def get_player(self, obj):
        return obj.habit.player.name


# 【FEAT-458 (2026-06-21)】お知らせ管理 admin。
# 運営が Django admin から GUI でお知らせ追加・編集・無効化 (is_active=False) 可能。
# 【2026-06-27】link_character (FK) を新規キャラ告知時の動線として編集可能化。
# 【2026-06-27】公開予約機能: published_at を未来日時に設定 → 到達まで非公開、
# 到達後自動公開。fieldsets で「公開予約」セクションに分離し運用方法を明示。
# 【2026-06-27】image (ImageField) 追加。Mobile popup の本文上に大きく表示。
# 【2026-06-27】プレビュー機能: change_view にプレビューボタン追加、別画面で
# Mobile popup UI 風に確認 → 「投稿する」ボタンで is_active=True + published_at=now
# に更新する経路を提供。下書き運用 (is_active=False で保存 → プレビュー → 公開)
# を構造的にサポート。
@admin.register(Announcement)
class AnnouncementAdmin(admin.ModelAdmin):
    list_display = ('title', 'published_at', 'expires_at', 'has_image',
                    'link_character', 'is_active')
    list_filter = ('is_active', 'published_at')
    list_editable = ('is_active',)  # 一覧画面から論理削除を即時切替
    search_fields = ('title', 'body')
    raw_id_fields = ('link_character',)  # キャラ数が増えても dropdown 重くならない
    # change_form_template でプレビューボタンを add (詳細は templates/admin/api/
    # announcement/change_form.html を参照)。
    change_form_template = 'admin/api/announcement/change_form.html'
    fieldsets = (
        ('お知らせ内容', {
            'fields': ('title', 'title_en', 'body', 'body_en', 'image'),
            'description': 'image: 任意、本文の上に大きく表示されます (16:9 推奨)。title_en / body_en: 英語版 (空欄 = ja にフォールバック)。',
        }),
        ('公開予約', {
            'fields': ('published_at', 'expires_at', 'is_active'),
            'description': (
                'published_at = 公開日時 (未来日時に設定すると、その時刻まで非公開、'
                '到達後に自動公開)。default = 「今」 (= 保存と同時に公開)。<br>'
                'expires_at = 公開終了日時 (任意、null = 無期限)。<br>'
                'is_active = 論理削除フラグ (False で即時非公開、履歴は保持)。'
                '<br><strong>運用 Tip:</strong> 下書き保存は is_active=False で実施し、'
                '上部の「プレビューを表示」ボタンで確認 → 問題なければプレビュー画面の'
                '「投稿する」ボタンで公開してください。'
            ),
        }),
        ('連動', {
            'fields': ('link_character',),
            'description': (
                'キャラを指定すると popup に「詳細を見る」ボタンが追加され、'
                'tap でキャラ詳細シートに遷移します。新キャラ告知用。'
            ),
        }),
    )

    def has_image(self, obj):
        """list_display で画像有無を ✓ / - で表示"""
        return bool(obj.image)
    has_image.boolean = True
    has_image.short_description = '画像'

    # ── プレビュー機能 (カスタム URL) ───────────────────────────────
    def get_urls(self):
        """change_view と一覧 view の他に、preview / publish のカスタム URL を追加。"""
        urls = super().get_urls()
        custom = [
            path(
                '<int:object_id>/preview/',
                self.admin_site.admin_view(self.preview_view),
                name='api_announcement_preview',
            ),
            path(
                '<int:object_id>/publish/',
                self.admin_site.admin_view(self.publish_view),
                name='api_announcement_publish',
            ),
        ]
        return custom + urls

    def preview_view(self, request, object_id):
        """お知らせのプレビュー画面 (Mobile popup UI 風 HTML レンダリング)。
        change_form 上の「プレビューを表示」ボタンから別タブで開かれる想定。
        ステータス判定 (公開中 / 予約 / 下書き) は context で渡してテンプレート簡素化。"""
        announcement = get_object_or_404(Announcement, pk=object_id)
        now = timezone.now()
        is_published_now = (
            announcement.is_active and announcement.published_at <= now
        )
        is_scheduled = (
            announcement.is_active and announcement.published_at > now
        )
        is_draft = not announcement.is_active
        return render(request, 'admin/api/announcement/preview.html', {
            'announcement':     announcement,
            'opts':             self.model._meta,
            'has_view_permission': True,
            'title':            f'お知らせプレビュー: {announcement.title}',
            'is_published_now': is_published_now,
            'is_scheduled':     is_scheduled,
            'is_draft':         is_draft,
        })

    def publish_view(self, request, object_id):
        """プレビュー画面の「投稿する」ボタン経路。
        is_active=True + published_at=now に更新して change_view へ redirect。
        idempotent: 既に公開済なら何もせず redirect のみ。"""
        if request.method != 'POST':
            # GET で誤アクセスされたら change_view へ redirect (操作なし)
            return HttpResponseRedirect(
                reverse('admin:api_announcement_change', args=[object_id])
            )
        announcement = get_object_or_404(Announcement, pk=object_id)
        # 公開: is_active=True、published_at=now (未来日予約は今すぐ公開に上書き)
        announcement.is_active = True
        announcement.published_at = timezone.now()
        announcement.save(update_fields=['is_active', 'published_at'])
        messages.success(request, f'お知らせ「{announcement.title}」を公開しました 🪶')
        return HttpResponseRedirect(
            reverse('admin:api_announcement_change', args=[object_id])
        )


# 【2026-06-27】キャラクター管理 admin。
# 新キャラ追加機能 (Gemini 要件) で「運営がエンジニアなしで新キャラを追加できる」を満たすため、
# 既存未登録だった Character model を admin に追加。tagline / release_date も list_editable で
# その場編集可能。Announcement 側で link_character として参照する。
#
# 【2026-06-27 段階公開機能】is_published を list_editable に追加し、運営が一覧画面から
# 一括でキャラ公開/非公開を切替可能。初回リリース 6 体 → 月 1-2 体追加公開の運用を支援。
# 非公開キャラは CharacterListView / ガチャ抽選 / 購入経路から完全除外される。
@admin.register(Character)
class CharacterAdmin(admin.ModelAdmin):
    list_display  = ('name', 'role', 'key', 'is_published', 'tagline',
                     'release_date', 'is_starter', 'unlock_level', 'price', 'order')
    list_filter   = ('is_published', 'is_starter', 'release_date')
    search_fields = ('name', 'key', 'role', 'tagline', 'description')
    list_editable = ('is_published', 'tagline', 'release_date', 'order')
    ordering      = ('order',)
    fieldsets = (
        ('基本情報', {
            'fields': ('key', 'name', 'name_en', 'role', 'role_en', 'tagline', 'tagline_en', 'description', 'description_en'),
            'description': '*_en: 英語版 (空欄 = ja にフォールバック、FEAT-489 Phase 4)。',
        }),
        ('公開設定', {
            'fields': ('is_published', 'release_date'),
            'description': 'is_published=False = 非公開 (一覧 / ガチャ / 購入から除外)。'
                           'starter (is_starter=True) は本フラグに関わらず常時公開される。',
        }),
        ('画像', {
            'fields': ('image_path',),
        }),
        ('ゲームパラメータ', {
            'fields': ('price', 'unlock_level', 'is_starter', 'order', 'job'),
        }),
    )


# 【2026-07-09 Phase C】PlayerAnnouncementReadAdmin:
# 「特定お知らせの既読率」の集計運用を可能にするため list_filter に announcement
# を追加 (お知らせで filter → count で既読ユーザー数)、search_fields 追加で
# ユーザー / お知らせ名検索可能、raw_id_fields → autocomplete_fields で UX 上位互換。
@admin.register(PlayerAnnouncementRead)
class PlayerAnnouncementReadAdmin(admin.ModelAdmin):
    list_display   = ('read_at', 'player', 'announcement')
    list_filter    = ('announcement', 'read_at')
    search_fields  = (
        'player__name', 'player__friend_id',
        'announcement__title',
    )
    autocomplete_fields = ('player', 'announcement')
    date_hierarchy = 'read_at'
    ordering       = ('-read_at',)


# 【FEAT-463 (2026-06-22)】緊急メンテナンスモード管理 admin。
# Singleton (pk=1 固定): add は条件付き override、delete は NoDeleteAdminMixin で抑制。
# 【FEAT-471 (2026-07-02)】save_model に cache invalidation hook を追加。
@admin.register(MaintenanceConfig)
class MaintenanceConfigAdmin(NoDeleteAdminMixin, admin.ModelAdmin):
    # 【FEAT-536 (2026-08-29)】翻訳の下書きプロンプトをクリップボードへコピーする
    # ボタン。JS は `id_<name>` / `id_<name>_en` のペアを自動検出するので、
    # ここでの対応表の設定は不要 (ChallengeAdmin と同じ)。
    class Media:
        js = ('admin/js/i18n_translate_prompt.js',)

    list_display = ('is_enabled', 'title', 'expires_at', 'updated_at')
    # 🔴 【FEAT-536】`title_en` / `body_en` を追加した。
    # `fields` を明示している以上、**model に field があっても admin には
    # 出てこない** —— つまり入力経路が存在しなかった。2026-08-11 に
    # `Challenge` で直したのと同じ欠陥で、こちらは**障害中の唯一の画面**に
    # 出る経路だった。露出は `test_i18n_field_census.py` の走査で縛っている。
    fieldsets = (
        ('メンテナンス状態', {
            'fields': ('is_enabled', 'expires_at'),
        }),
        ('日本語', {
            'fields': ('title', 'body'),
        }),
        ('English', {
            'fields': ('title_en', 'body_en'),
            'description': (
                '英語欄が空のまま ON にすると、英語のユーザーには '
                '<strong>汎用の英文</strong>が出ます (日本語は出ません)。<br>'
                '<strong>具体的な状況を伝えたいときは英語欄も埋めてください。</strong><br>'
                '⚠️ 汎用英文の実体は <code>api/views/maintenance.py</code> の '
                '<code>_EN_FALLBACK</code> です。'
            ),
        }),
    )

    # add は「pk=1 が未作成なら 1 回だけ許可」の条件付きなので mixin 化しない。
    def has_add_permission(self, request):
        # Singleton: pk=1 が既にあれば追加禁止
        return not MaintenanceConfig.objects.filter(pk=1).exists()

    def save_model(self, request, obj, form, change):
        # 【Pre-mortem S3】expires_at 未入力時は admin に警告する想定だったが、
        # v1.0 は help_text の明示のみで対応 (Slack 通知等の能動検知は v1.1+)。
        obj.created_by = request.user
        super().save_model(request, obj, form, change)
        # 【FEAT-471】admin 保存で cache を即時 invalidate → 次のリクエストから最新値が反映される
        from .services.maintenance_cache import invalidate_maintenance_cache
        invalidate_maintenance_cache()


# 【FEAT-543 (2026-09-23)】バージョンアップ告知 admin。
# Singleton (pk=1 固定)。MaintenanceConfigAdmin をそのまま写している。
@admin.register(AppUpdateConfig)
class AppUpdateConfigAdmin(NoDeleteAdminMixin, admin.ModelAdmin):
    # 【FEAT-536】翻訳の下書きプロンプトをクリップボードへコピーするボタン。
    class Media:
        js = ('admin/js/i18n_translate_prompt.js',)

    list_display = (
        'is_enabled', 'latest_version', 'min_supported_version', 'updated_at',
    )
    fieldsets = (
        ('告知の ON / OFF', {
            'fields': ('is_enabled',),
            'description': (
                '🔴 <strong>latest_version を上げるのは、実機でストアから'
                '実際に落とせることを確認した後にしてください。</strong><br>'
                '承認直後のバイナリは地域ごとに段階配信されるため、数時間は'
                '古い版が返ります。そこで告知すると<strong>押しても更新できない</strong>'
                '画面を見せることになります。<br>'
                '🔵 事故ったらここを OFF にすれば 60 秒で全ユーザーから消えます '
                '(推奨も必須もまとめて止まります)。<br>'
                '⚠️ 手順と運用早見表は <code>doc/runbook/app_update_notice.md</code> にあります。'
            ),
        }),
        ('しきい値', {
            'fields': ('latest_version', 'min_supported_version'),
            'description': (
                '<strong>latest_version</strong> = 「ここまで上げてほしい」'
                '(「後で」で閉じられる)<br>'
                '<strong>min_supported_version</strong> = 「ここより古いと'
                '使わせられない」(閉じられない)<br>'
                '🔴 <strong>min_supported_version は空のままが既定です。</strong>'
                '入れるのは「その版ではデータが壊れる」ときだけ。'
                '<strong>審査中の版を含めないでください</strong>'
                '(reviewer が古い版で詰みます)。'
            ),
        }),
        ('日本語 (推奨更新の文面)', {
            'fields': ('title', 'body'),
            'description': (
                '⚠️ ここで編集できるのは<strong>推奨更新の文面</strong>です。<br>'
                '必須更新 (閉じられない側) の文面は'
                '<strong>下の「必須更新の文面」欄</strong>で編集します '
                '(FEAT-544)。空にするとアプリ内の固定文に落ちるので、'
                '<strong>緊急時に何も書かなくても成立します</strong>。'
            ),
        }),
        ('English (推奨更新の文面)', {
            'fields': ('title_en', 'body_en'),
            'description': (
                '英語欄が空のまま ON にすると、英語のユーザーには '
                '<strong>汎用の英文</strong>が出ます (日本語は出ません)。<br>'
                '⚠️ 汎用英文の実体は <code>api/models/app_update.py</code> の '
                '<code>EN_FALLBACK</code> です。'
            ),
        }),
        ('必須更新の文面 (閉じられない画面)', {
            'fields': (
                'mandatory_title', 'mandatory_body',
                'mandatory_title_en', 'mandatory_body_en',
            ),
            'description': (
                '🔵 <strong>空にするとアプリ内の既定文が出ます。</strong>'
                '文面の無い画面にはなりません。<br>'
                '⚠️ <strong>必須更新が発火するのは、上の「最低サポート'
                'バージョン」に数字が入っているときだけです。</strong>'
                '文面を書いても、そこが空なら誰にも出ません。<br>'
                '🔴 この画面は<strong>閉じられません</strong>。'
                '文面は「何をすればよいか」が分かるように書いてください。'
            ),
        }),
    )

    # add は「pk=1 が未作成なら 1 回だけ許可」の条件付きなので mixin 化しない。
    def has_add_permission(self, request):
        return not AppUpdateConfig.objects.filter(pk=1).exists()

    def save_model(self, request, obj, form, change):
        obj.created_by = request.user
        super().save_model(request, obj, form, change)
        # admin 保存で cache を即時 invalidate → 次のリクエストから最新値が反映される
        from .services.app_update_cache import invalidate_app_update_cache
        invalidate_app_update_cache()


# 【FEAT-465→FEAT-466 (2026-06-24)】月次カテゴリチャレンジ管理 admin。
# リリース直前 (6/30 中) に Django admin から手動で 7 月分 3 件 seed する運用 (Q5)。
# 【FEAT-466】3 段階 Bronze/Silver/Gold 累積開放方式に対応。is_tiered=False 時の
# bronze/silver 非表示 JS は実装しない (PM 判断: 常時表示でフォーム複雑化を許容)。
# 【2026-07-09 Phase C】ChallengeAdmin: search_fields 追加 (ChallengeParticipationAdmin
# の autocomplete_fields 依存)、list_editable で is_active / is_tiered を一覧切替可。
@admin.register(Challenge)
class ChallengeAdmin(admin.ModelAdmin):
    # 【2026-08-11】翻訳の下書きプロンプトをクリップボードへコピーするボタン。
    # JS は `id_<name>` / `id_<name>_en` のペアをフォームから自動検出するので、
    # ここでの対応表の設定は不要 (field を足しても更新漏れが起きない)。
    #
    # **LLM は呼んでいない。** 外部依存もシークレットも増やさずに運用を軽くする
    # 方式で、`anthropic` を SEC-11 (2026-05-15) で撤去した状態を維持している。
    # API を直接叩く案 (工数 6-8h + Render env var 追加) は v1.1 では見送った。
    class Media:
        js = ('admin/js/i18n_translate_prompt.js',)

    list_display = (
        'title', 'category', 'is_tiered', 'current_count', 'target_count_gold',
        'start_date', 'end_date', 'is_active',
    )
    list_filter = ('category', 'is_tiered', 'is_active')
    list_editable = ('is_active', 'is_tiered')
    search_fields = ('title', 'description')
    ordering = ('-start_date', 'title')
    fieldsets = (
        (None, {'fields': ('title', 'description', 'category', 'is_active')}),
        # 【2026-08-11】英語版の入力欄。**fieldsets を明示定義しているため、
        # model に field があってもここに書かない限り admin に出てこない**。
        # FEAT-516 (migration 0200) で `title_en` / `description_en` は追加済
        # だったが、この欄が無いせいで入力経路が存在せず、英語 UI でチャレンジ名
        # だけ日本語のまま出ていた。
        #
        # Challenge は seed も management command も無く **admin で手動作成する
        # 運用**なので、翻訳 JSON (`translate_master_data`) では埋められない。
        # 月次でチャレンジを作るときに、ここも一緒に入力すること。
        # 空欄なら ja へ silent fallback する (`get_i18n_field`)。
        ('英語版 (v1.1〜、空欄なら日本語にフォールバック)', {
            'fields': ('title_en', 'description_en'),
            'description': (
                '英語 locale のユーザーに表示されます。'
                '<strong>空欄だと日本語がそのまま出ます。</strong>'
            ),
        }),
        ('累積開放方式', {'fields': ('is_tiered',)}),
        ('目標回数', {'fields': ('target_count_bronze', 'target_count_silver', 'target_count_gold')}),
        ('報酬 EXP', {'fields': ('reward_exp_bronze', 'reward_exp_silver', 'reward_exp_gold')}),
        ('期間', {'fields': ('start_date', 'end_date')}),
        ('集計 (denormalized counter)', {'fields': ('current_count',)}),
    )
    # Challenge.clean() の bronze<silver<gold validation は ModelForm の
    # _post_clean() (instance.full_clean()) 経由で admin 保存時に自動発火する
    # ため、save_model のオーバーライドは不要 (Django 標準挙動)。


# 【2026-07-09 Phase C】ChallengeParticipationAdmin:
# 従来は完全 view-only で「Silver 到達したのに silver_granted=False のまま報酬
# 未配布」等のバグ救済が admin から不可能 (SQL 直触が必要) だった。change を
# 許可し、bronze/silver/gold_granted と contribution_count を list_editable に
# することで、救済経路を admin に集約する。
#
# 想定運用シナリオ:
#   - bug で Silver 到達したのに未配布: 該当ユーザーの diamond/exp を PlayerEconomyState
#     admin から補償 → 本 admin で silver_granted=True にセット (二重配布防止)
#   - 誤って granted=True になった: False に戻して次回タスク完了時に自動再配布
#
# add / delete は禁止 (Backend が生成、admin 経路で作成 = 削除する運用はない)。
@admin.register(ChallengeParticipation)
class ChallengeParticipationAdmin(NoAddAdminMixin, NoDeleteAdminMixin,
                                  admin.ModelAdmin):
    list_display = (
        'player', 'challenge', 'contribution_count', 'last_contribution_date',
        'bronze_granted', 'silver_granted', 'gold_granted',
    )
    list_filter = ('gold_granted', 'silver_granted', 'bronze_granted', 'challenge')
    list_editable = (
        'contribution_count',
        'bronze_granted', 'silver_granted', 'gold_granted',
    )
    search_fields = (
        'player__name', 'player__friend_id', 'player__user__email',
        'challenge__title',
    )
    autocomplete_fields = ('player', 'challenge')
    readonly_fields = ('last_contribution_date',)
    ordering = ('challenge', 'player__name')

    fieldsets = (
        ('参加関係', {
            'fields': ('player', 'challenge'),
            'description': (
                '<strong>player</strong> / <strong>challenge</strong> の組合せは '
                'unique_together で保護。add / 変更後の re-save で違反すると保存時エラー。'
            ),
        }),
        ('進捗', {
            'fields': ('contribution_count', 'last_contribution_date'),
            'description': (
                '<strong>contribution_count</strong> = ユーザー個人の貢献回数 '
                '(challenge の集合カウンタ current_count とは別)。<br>'
                'last_contribution_date は Backend が自動更新、admin では readonly。'
            ),
        }),
        ('報酬配布フラグ (冪等性キー、慎重に触ること)', {
            'fields': ('bronze_granted', 'silver_granted', 'gold_granted'),
            'description': (
                '<strong style="color: #b91c1c;">⚠ 冪等性キー</strong>: True = 該当 tier の'
                '報酬配布済み、次回タスク完了時に自動再配布されない。<br>'
                '救済対応で granted=True に手動セットする場合は、事前に '
                'PlayerEconomyState admin で diamond / bonus_coins の補償を必ず実施 '
                '(本フラグ操作は「報酬配布記録の記帳」であって、報酬自体は自動配布されない)。'
            ),
        }),
    )


# 【新規 (2026-06-26)】サビセリフ管理 admin。
# 運営が Django admin (`/admin/api/sabimessage/`) からセリフを追加・編集・
# 無効化 (is_active=False) できる。post_save / post_delete signal で
# sabi_loader.py の cache が即時 invalidate される (signals.py 参照)。
@admin.register(SabiMessage)
class SabiMessageAdmin(admin.ModelAdmin):
    list_display = (
        'pool',
        'content_preview',
        'is_active',
        'sort_order',
        'updated_at',
    )
    list_filter = ('pool', 'is_active')
    list_editable = ('is_active', 'sort_order')
    search_fields = ('content', 'note')
    list_per_page = 50
    save_on_top = True  # 編集画面の上部にも保存ボタン (頻繁更新支援)

    fieldsets = (
        ('基本情報', {
            'fields': ('pool', 'content', 'content_en', 'is_active'),
            # 【BUG-145】プール全体を無効化すると YAML の初期値に戻る挙動を明記。
            # 2026-06-26 に home_none_done の 9 行が一括 OFF にされ、日本語では
            # 何も変わらないまま英語だけが日本語に落ちる状態が 2026-08-16 まで
            # 続いた。field の help_text ではなくここに書くのは、help_text を
            # 変えると AlterField migration が発生するため。
            'description': (
                'content_en: 英語版 (空欄 = content にフォールバック)。<br>'
                '⚠ <b>プール内の有効な行が 0 件になると、そのプールは YAML の'
                '初期値に戻ります。</b>日本語では同じセリフが出続け、'
                '<b>英語だけが日本語表示になります</b>。'
                'プール全体を止めたい場合はコード側の対応が必要です。'
            ),
        }),
        ('表示順 / メモ', {
            'fields': ('sort_order', 'note'),
            'classes': ('collapse',),
        }),
        ('タイムスタンプ', {
            'fields': ('created_at', 'updated_at'),
            'classes': ('collapse',),
        }),
    )
    readonly_fields = ('created_at', 'updated_at')

    @admin.display(description='セリフ (冒頭)')
    def content_preview(self, obj):
        """list 画面用 セリフ冒頭プレビュー (50 文字)。"""
        if len(obj.content) <= 50:
            return obj.content
        return format_html(
            '{}<span style="color:#888;">…</span>',
            obj.content[:50],
        )


# 【2026-06-29】ガチャ報酬管理 admin。
#
# 運営が Django admin (`/admin/api/gachareward/`) からデイリー / ウィークリー /
# マンスリー (SSR 確定) ガチャの **内容と排出確率** を編集できる。
#
# 設計:
# - 抽選ロジック `views/gacha.py:_pick_reward` は既に DB の `GachaReward` を
#   真実値として読んでいる (is_active=True かつ ticket_type 一致で filter、
#   weight で 重み付き抽選)。つまり admin 編集は **即座に全ユーザーに反映される**。
# - 唯一 Python 側にハードコードがあるのは `_DAILY_REWARDS` / `_WEEKLY_REWARDS` /
#   `_MONTHLY_REWARDS` の seed リテラル (`_ensure_gacha_rewards()` で初回のみ
#   get_or_create、既存 entry は touch しない)。admin で weight を編集しても
#   seed リテラル側の値は再書き込みされない冪等設計のため上書き事故が起きない。
#
# 削除許可 (`has_delete_permission` 明示指定なし = Django admin default で許可):
# - 【2026-07-02】ユーザー要望で削除を可能化。運営が「試作エントリを消して整理したい」
#   ケースに対応。ただし GachaHistory.reward は on_delete=CASCADE なので、削除すると
#   過去のガチャ履歴の該当行が **連鎖削除される** (BUG-119 で history.character 経由の
#   表示契約が壊れる原因になった経路)。誤操作抑止として:
#     1. fieldset の「状態」description に削除時の CASCADE 影響を強い警告として明示
#     2. Django admin 標準の削除確認ダイアログで 1 段保護 (「本当に削除しますか?」)
#   運用推奨: **論理削除 (`is_active=False`) で除外し、DB からは残す**。物理削除は
#   「本当に不要 + 過去履歴の該当行が消えても構わない」と判断した場合のみ実行する。
#
# 排出確率 % の表示:
# - `get_queryset` で各 ticket_type の active 合計 weight を Subquery annotate、
#   一覧画面で「weight 6 / 合計 200 = 3.00%」を各行に併記する (N+1 回避)。
# - 「ユーザー要望: SSR 確定ガチャの確率」= Monthly Gacha は通常 character entry
#   が唯一の active entry (weight=100、確率 100%)。BUG-97 で天井廃止済、
#   FEAT-433 で 21 日達成で月 1 枚配布される SSR 確定チケット。
@admin.register(GachaReward)
class GachaRewardAdmin(admin.ModelAdmin):
    # 【FEAT-536 (2026-08-29)】翻訳の下書きプロンプトをクリップボードへコピーする
    # ボタン。JS は `id_<name>` / `id_<name>_en` のペアを自動検出するので、
    # ここでの対応表の設定は不要 (field を足しても更新漏れが起きない)。
    class Media:
        js = ('admin/js/i18n_translate_prompt.js',)

    list_display = (
        'ticket_type', 'rarity', 'reward_type', 'icon_display', 'name',
        'detail_short', 'weight', 'drop_rate_display', 'value', 'is_active',
    )
    list_filter   = ('ticket_type', 'rarity', 'reward_type', 'is_active')
    list_editable = ('weight', 'value', 'is_active')
    search_fields = ('name', 'detail', 'weapon_key')
    ordering      = ('ticket_type', 'rarity', '-weight', 'id')
    save_on_top   = True
    list_per_page = 100

    fieldsets = (
        ('基本情報', {
            'fields': ('ticket_type', 'rarity', 'reward_type'),
            'description': (
                'ticket_type: daily=デイリー、weekly=ウィークリー、monthly=マンスリー (SSR 確定)。<br>'
                'reward_type: exp / diamond / xp_boost / title / character / weapon / character_ticket。<br>'
                '<strong>注意</strong>: monthly + character の唯一 active entry を deactivate すると '
                'マンスリー (SSR 確定) が回せなくなります。<br>'
                '<strong>注意</strong>: reward_type=weapon を選んだ場合は weapon_key (例: mythril_sword) の入力が必要です。'
            ),
        }),
        ('表示情報 (ユーザーに見える文言)', {
            # 🔴 【FEAT-536】`name_en` / `detail_en` を追加した。
            # 欄が無い状態では、ja を直した時点で `_en` が陳腐化し、
            # **admin から直す手段が無い** ——
            # `translate_master_data` の `_source_matches` が「翻訳元と違う」で
            # skip するため、次の一括投入でも直らない。
            'fields': ('name', 'name_en', 'detail', 'detail_en', 'icon'),
            'description': (
                'name / detail はユーザーの結果画面に表示されます。'
                'icon は絵文字 1 文字推奨 (例: 💎 ⚔️ ✨ ⭐ 🌟)。<br>'
                '<strong style="color: #b91c1c;">⚠ 日本語を直したら英語も直してください。</strong> '
                '英訳は通常 <code>translate_master_data</code> で一括投入しますが、'
                'そのコマンドは「翻訳元の日本語が投入時と違う」行を <strong>skip</strong> します。'
                'ここで ja だけ書き換えると、<strong>英語が古いまま固定されます</strong>。'
            ),
        }),
        ('数値設定', {
            'fields': ('weight', 'value', 'weapon_key'),
            'description': (
                'weight = 排出ウェイト (相対値、同 ticket_type 内の他 entry との比率で確率が決まる)。<br>'
                '&nbsp;&nbsp;例: Weekly 全 entry の合計 weight=200 のとき、weight=1 の entry は 1/200=0.50% の確率。<br>'
                'value = 報酬値 (exp の EXP 量 / diamond の枚数 / xp_boost の stock 数 / character は 0 = 未所持優先ランダム)。<br>'
                'weapon_key = reward_type=weapon のとき WeaponMaster.key (例: mythril_sword、dragon_slayer)。それ以外では空。'
            ),
        }),
        ('状態', {
            'fields': ('is_active',),
            'description': (
                'is_active=False で抽選プールから除外されます (履歴は保持、推奨経路)。<br>'
                '<strong style="color: #b91c1c;">⚠ 物理削除は連鎖削除のリスクあり</strong>: '
                'GachaReward を admin から削除すると <code>GachaHistory.reward</code> が '
                '<code>on_delete=CASCADE</code> のため <strong>過去のガチャ履歴の該当行も同時に消えます</strong>。'
                'BUG-119 の再発源になるため、通常は <strong>is_active=False で論理削除</strong> することを強く推奨します。<br>'
                '<strong>変更は即時反映</strong>: weight や is_active の編集は次回ガチャ抽選から '
                '即座に全ユーザーに反映されます (デプロイ不要)。'
            ),
        }),
    )

    # 【2026-07-02】has_delete_permission は明示指定なし = Django admin default で許可。
    # 削除時の連鎖影響は fieldset description で警告表示 (誤操作は Django 標準の削除
    # 確認ダイアログでもう 1 段保護される)。運用推奨は依然として is_active=False での
    # 論理削除だが、明示的に物理削除したいケース (試作エントリの整理等) に対応する。

    @admin.display(description='アイコン')
    def icon_display(self, obj):
        try:
            return obj.icon or '—'
        except Exception:
            return '—'

    @admin.display(description='詳細')
    def detail_short(self, obj):
        try:
            detail = obj.detail or ''
            if len(detail) <= 20:
                return detail
            return f'{detail[:20]}…'
        except Exception:
            return '—'

    # 【2026-06-29 hotfix】get_queryset の Subquery annotate を削除。
    # 旧実装は OuterRef + Subquery で各 ticket_type の active 合計を annotate していたが、
    # change_view (編集画面遷移) は get_object 経由で get_queryset の annotate を引き継ぎ、
    # 単一行取得時の SELECT に Subquery が残留して 500 を発生させていた (PostgreSQL での
    # Subquery + .get(pk=...) の組み合わせで再現)。
    # → drop_rate_display 内で個別 aggregate に書き換え、changelist 表示時のみ計算する設計に変更。
    # changelist 1 ページ最大 100 件 + ticket_type 3 種 → request 内 totals cache で実質 3 query。
    # change_view では drop_rate_display 自体が呼ばれないため影響ゼロ。

    @admin.display(description='排出確率', ordering='weight')
    def drop_rate_display(self, obj):
        """各 entry の排出確率% を表示。
        例: 「3.00% (w 6/200)」= weight 6 / 同 ticket_type 内 active 合計 200。

        【2026-06-29 hotfix-v3】defensive 化:
        - 表示計算で例外が出ても admin 一覧が 500 にならないよう全例外を捕捉、
          logger.exception で本番ログに traceback を残す + 当該行のみ赤字 'err' 表示
        - format spec '{:.2f}' は SafeString に効かない (Django 仕様) ため、
          rate を f-string で pre-format してから format_html に渡す
        - obj.weight / obj.detail / obj.ticket_type は DB 制約上 NOT NULL だが、
          念のため `or 0` / `or ''` でフォールバック
        """
        try:
            if not obj.is_active:
                return format_html('<span style="color: #999;">— (無効)</span>')
            ticket_type = obj.ticket_type or ''
            weight = obj.weight or 0
            # 毎行で aggregate (3-4 ticket_type のみ、計 3-4 query で軽量)。
            # 旧版の self._drop_rate_totals_cache は ModelAdmin lifecycle 共有で
            # thread-safety の懸念があったため撤去 (Pre-mortem 防御)。
            total = GachaReward.objects.filter(
                ticket_type=ticket_type, is_active=True,
            ).aggregate(s=Sum('weight'))['s'] or 0
            if total <= 0:
                return format_html('<span style="color: #999;">—</span>')
            rate_str = f'{(weight / total) * 100:.2f}'
            return format_html(
                '<strong>{}%</strong> <span style="color: #888; font-size: 0.85em;">(w {}/{})</span>',
                rate_str, weight, total,
            )
        except Exception as e:
            import logging
            logging.getLogger(__name__).exception(
                '[GachaRewardAdmin.drop_rate_display] failed for pk=%s ticket_type=%s: %s',
                getattr(obj, 'pk', '?'),
                getattr(obj, 'ticket_type', '?'),
                e,
            )
            return format_html(
                '<span style="color: red;" title="{}">err</span>',
                str(e)[:120],
            )


# 【FEAT-467 (2026-07-02)】タスク候補 admin。
# 運営が Django admin からタイトル候補 (予定 / ToDo / 習慣) を追加・編集・無効化できる。
# 削除禁止 → is_active=False での論理削除を強制する。
@admin.register(TaskSuggestion)
class TaskSuggestionAdmin(NoDeleteAdminMixin, admin.ModelAdmin):
    list_display  = ('type', 'title', 'category', 'emoji', 'order', 'is_active')
    list_filter   = ('type', 'category', 'is_active')
    list_editable = ('order', 'is_active')
    search_fields = ('title', 'hint')
    ordering      = ('type', 'order', 'id')
    save_on_top   = True
    list_per_page = 100

    fieldsets = (
        ('基本情報', {
            'fields': ('type', 'title', 'title_en', 'category'),
            'description': (
                'type: event=予定 / todo=ToDo / habit=習慣。<br>'
                'category: CATEGORY_CHOICES 11 値 (運動/学習/仕事/体力/美容/健康/精神/創造/社交/休息/その他)。<br>'
                '空欄可 (カテゴリ推薦なし = user が別途選択)。title_en: 英語版 (空欄 = ja にフォールバック)。'
            ),
        }),
        ('表示', {
            'fields': ('emoji', 'hint', 'hint_en'),
            'description': 'emoji: 1-2 文字絵文字 / hint: chip 表示用の補足テキスト (省略可)。hint_en: 英語版 (空欄 = ja にフォールバック)。',
        }),
        ('状態', {
            'fields': ('order', 'is_active'),
            'description': (
                'order: 表示順 (小さいほど上)。<br>'
                'is_active=False で popup 候補から除外 (既存記録は保持)。<br>'
                '<strong>削除は不可</strong>: 論理削除 (is_active=False) を推奨。'
            ),
        }),
    )


# 【2026-06-29】プレイヤーガチャ状態管理 admin (運用補助、編集可)。
# 個別ユーザーのチケット枚数 / redo 状態を確認・調整するための運用ツール。
# 削除禁止 (PlayerProfile 1:1 OneToOne、削除すると同期挙動が壊れる)。
# 【2026-07-09 Phase C】チケット枚数の list_editable 追加、
# raw_id_fields → autocomplete_fields、search_fields 拡充。
# 補償対応で list 一覧から直接チケット数を触れるようになり、詳細画面遷移不要。
@admin.register(PlayerGachaStatus)
class PlayerGachaStatusAdmin(NoDeleteAdminMixin, admin.ModelAdmin):
    list_display = (
        'player', 'daily_tickets', 'weekly_tickets', 'monthly_tickets',
        'redo_used', 'last_pull_pool', 'last_pull_at',
    )
    list_filter   = ('redo_used', 'last_pull_pool')
    list_editable = ('daily_tickets', 'weekly_tickets', 'monthly_tickets')
    search_fields = (
        'player__name', 'player__friend_id', 'player__user__email',
    )
    autocomplete_fields = ('player',)
    ordering = ('-monthly_tickets', '-weekly_tickets', '-daily_tickets')


# 【2026-06-29 → 2026-07-02 拡張】ガチャ履歴 admin (運用デバッグ用、原則読み取り専用)。
# プレイヤーが何を引いたかを admin から確認できる。
# add / change は禁止 (履歴の改ざん禁止)。
#
# 【2026-07-02】delete は許可に変更 (`has_delete_permission=True`)。
# 理由: GachaRewardAdmin で削除許可 (2026-07-02) にした際、Django admin が
# CASCADE で連鎖削除される GachaHistory 側の delete permission も要求するため、
# `has_delete_permission=False` のままだと GachaReward 削除画面で
# 「関連オブジェクトを削除する権限がありません」エラーになる (実測 2026-07-02)。
# 誤操作抑止として:
#   - `NoBulkDeleteAdminMixin` で list view の「削除」action を除外 (一括削除経路を隠す)
#   - `NoAddAdminMixin` + `NoChangeAdminMixin` は維持 (改ざん防止)
#   - list view 行右端の個別 delete link は Django admin default で残る =
#     意図的な操作コストで保護 (直接 GachaHistory を消す通常運用はない)
@admin.register(GachaHistory)
class GachaHistoryAdmin(NoAddAdminMixin, NoChangeAdminMixin,
                        NoBulkDeleteAdminMixin, admin.ModelAdmin):
    list_display    = ('player', 'ticket_type', 'reward', 'character', 'pulled_at')
    list_filter     = ('ticket_type', 'pulled_at')
    raw_id_fields   = ('player', 'reward', 'character')
    search_fields   = ('player__name', 'reward__name')
    date_hierarchy  = 'pulled_at'

    def has_delete_permission(self, request, obj=None):
        # 【2026-07-02】True に変更。GachaReward CASCADE 削除経路を通すため必須。
        # 誤操作は NoBulkDeleteAdminMixin で一括削除 action を除外して抑止。
        # (Django default は permission ベース判定だが、ここは無条件 True が意図)
        return True


# ──────────────────────────────────────────────────────────────────────────────
# 【2026-07-09】武器マスタ / プレイヤー武器 / プレイヤー所持品 admin
# ──────────────────────────────────────────────────────────────────────────────

@admin.register(WeaponMaster)
class WeaponMasterAdmin(admin.ModelAdmin):
    """武器マスタ (master data) の admin 編集画面。

    運営が新規武器を追加、既存武器のバランス調整 (atk_bonus / socket_count / tier)、
    説明文の修正を GUI から実施できる。
    """
    # 【FEAT-536 (2026-08-29)】翻訳の下書きプロンプトをクリップボードへコピーする
    # ボタン。JS は `id_<name>` / `id_<name>_en` のペアを自動検出するので、
    # ここでの対応表の設定は不要 (field を足しても更新漏れが起きない)。
    class Media:
        js = ('admin/js/i18n_translate_prompt.js',)

    list_display  = ('key', 'name', 'atk_bonus', 'tier', 'socket_count', 'description')
    list_filter   = ('tier',)
    # 【運用】balance 調整で頻繁に触る atk_bonus / tier / socket_count を一覧編集可
    list_editable = ('atk_bonus', 'tier', 'socket_count')
    # 【運用】PlayerWeaponAdmin.autocomplete_fields=('weapon',) の要件
    search_fields = ('key', 'name', 'description')
    ordering      = ('tier', 'atk_bonus', 'key')
    save_on_top   = True

    fieldsets = (
        ('基本情報', {
            # 🔴 【FEAT-536】`name_en` を追加 (GachaReward と同じ理由)。
            'fields': ('key', 'name', 'name_en', 'tier'),
            'description': (
                '<strong>key</strong>: internal identifier (例: <code>starter_sword</code>, '
                '<code>dragon_slayer</code>)、ユニーク、Mobile ↔ Backend で共通の識別子。'
                '<strong>変更禁止</strong> (既存 PlayerWeapon / GachaReward.weapon_key が参照)。<br>'
                '<strong>name</strong>: user 表示名 (例:「見習いの剣」「竜殺しの剣」)。<br>'
                '<strong>tier</strong>: バトル勝利時のドロップ分類。'
                '<code>starter</code> = onboarding 配布、'
                '<code>normal</code> / <code>rare</code> = BattleFinishView が動的取得しドロップ抽選、'
                '<code>shop</code> = Shop 購入のみ (ドロップ対象外)。'
            ),
        }),
        ('性能', {
            'fields': ('atk_bonus', 'socket_count'),
            'description': (
                '<strong>atk_bonus</strong>: 攻撃力ボーナス '
                '(参考値: starter_sword=10, bronze=15, iron=20, steel=25, '
                'mythril=35, dragon_slayer=50)。<br>'
                '<strong>socket_count</strong>: v1.0 は固定値 (v1.1+ で結晶装着 UI 解禁予定)。'
                'starter/bronze=1、iron/steel=2、mythril/dragon_slayer=3 が現状 seed。'
            ),
        }),
        ('説明', {
            # 🔴 【FEAT-536】`description_en` を追加。
            'fields': ('description', 'description_en'),
            'description': (
                'user 向け説明文 (Shop / EquipmentSelectionOverlay で表示)。<br>'
                '<strong style="color: #b91c1c;">⚠ 日本語を直したら英語も直してください。</strong> '
                '<code>translate_master_data</code> は「翻訳元の日本語が投入時と違う」行を '
                '<strong>skip</strong> するため、ja だけ書き換えると'
                '<strong>英語が古いまま固定されます</strong>。'
            ),
        }),
    )


@admin.register(PlayerWeapon)
class PlayerWeaponAdmin(admin.ModelAdmin):
    """プレイヤー所持武器 (per-player) の admin 編集画面。

    運営が特定 user に武器を付与 (補償対応等)、装備状態の変更、削除を GUI から実施できる。
    """
    list_display        = ('id', 'player', 'weapon', 'is_equipped', 'acquired_at')
    list_filter         = ('is_equipped', 'weapon__tier', 'weapon')
    list_editable       = ('is_equipped',)
    search_fields       = (
        'player__name', 'player__friend_id',
        'weapon__key', 'weapon__name',
    )
    autocomplete_fields = ('player', 'weapon')
    date_hierarchy      = 'acquired_at'
    readonly_fields     = ('acquired_at',)
    save_on_top         = True


    fieldsets = (
        ('所有者・武器', {
            'fields': ('player', 'weapon'),
            'description': (
                '<strong>player</strong> と <strong>weapon</strong> の組合せは '
                'UniqueConstraint (unique_player_weapon) で保護されている。'
                '既に所持している武器を再付与しようとすると保存時にエラーになる。<br>'
                '<strong>weapon FK は PROTECT</strong> のため、WeaponMaster を削除する前に '
                '関連 PlayerWeapon をすべて削除する必要がある。'
            ),
        }),
        ('装備状態', {
            'fields': ('is_equipped',),
            'description': (
                'v1.0 は 1 人 1 武器を想定 (MVP 前提)、複数所持は Phase 2 拡張予定。'
                '本 flag が True の武器がバトル開始時に自動装備される。<br>'
                '<strong>【FEAT-538】True にして save すると、同じプレイヤーの'
                '他の武器は自動で False に落ちる。</strong> 複数 True にすると '
                'ATK の読み出しが非決定 (順序指定なしの先頭 1 件) になり、'
                '同じプレイヤーの攻撃力がリクエストごとに変わるため。<br>'
                '外す操作 (False) では何も昇格しない。0 本は正当な状態で、'
                'Mobile は未装備なら atk_bonus 10 (starter_sword 相当) で計算する。'
            ),
        }),
        ('ソケット装着 (v1.1+ 用)', {
            'fields': ('socket_1_crystal_type',
                       'socket_2_crystal_type',
                       'socket_3_crystal_type'),
            'description': (
                'v1.0 は None (未装着) が想定値、v1.1+ で結晶装着 UI 解禁時に活性化。<br>'
                '<strong>有効値</strong> (constants.py:CRYSTAL_TYPE_CHOICES 参照):<br>'
                '&nbsp;&nbsp;<code>exercise</code> — 運動の結晶<br>'
                '&nbsp;&nbsp;<code>learning</code> — 学習の結晶<br>'
                '&nbsp;&nbsp;<code>health</code> — 健康の結晶<br>'
                '&nbsp;&nbsp;<code>mental</code> — 精神の結晶<br>'
                '&nbsp;&nbsp;<code>creation</code> — 創造の結晶<br>'
                '&nbsp;&nbsp;<code>contribution</code> — 貢献の結晶<br>'
                '武器の socket_count 以下の数だけ有効 (超過分は無視)。'
            ),
            'classes': ('collapse',),
        }),
        ('記録', {
            'fields': ('acquired_at',),
            'classes': ('collapse',),
        }),
    )

    def save_model(self, request, obj, form, change):
        """【FEAT-538 (2026-08-29)】1 プレイヤー 1 装備に収束させる。

        🔴 `is_equipped` には **DB 制約が無い**。守っていたのは
        `EquipWeaponView` の手続きだけで、admin はそこを通らない。
        しかも model default が **True** なので、補償対応で武器を 1 本
        追加しただけで 2 本装備が成立する。

        `list_editable` の一括保存でも `save_model` は 1 件ずつ呼ばれるため、
        ここ 1 箇所で詳細画面 / 一覧 / 追加画面の 3 経路すべてを覆える
        (`CharacterStatAdmin.save_model` が同じ前提で動いている)。
        """
        super().save_model(request, obj, form, change)

        # 外す操作では何も昇格させない。不変条件は「常に 1 本」ではなく
        # 「**多くとも 1 本**」で、0 本は正当な状態。
        if not obj.is_equipped:
            return

        demoted = equip_exclusively(obj.player, obj)

        # ⚠️ 収束したことを必ず伝える。同一 POST で 2 行を True にした場合は
        # 後勝ちで 1 本に収束するので、黙っていると「チェックしたのに外れて
        # いる」ように見える。
        if demoted:
            self.message_user(
                request,
                '「{player}」の装備を「{equipped}」1 本に収束させました'
                '（外した武器: {demoted}）。'
                '1 人 1 装備が前提のため、他の装備は自動で外れます。'.format(
                    player=obj.player.name,
                    equipped=obj.weapon.name,
                    demoted='・'.join(w.weapon.name for w in demoted),
                ),
                messages.WARNING,
            )
        else:
            self.message_user(
                request,
                '「{player}」の装備は「{equipped}」1 本です。'.format(
                    player=obj.player.name,
                    equipped=obj.weapon.name,
                ),
                messages.INFO,
            )


# 【2026-07-09】プレイヤー経済状態 (coin / diamond) admin。
#
# FEAT-478 Phase 2 の PlayerProfile 4 分割で diamonds / bonus_coins 等の経済系
# field が PlayerEconomyState に切り出されたが、admin 側の追従が漏れていたため
# admin 画面から残高確認できない状態だった。本 admin で:
#   1. list 画面で全ユーザーの残高を概観 (top N 把握 / モニタリング)
#   2. 個別ユーザーの残高を直接編集 (support 補償対応)
# を可能にする。
#
# has_delete_permission=False: PlayerProfile と OneToOne(primary_key=True) で
# 紐付き、admin から削除すると次のアクセス時に property.get_or_create() で
# 空 state が新規生成される (= diamonds_total / coins_spent の累計履歴が消失)
# ため禁止。
@admin.register(PlayerEconomyState)
class PlayerEconomyStateAdmin(NoDeleteAdminMixin, admin.ModelAdmin):
    list_display = (
        'player', 'diamonds', 'diamonds_total',
        'bonus_coins', 'coins_spent',
        'character_exchange_tickets',
        'streak_protection_count',
    )
    search_fields = (
        'player__name', 'player__friend_id', 'player__user__email',
    )
    autocomplete_fields = ('player',)
    # 【運用】残高系 3 field は list 一覧から即編集可 (補償対応の頻度が高い field)。
    # 累計 (diamonds_total / coins_spent) は誤操作抑止のため list_editable 対象外、
    # 変更したい場合は詳細画面 (change_view) から明示的に触る。
    list_editable = ('diamonds', 'bonus_coins', 'character_exchange_tickets')
    ordering = ('-diamonds',)
    save_on_top = True

    fieldsets = (
        ('プレイヤー', {
            'fields': ('player',),
        }),
        ('残高 (現在値、補償対応で直接編集可)', {
            'fields': ('diamonds', 'bonus_coins', 'character_exchange_tickets'),
            'description': (
                '<strong>補償対応 (support)</strong> の際は本セクションを直接編集して即時反映できる。<br>'
                '<strong>diamonds</strong> = 現在ダイヤ残高 (IAP 購入 / gacha 排出 / ログイン報酬)。<br>'
                '<strong>bonus_coins</strong> = 現在コイン残高 (クエスト報酬 / バトル勝利)。<br>'
                '<strong>character_exchange_tickets</strong> = キャラ交換券 (11 連目確定枠等)。'
            ),
        }),
        ('累計 / 統計 (通常は触らない)', {
            'fields': ('diamonds_total', 'coins_spent', 'diamond_bonus_date'),
            'description': (
                '<strong>diamonds_total</strong> = 総取得ダイヤ累計 (leaderboard / milestone 集計用)。<br>'
                '<strong>coins_spent</strong> = Shop 消費コイン累計 (集計用)。<br>'
                '<strong>diamond_bonus_date</strong> = 最終ダイヤボーナス日付 (連続ログイン管理)。<br>'
                '<em>補償で diamonds を増やした場合、統計整合のため diamonds_total も同額増やすかは運用判断。</em>'
            ),
            'classes': ('collapse',),
        }),
        ('ストリーク保護 (在庫 / 自動発動 flag)', {
            'fields': (
                'streak_protection_count',
                'streak_protection_auto_enabled',
                'streak_protection_pending',
                'last_streak_protection_used_at',
            ),
            'classes': ('collapse',),
        }),
        ('XP boost', {
            'fields': ('xp_boost_active_until',),
            'description': 'XP boost item の有効期限。null = 未使用。',
            'classes': ('collapse',),
        }),
    )


@admin.register(PlayerItem)
class PlayerItemAdmin(admin.ModelAdmin):
    """プレイヤー所持アイテム (per-player) の admin 編集画面。

    運営が特定 user にアイテムを付与 (補償対応 / テスト用配布)、数量調整、削除を
    GUI から実施できる。
    """
    list_display        = ('id', 'player', 'item_id', 'quantity', 'purchased_at')
    list_filter         = ('item_id',)
    list_editable       = ('quantity',)
    search_fields       = ('player__name', 'player__friend_id', 'item_id')
    autocomplete_fields = ('player',)
    date_hierarchy      = 'purchased_at'
    readonly_fields     = ('purchased_at',)
    save_on_top         = True

    fieldsets = (
        ('所有者・アイテム', {
            'fields': ('player', 'item_id'),
            'description': (
                '<strong>item_id</strong> は Shop / Battle / Gacha で扱う string ID '
                '(unique_together (player, item_id) 制約あり、同じ item_id を 2 行作れない)。<br>'
                '<strong>主要 item_id (SHOP_CATALOG より抜粋)</strong>:<br>'
                '&nbsp;&nbsp;<code>recovery_potion</code> — 回復薬 💊 (max_stock=99)<br>'
                '&nbsp;&nbsp;<code>recovery_potion_plus</code> — 上位回復薬 💊 (max_stock=10)<br>'
                '&nbsp;&nbsp;<code>attack_potion</code> — 攻撃の薬 ⚔️ (max_stock=10)<br>'
                '&nbsp;&nbsp;<code>defense_potion</code> — 防御の薬 🛡️ (max_stock=10)<br>'
                '&nbsp;&nbsp;<code>rest_fruit</code> — 休息の果実 🍎 (max_stock=99)<br>'
                '&nbsp;&nbsp;<code>xp_boost_1.5x</code> — XP ブースト 🚀 (ガチャ排出、上限なし)<br>'
                '<code>ticket_daily</code> / <code>ticket_weekly</code> はチケット交換のため '
                'PlayerItem には保存されない (PlayerGachaStatus.*_tickets 直接加算する経路)。'
            ),
        }),
        ('数量', {
            'fields': ('quantity',),
            'description': (
                '各 item_id の推奨 max_stock は <code>shop.py:SHOP_CATALOG</code> 参照。<br>'
                'admin から max_stock を超える値も設定可能 (アプリ側 UI が壊れない範囲で運用)。'
            ),
        }),
        ('記録', {
            'fields': ('purchased_at',),
            'classes': ('collapse',),
        }),
    )


# ──────────────────────────────────────────────────────────────────────────────
# 【2026-07-09 Phase A】state 3 種 (Battle / Streak / Settings) 単体 admin
# ──────────────────────────────────────────────────────────────────────────────
# PlayerProfile 詳細画面の inline に加え、単体 admin (list + detail) も提供。
# 用途:
#   - list_editable で複数ユーザーを一気に補償 (例: 全 tester に battle_charges +9)
#   - list_filter で「login_streak_days >= 30」等の条件抽出
#   - 単体 URL 直接アクセスで operational script との連携
# has_delete_permission=False で OneToOne(primary_key) の履歴消失を構造防止。


@admin.register(PlayerBattleState)
class PlayerBattleStateAdmin(NoDeleteAdminMixin, admin.ModelAdmin):
    list_display = (
        'player', 'level', 'current_exp', 'max_exp',
        'allocatable_points', 'battle_charges', 'daily_battle_count',
    )
    search_fields = (
        'player__name', 'player__friend_id', 'player__user__email',
    )
    autocomplete_fields = ('player',)
    list_editable = ('level', 'current_exp', 'battle_charges')
    ordering = ('-level', '-current_exp')
    save_on_top = True
    # 【FEAT-538 (2026-08-29)】max_exp は level から自動再計算 (下記 save_model)。
    # ⚠️ read-only の列を list_editable に入れると admin.E121 で
    #    `manage.py check` が落ち、build.sh の migrate が止まる (EnemyAdmin に前例)。
    readonly_fields = ('max_exp',)


    fieldsets = (
        ('プレイヤー', {'fields': ('player',)}),
        ('レベル / EXP (support 補償で直接編集可)', {
            'fields': ('level', 'current_exp', 'max_exp', 'allocatable_points'),
            'description': (
                'レベルダウン救済 / EXP 補償 / ステ振り追加ポイント配布。<br>'
                '<em>max_exp は readonly。level を save すると '
                '<code>level_to_max_exp(level)</code> から自動で追従する '
                '(FEAT-538)。</em><br>'
                '<em>current_exp は自動調整しない (補償で入れた EXP を尊重する)。</em>'
            ),
        }),
        ('バトルチャージ / 日次スロットル', {
            'fields': (
                'battle_charges', 'battle_charges_date',
                'daily_battle_count', 'daily_battle_count_date',
                'daily_exp_count', 'daily_exp_count_date',
            ),
            'classes': ('collapse',),
        }),
        ('クエスト枠拡張 (FEAT-429 累進価格)', {
            'fields': ('daily_battle_limit_bonus', 'daily_battle_limit_purchase_count'),
            'classes': ('collapse',),
        }),
    )

    def save_model(self, request, obj, form, change):
        """【FEAT-538 (2026-08-29)】level を触ったら max_exp を追従させる。

        `CharacterStat` 側は 2026-07-09 に同じ 3 点セットで解決済みだったが、
        **プレイヤー Lv 側だけ「人間が手で合わせること」という注意書きのまま**
        残っていた。max_exp が `level_to_max_exp(level)` から乖離すると、
        次の EXP 加算でレベルアップ判定の while が意図しない回数まわる
        (`services/exp_service.py` に同じ警告がある)。

        `list_editable` / 詳細編集の両経路がここを通る。inline 経由だけは
        通らないので `PlayerProfileAdmin.save_formset` に同じ処理がある。

        ⚠️ current_exp は触らない (補償で入れた EXP を黙って削らない)。
        """
        obj.max_exp = GameBalance.level_to_max_exp(obj.level)
        super().save_model(request, obj, form, change)


@admin.register(PlayerStreakState)
class PlayerStreakStateAdmin(NoDeleteAdminMixin, admin.ModelAdmin):
    # 【FEAT-539 (2026-09-05)】`login_streak_days` は FEAT-331 から本 FEAT まで
    # **本番コードが一度も更新していなかった**。それでもこの列で並べ替えができたので、
    # 運営から見ると「全員 0 の列で並べている」状態だった (指示書 §2)。
    # 本 FEAT で発火点が書くようになったので、この列は実データになった。
    list_display = (
        'player', 'login_streak_days', 'best_task_streak_days',
        'last_login_diamond_at', 'daily_task_count', 'last_battle_diamond_at',
    )
    search_fields = (
        'player__name', 'player__friend_id', 'player__user__email',
    )
    autocomplete_fields = ('player',)
    list_editable = ('login_streak_days',)
    ordering = ('-login_streak_days',)
    save_on_top = True

    fieldsets = (
        ('プレイヤー', {'fields': ('player',)}),
        ('最終アクティブ (FEAT-540)', {
            'fields': ('last_achievement_check_at',),
            'description': (
                'support が最初に見る値。**「まだ使っているか」**を測っている。<br>'
                '🔴 <strong>「ログイン」ではない。</strong> DRF の Token 認証は '
                '<code>User.last_login</code> を更新しないので、'
                'Django 既定の User 画面に出ている「最終ログイン」は'
                '<strong>全員 なし</strong>である (FEAT-540 §1)。<br>'
                '更新経路は 3 つ: 習慣 / ToDo のカウント、チェックリストのチェック、'
                '実績画面を開いたとき (60 秒スロットル)。<br>'
                '⚠️ <strong>タイムライン予定の完了だけでは動かない。</strong>'
                'タイムラインしか使っていないユーザーは休眠に見えるので、'
                '判断する前に <code>DailyAchievement</code> (日次達成記録) も見ること。'
            ),
        }),
        ('連続達成 (FEAT-539)', {
            'fields': (
                'login_streak_days', 'best_task_streak_days', 'last_login_diamond_at',
            ),
            'description': (
                '🔴 <strong>login_streak_days / best_task_streak_days は キャッシュ であり、'
                '真実値ではありません</strong>。真実値は <code>DailyAchievement</code> の行です '
                '(FEAT-539)。<br>'
                'ここを手で書き換えると <code>manage.py check_daily_achievement_consistency</code> '
                'が不一致として報告し、<code>--fix</code> で<strong>行の値に戻されます</strong>。<br>'
                '救済で連続日数を伸ばしたい場合は、キャッシュではなく '
                '<code>DailyAchievement</code> の行を足してください。<br>'
                '⚠️ <strong>last_login_diamond_at は「ログイン」で動きません。</strong>'
                '<strong>その日の初回タスク達成</strong>で更新される冪等性キーです '
                '(BUG-122 が発火条件を変えた際、名前だけ据え置かれた)。<br>'
                '今日の日付をここに書くと、本日は追加付与されません。<br>'
                '🔵 改名しないのは <code>diamond_service.py</code> が'
                '冪等性キーとして依存しているためです。<strong>名前ではなく説明で解いています。</strong>'
            ),
        }),
        ('ダイヤ付与冪等性', {
            'fields': ('last_battle_diamond_at', 'last_streak_diamond_day'),
            'classes': ('collapse',),
        }),
        ('日次カウンタ / popup 判定', {
            'fields': (
                'daily_task_count', 'daily_task_count_date',
                'last_friend_gift_popup_date',
            ),
            'classes': ('collapse',),
        }),
        ('パズル世界 (FEAT-479)', {
            'fields': ('last_task_piece_date', 'last_quest_piece_date'),
            'classes': ('collapse',),
        }),
    )


@admin.register(PlayerSettings)
class PlayerSettingsAdmin(NoDeleteAdminMixin, admin.ModelAdmin):
    list_display = (
        'player', 'mode', 'all_private',
        'reminder_enabled', 'reminder_time',
        'gcal_push_enabled',
    )
    list_filter = ('mode', 'all_private', 'reminder_enabled', 'gcal_push_enabled')
    search_fields = (
        'player__name', 'player__friend_id', 'player__user__email',
    )
    autocomplete_fields = ('player',)
    # 【運用】頻繁に触るのは reminder_enabled / all_private の 2 flag。
    # mode / week_start_day は挙動影響大なので detail 画面での明示編集を強制。
    list_editable = ('reminder_enabled', 'all_private')
    readonly_fields = ('fcm_token',)
    save_on_top = True

    fieldsets = (
        ('プレイヤー', {'fields': ('player',)}),
        ('プライバシー / モード', {
            'fields': ('all_private', 'mode'),
        }),
        ('言語設定 (FEAT-489 Phase 4)', {
            'fields': ('preferred_language',),
            'description': 'preferred_language: ja=日本語 / en=English。Mobile の PATCH /api/player/ で設定可。',
        }),
        ('通知', {
            'fields': ('reminder_enabled', 'reminder_time', 'fcm_token'),
            'description': (
                '<strong>fcm_token</strong> は Mobile 自動更新値、admin から編集禁止 (readonly)。'
            ),
        }),
        ('リセットタイミング', {
            'fields': ('week_start_day', 'month_reset_day'),
            'classes': ('collapse',),
        }),
        ('Google カレンダー連動 (FEAT-257/263/273)', {
            'fields': (
                'gcal_push_enabled',
                'timeline_uncompleted_reminder_enabled',
            ),
            'classes': ('collapse',),
        }),
    )


# ──────────────────────────────────────────────────────────────────────────────
# 【2026-07-09 Phase A】IAP 領収書 (RevenueCat) view-only admin
# ──────────────────────────────────────────────────────────────────────────────
# 課金トラブル対応 (「買ったのにダイヤが反映されない」) / 返金対応 / 会計監査で使う。
# 改ざん防止のため view のみ (add / change / delete 全禁止):
#   - webhook 経由でのみ作成される (RevenueCatWebhookView)
#   - 領収書の内容変更は監査整合を壊すため禁止
#   - 削除は会計監査で追跡不能になるため禁止
@admin.register(IAPReceipt)
class IAPReceiptAdmin(ReadOnlyAdminMixin, admin.ModelAdmin):
    list_display = (
        'created_at', 'player', 'event_type', 'product_id',
        'store', 'status', 'granted_diamonds',
    )
    list_filter = ('status', 'event_type', 'store')
    search_fields = (
        'event_id', 'transaction_id', 'product_id', 'app_user_id',
        'player__name', 'player__friend_id', 'player__user__email',
    )
    autocomplete_fields = ('player',)
    date_hierarchy = 'created_at'
    ordering = ('-created_at',)
    # 全 field readonly (view-only + save button 非表示)
    readonly_fields = (
        'player', 'event_id', 'event_type', 'product_id', 'transaction_id',
        'store', 'app_user_id', 'status', 'granted_diamonds', 'raw_payload',
        'error_message', 'created_at', 'processed_at',
    )

    fieldsets = (
        ('プレイヤー / 商品', {
            'fields': ('player', 'app_user_id', 'product_id', 'store'),
        }),
        ('冪等性キー / トランザクション', {
            'fields': ('event_id', 'event_type', 'transaction_id'),
        }),
        ('処理状態', {
            'fields': ('status', 'granted_diamonds', 'error_message'),
        }),
        ('タイムスタンプ', {
            'fields': ('created_at', 'processed_at'),
        }),
        ('生ペイロード (デバッグ / ベンダーロックイン fallback)', {
            'fields': ('raw_payload',),
            'classes': ('collapse',),
        }),
    )


# ──────────────────────────────────────────────────────────────────────────────
# 【2026-07-09 Phase A】退会理由フィードバック view-only admin
# ──────────────────────────────────────────────────────────────────────────────
# 退会理由の集計・プロダクト改善指標 (CSAT / churn 分析)。個人特定は player_id のみ
# 保持 (プロファイル本体は削除済のため、id からユーザーを引く手段は消失)。
@admin.register(AccountDeletionFeedback)
class AccountDeletionFeedbackAdmin(ReadOnlyAdminMixin, admin.ModelAdmin):
    list_display = (
        'created_at', 'player_id', 'player_level',
        'reason', 'reason_text_short', 'app_version',
    )
    list_filter = ('reason', 'app_version')
    date_hierarchy = 'created_at'
    ordering = ('-created_at',)
    readonly_fields = (
        'player_id', 'player_level', 'reason',
        'reason_text', 'app_version', 'created_at',
    )

    fieldsets = (
        ('退会情報', {
            'fields': ('created_at', 'player_id', 'player_level', 'app_version'),
        }),
        ('退会理由', {
            'fields': ('reason', 'reason_text'),
        }),
    )

    @admin.display(description='理由 (詳細)', ordering='reason_text')
    def reason_text_short(self, obj):
        text = obj.reason_text or ''
        if len(text) <= 50:
            return text
        return f'{text[:50]}…'


# ──────────────────────────────────────────────────────────────────────────────
# 【2026-07-09 Phase B】敵マスタ (Enemy) admin
# ──────────────────────────────────────────────────────────────────────────────
# ゲームバランス調整 (HP / attack / reward の即時反映) を admin から実施可能に。
# Backend で `Enemy.objects.get(key=...)` を都度取得する設計のため、admin 変更は
# デプロイなしで全ユーザーに反映される (Mobile 側にハードコード無し、safe)。
@admin.register(Enemy)
class EnemyAdmin(admin.ModelAdmin):
    list_display = (
        'key', 'name', 'tier', 'unlock_level',
        'base_hp', 'base_atk', 'base_spd', 'level_scaling',
        # 【FEAT-521 Phase 1】想定撃数 2 列 (read-only の計算列)。
        # list_editable には入れない — read-only 列を入れると admin.E121 で
        # `manage.py check` が落ち、build.sh の migrate が失敗してデプロイが止まる。
        'expected_hits_baseline', 'expected_hits_physical',
        'reward_coins', 'reward_exp',
        'physical_resistance', 'magical_resistance', 'weak_ult_cost',
    )
    list_filter   = ('tier',)
    # 【運用】balance 調整で頻繁に触る 6 field を list 一覧から即編集可
    list_editable = (
        'base_hp', 'base_atk', 'reward_coins', 'reward_exp',
        'physical_resistance', 'magical_resistance',
    )
    search_fields = ('key', 'name')
    ordering      = ('tier', 'unlock_level', 'key')
    save_on_top   = True

    # ── 【FEAT-521 Phase 1】想定撃数の可視化 ──────────────────────────────
    #
    # バランス目標は「unlock_level で決められたレンジ内の撃数で倒せる」だが、
    # admin に撃数が出ないため `base_hp` を 1 つ触るたびに手計算になっていた。
    # レンジの現行値は下の _TARGET_HITS_MIN / _TARGET_HITS_MAX (§6.3 PM 判断)。
    #
    # 【基準プレイヤーモデル】
    # Flutter の `BattleDisplay.computeAtk(level, weaponAtk, studyLv,
    # attackPowerModifier)` (`battle_constants.dart`) に
    #   weaponAtk = 10 (starter_sword) / studyLv = 0 / attackPowerModifier = 1.0
    # を入れて **1 つの仮定に畳んだ結果**が下の式である。
    # Dart の式全体を移植したものではないので、汎用化しないこと。
    #
    #     基準 ATK(Lv) = 20 + Lv × 2
    #
    # `test_enemy_balance_v400.py` に記録された全 12 体の撃数コメントと一致する
    # (slime 5.9 / goblin 5.0 / armored_knight 5.7 / griffin 6.7 …)。
    #
    # 【drift 防止】Dart 側の係数が変わると本モデルは黙って嘘になる。
    # `mobile/test/battle/battle_display_formula_contract_test.dart` が
    # `computeAtk` の形を縛り、変更時に本ファイルを名指しで落とす。
    #
    # 【FEAT-535 (2026-08-29)】式の実体は
    # `services/battle_stats_preview.baseline_atk_for_enemy_table` へ移した。
    # per-player 版 (`compute_player_battle_stats`) と**同じモジュール**に置くことで、
    # 片方だけ直される事故を減らす。ここは呼ぶだけ。

    # 【FEAT-521 §6.3 PM 判断 (2026-08-07)】目標レンジは **5.0-7.0**。
    #
    # 実装当初は FEAT-400 v3 の文書記述 5.0-6.0 を使っていたが、こちらは
    # **CI で縛られていない**。実際に縛っているのは FEAT-401 の
    # `test_enemy_roster_v401.py` の 4.0 ≤ hits ≤ 7.0 で、縛られている方を基準に
    # 採る判断になった。下限は実測で 5.0 未満が 0 体のため 4.0 ではなく 5.0。
    # 真実値は doc/instructions/FEAT-521_enemy_balance_tuning_ops.md §6.3。
    _TARGET_HITS_MIN = 5.0
    _TARGET_HITS_MAX = 7.0

    @staticmethod
    def _baseline_atk(level: int) -> int:
        """基準プレイヤー (初期装備 / stat 未成長 / ジョブ修飾なし) の ATK。

        🔴 **per-player の表示に流用しないこと。** 3 つの仮定を畳んだ簡約式である。
        個票は `PlayerProfileAdmin.battle_stats_preview` (別式) が担当する。
        """
        return baseline_atk_for_enemy_table(level)

    @admin.display(description='想定撃数 (基準/耐性なし)')
    def expected_hits_baseline(self, obj):
        """`base_hp ÷ 基準 ATK(unlock_level)`。**耐性を含まない**。

        目標レンジ (_TARGET_HITS_MIN 〜 _TARGET_HITS_MAX) と直接比較できる数字。
        `unlock_level == 0` (常時解禁) は Lv.1 で計算し、その旨を併記する。
        """
        return self._render_hits(obj, resistance=1.0)

    @admin.display(description='物理職 実効 (耐性込)')
    def expected_hits_physical(self, obj):
        """`base_hp ÷ (基準 ATK × physical_resistance)`。**耐性を含む**。

        `physical_resistance == 1.0` の敵では基準列と一致するので、
        **耐性持ちの敵だけ差が出て目に付く**。
        armored_knight (0.7) は基準 5.7 撃に対し物理職の実効は 8.2 撃で、
        「5.7 だからちょうどいい」と据え置くのは誤判断になる。
        """
        return self._render_hits(obj, resistance=obj.physical_resistance)

    def _render_hits(self, obj, *, resistance: float):
        """撃数を整形して返す。目標レンジ (§6.3 PM 判断 = 5.0-7.0) を外れたら色を付ける。"""
        atk = self._baseline_atk(obj.unlock_level) * (resistance or 1.0)
        if atk <= 0 or not obj.base_hp:
            return '—'
        hits = obj.base_hp / atk
        suffix = ' (Lv.1)' if obj.unlock_level == 0 else ''
        in_range = self._TARGET_HITS_MIN <= hits <= self._TARGET_HITS_MAX
        color = '#000000' if in_range else '#b34700'
        return format_html(
            '<span style="color:{}">{}{}</span>',
            color, f'{hits:.1f}', suffix,
        )

    fieldsets = (
        ('基本情報', {
            'fields': ('key', 'name', 'name_en', 'sprite_key', 'tier', 'unlock_level'),
            'description': (
                '<strong>key</strong>: 識別子 (例: <code>goblin</code>)、'
                'Mobile ↔ Backend で共通。<strong>変更禁止</strong> '
                '(既存 Battle / GachaHistory が参照)。<br>'
                '<strong>sprite_key</strong>: Mobile 側 <code>assets/images/battle/&lt;key&gt;.png</code> の識別子。<br>'
                '<strong>tier</strong>: zako / mid_boss / boss / hidden_boss。<br>'
                '<strong>unlock_level</strong>: プレイヤーレベル解禁閾値 '
                '(0=常時解禁 / 15=mid_boss / 25=boss / 35=hidden_boss、FEAT-302)。<br>'
                '<strong>name_en</strong>: 英語版表示名 (空欄 = ja にフォールバック、FEAT-489 Phase 4)。'
            ),
        }),
        ('ステータス (balance 調整で直接編集可)', {
            'fields': ('base_hp', 'base_atk', 'base_spd', 'level_scaling'),
            'description': (
                # 【2026-08-06 訂正】旧説明「base_hp / base_atk / base_spd は Lv.1 基準値、
                # level_scaling で player.level に応じて自動増加 (1.0=等倍 / 1.5=+50%)」は
                # **3 点とも実装と食い違っていた**。本 admin 追加 (2026-07-09) の時点で
                # 既に FEAT-400 v3 (2026-05-31) の HP 固定化が入っており、初出から誤り。
                #
                # 【FEAT-522 (2026-08-07) 再訂正】ATK も Lv 連動をやめ「設定値 = 実ダメージ」
                # にしたため、上記訂正で書いた
                # 「Lv 連動するのは base_atk だけ」「1.0 は等倍ではない」の 2 点が今度は
                # 古くなった。**式を変えたら同じコミットでここも直すこと** (この欄は
                # 2 度乖離している)。真実値: views/battle/start.py `scaled_hp` / `scaled_atk`。
                '<strong>入力した数字が、そのまま戦闘中の値になります。</strong><br><br>'
                '<code>base_hp</code>: 戦闘中 HP に<strong>そのまま</strong>使われます。'
                'プレイヤー Lv では増えません '
                '(FEAT-400 v3 で HP 固定化。Player が育つほど撃数が減る設計)。<br>'
                '<code>base_atk</code>: <strong>1 発のダメージそのもの</strong>です。'
                '37 と入れれば 37 ダメージ。プレイヤー Lv では増えません '
                '(FEAT-522)。<br>'
                '<code>base_spd</code>: ATB 充填速度。<strong>Lv 連動しません</strong>。<br>'
                '<code>level_scaling</code>: <strong>0 = 固定</strong> '
                '(推奨・全 24 体の既定)。'
                '0 より大きい値を入れると、<strong>その敵だけ</strong> '
                '<code>unlock_level</code> 以降に緩やかに追随します。'
                '<br><br>'
                '正確な式は '
                '<code>base_atk × (1 + level_scaling × (プレイヤー Lv − unlock_level))</code> '
                'で、<code>unlock_level</code> より下では 1 倍に固定されます。'
                'つまり <code>level_scaling</code> が 0 でなくても'
                '「<strong>解禁時のダメージ = 設定値</strong>」は常に成立します。'
                '<br><br>'
                'バランス目標は「<strong>unlock_level で 5.0-7.0 撃で倒せる</strong>」'
                '(FEAT-521 §6.3 の PM 判断。CI で縛られている FEAT-401 の'
                ' 4.0-7.0 を基準に採り、実測で 5.0 未満が 0 体のため下限を 5.0 に寄せた)。'
                'base_hp を変えたら、この目標からずれていないか確認してください。'
                '<br><br>'
                # 【FEAT-521 Phase 1】一覧画面では description が見えないため、
                # 前提は列名 (「基準/耐性なし」「耐性込」) にも入れてある。
                # ここは「なぜその数字なのか」を読める唯一の場所。
                '<strong>一覧の「想定撃数」列について</strong><br>'
                '<code>base_hp ÷ (20 + unlock_level × 2)</code> で計算しています。'
                'この分母は <strong>基準プレイヤー</strong>の攻撃力で、'
                '次の 4 点を仮定しています:'
                '<ul>'
                '<li><strong>初期装備</strong> (starter_sword、atk_bonus = 10)</li>'
                '<li><strong>ステータス未成長</strong> (学習力 Lv.0)</li>'
                '<li><strong>ジョブ修飾なし</strong> (attackPowerModifier = 1.0)</li>'
                '<li><strong>耐性なし</strong> — 「基準」列は '
                '<code>physical_resistance</code> / <code>magical_resistance</code> '
                'を<strong>含みません</strong></li>'
                '</ul>'
                '「基準」列が上の目標レンジと直接比較できる数字です。'
                '隣の「<strong>物理職 実効</strong>」列は '
                '<code>physical_resistance</code> を掛けた実際の手応えで、'
                '耐性 1.0 の敵では基準列と同じ値になります。'
                '<br><br>'
                '⚠ 例: <code>armored_knight</code> は '
                '<code>physical_resistance = 0.7</code> なので、'
                '基準 <strong>5.7 撃</strong>に対し物理職の実効は '
                '<strong>8.2 撃</strong>です。'
                '基準列だけを見て「ちょうどいい」と据え置くのと、'
                '実効を見て HP を下げるのとでは真逆の調整になります。'
                '<br>'
                '耐性は「ジョブを切り替えさせる仕掛け」(FEAT-302) なので、'
                '差が出ていること自体はバグではありません。'
                '<br><br>'
                '目標レンジ (5.0-7.0) を外れた値は<span style="color:#b34700">'
                'この色</span>で表示されます。'
            ),
        }),
        ('報酬 (balance 調整で直接編集可)', {
            'fields': ('reward_coins', 'reward_exp'),
            'description': (
                '勝利時のドロップ量。BattleStartView が本値を Mobile に渡すため、'
                '変更は次回バトルから即座に反映される (デプロイ不要)。'
            ),
        }),
        ('弱点 / 耐性 (FEAT-302)', {
            'fields': (
                'physical_resistance', 'magical_resistance', 'weak_ult_cost',
            ),
            'description': (
                'physical_resistance / magical_resistance: 1.0=等倍 / 0.7=30%軽減 / 1.3=30%増幅。<br>'
                'weak_ult_cost: null=弱点なし / 4 で thief (ultCost=4) 限定で +30% ダメージ。'
            ),
            'classes': ('collapse',),
        }),
        ('背景画像 (FEAT-381)', {
            'fields': ('background_image_path',),
            'classes': ('collapse',),
        }),
    )


# ──────────────────────────────────────────────────────────────────────────────
# 【2026-07-09 Phase B】社交機能 (Friendship / Message / Notification) admin
# ──────────────────────────────────────────────────────────────────────────────
# 通報対応 (不適切なメッセージ削除 / フレンド関係解除) / 「通知届いてない」問い合わせ
# 対応で使う。改ざんによる悪用防止のため change_permission は原則禁止:
#   - Friendship: status 変更のみ可 (approved → pending 巻き戻し等)、bulk delete 禁止
#     add 禁止: 通常は Mobile 経由でのみ作成、admin 手動追加は誤操作リスクが大きい
#   - Message: 内容変更禁止、個別 delete のみ許可 (bulk delete 禁止で誤操作抑止)
#   - Notification: 内容変更禁止、個別 delete のみ許可 (Backend が生成、admin add 不可)
@admin.register(Friendship)
class FriendshipAdmin(NoAddAdminMixin, NoBulkDeleteAdminMixin, admin.ModelAdmin):
    list_display  = ('from_player', 'to_player', 'status', 'created_at')
    list_filter   = ('status',)
    search_fields = (
        'from_player__name', 'from_player__friend_id',
        'to_player__name', 'to_player__friend_id',
    )
    autocomplete_fields = ('from_player', 'to_player')
    date_hierarchy = 'created_at'
    ordering       = ('-created_at',)
    readonly_fields = ('created_at',)

    fieldsets = (
        ('関係', {
            'fields': ('from_player', 'to_player', 'status', 'created_at'),
            'description': (
                'status = pending (申請中) / accepted (承認済み)。<br>'
                '通報対応で関係解消したい場合は個別 delete (bulk delete は誤操作抑止で禁止)。'
            ),
        }),
    )


@admin.register(Message)
class MessageAdmin(NoAddAdminMixin, NoChangeAdminMixin,
                   NoBulkDeleteAdminMixin, admin.ModelAdmin):
    list_display  = ('created_at', 'sender', 'receiver', 'content_short')
    search_fields = (
        'sender__name', 'sender__friend_id',
        'receiver__name', 'receiver__friend_id',
        'content',
    )
    autocomplete_fields = ('sender', 'receiver')
    date_hierarchy = 'created_at'
    ordering       = ('-created_at',)
    readonly_fields = ('sender', 'receiver', 'content', 'created_at')

    @admin.display(description='内容 (先頭 30 文字)', ordering='content')
    def content_short(self, obj):
        content = obj.content or ''
        if len(content) <= 30:
            return content
        return f'{content[:30]}…'

    def has_delete_permission(self, request, obj=None):
        return True  # 通報対応で個別 delete 可 (bulk は mixin が遮断)


@admin.register(Notification)
class NotificationAdmin(NoAddAdminMixin, NoChangeAdminMixin,
                        NoBulkDeleteAdminMixin, admin.ModelAdmin):
    list_display   = ('created_at', 'player', 'notif_type', 'title',
                      'is_read', 'related_id')
    list_filter    = ('notif_type', 'is_read')
    search_fields  = (
        'player__name', 'player__friend_id', 'title', 'body',
    )
    autocomplete_fields = ('player',)
    date_hierarchy = 'created_at'
    ordering       = ('-created_at',)
    readonly_fields = (
        'player', 'notif_type', 'title', 'body', 'related_id',
        'is_read', 'created_at',
    )

    def has_delete_permission(self, request, obj=None):
        # 不適切な通知や運用ミスで生成された通知の個別削除は許可
        # (bulk delete は NoBulkDeleteAdminMixin が遮断)
        return True


# ──────────────────────────────────────────────────────────────────────────────
# 【2026-07-09 Phase B】所持キャラ (OwnedCharacter) admin
# ──────────────────────────────────────────────────────────────────────────────
# support 補償対応で「ガチャで引いたのに一覧に出ない」問い合わせに個別付与。
# add 可 (補償配布) / delete 可 (誤付与取消) / change 不可。
#   change 禁止の理由: (player, character) の付替えは「別 user への譲渡」に相当する。
#   取り消したい場合は delete → 再 add で表現すること。
@admin.register(OwnedCharacter)
class OwnedCharacterAdmin(NoChangeAdminMixin, admin.ModelAdmin):
    list_display        = ('id', 'player', 'character', 'purchased_at')
    list_filter         = ('character',)
    search_fields       = (
        'player__name', 'player__friend_id',
        'character__key', 'character__name',
    )
    autocomplete_fields = ('player', 'character')
    date_hierarchy      = 'purchased_at'
    readonly_fields     = ('purchased_at',)
    save_on_top         = True

    fieldsets = (
        ('所持関係', {
            'fields': ('player', 'character'),
            'description': (
                '<strong>unique_together</strong> (player, character) 制約あり、'
                '既に所持しているキャラの再付与は保存時にエラーになる。<br>'
                '補償対応で付与する場合は該当 player + character を選択して保存。'
            ),
        }),
        ('記録', {
            'fields': ('purchased_at',),
            'classes': ('collapse',),
        }),
    )


# ──────────────────────────────────────────────────────────────────────────────
# 【2026-07-09 Phase B】重複報酬待ち (PendingDuplicateReward) admin
# ──────────────────────────────────────────────────────────────────────────────
# 30 日期限の未交換 pending 一覧を運営がモニタリング。「引いたのに交換画面に
# 出ない」問い合わせや期限切れ寸前検知に使う。改ざん防止のため view-only
# (生成経路は Backend gacha のみ)。
@admin.register(PendingDuplicateReward)
class PendingDuplicateRewardAdmin(ReadOnlyAdminMixin, admin.ModelAdmin):
    list_display   = (
        'created_at', 'player', 'reward', 'status',
        'exchange_type', 'expires_at',
    )
    list_filter    = ('status', 'exchange_type')
    search_fields  = (
        'player__name', 'player__friend_id',
        'reward__name',
    )
    autocomplete_fields = ('player', 'reward')
    date_hierarchy = 'created_at'
    ordering       = ('-created_at',)
    readonly_fields = (
        'player', 'reward', 'status', 'exchange_type',
        'expires_at', 'created_at',
    )


# ──────────────────────────────────────────────────────────────────────────────
# 【2026-07-09】プレイヤーステータス pivot ビュー (PlayerStatsMatrix proxy)
# ──────────────────────────────────────────────────────────────────────────────
# 従来の CharacterStat admin は long-format (1 行 = 1 player × 1 stat) で
# プレイヤー数 × 6 行に膨張していた。本 admin は proxy model 経由で pivot table
# (1 行 = 1 プレイヤー、6 ステータス列 + 合計列) を提供、cross-player 比較と
# balance 傾向把握を可能にする。
#
# 個別 stat の CRUD は既存 CharacterStatAdmin (「ステータス個別編集」) に集約。
#
# 【2026-08-07 訂正】旧コメントは「view-only (has_add / has_change / has_delete
# = False)」と書いていたが、後日 CharacterStatInline を追加した際 (commit
# 83384d44) に change は許可へ変わっており、コメントだけが取り残されていた。
# 現在の実際の権限は **add / delete のみ禁止、change は許可** (inline から
# 6 stat を編集する動線がこの admin の主目的なので change は必須)。
# PlayerProfile 側 field は readonly_fields で個別に保護している。
#
# get_queryset: Subquery annotation で 6 stat level を各行に埋め込み、
#   1. N+1 回避 (通常 100 プレイヤーで 600 stat query → 1 SELECT + 6 Subquery)
#   2. 各 stat 列で ordering 可 (header クリックで「運動 Lv 高い順」等)
# の 2 効果を得る。
from django.db.models import IntegerField, OuterRef, Subquery


def _stat_subquery(stat_name: str) -> Subquery:
    """指定ステータス名の level を PlayerProfile 各行に annotate する Subquery。"""
    return Subquery(
        CharacterStat.objects.filter(
            player=OuterRef('pk'), name=stat_name,
        ).values('level')[:1],
        output_field=IntegerField(),
    )


# 【2026-07-09】プレイヤーステータス詳細画面での 6 stat inline 編集。
#
# support 補償対応「A さんの運動 Lv +5」の実手数を半減 (5-6 → 3 クリック):
#   1. プレイヤーステータス admin で A さん検索 → クリック
#   2. 詳細画面が開く → 6 stat の inline テーブル (name / level / current_exp / max_exp)
#   3. 該当セル編集 → Save
# 6 stat が同時 visible = 「補償のバランス判断」も同一画面で完結可能。
#
# 制約:
#   - extra=0: 空行追加しない (6 stat は PlayerProfile 作成時に seed 済想定)
#   - max_num=6: それ以上の追加禁止 (CATEGORY_STAT_MAP 定義の 6 種以外は不正)
#   - can_delete=False: unique_together (player, name) の穴を作らない
#   - readonly_fields=('name', 'max_exp'): 【2026-07-09 レビュー §2 P1 対応】
#       stat 名変更は unique 制約を破綻させるため禁止。
#       max_exp は履歴依存 (habits.py:156 の compound int() で積み上がる) で
#       level から公式暗算不可、support 手動編集で drift しないよう readonly。
#       level を編集すると PlayerStatsMatrixAdmin.save_formset で max_exp が自動再計算される。
class CharacterStatInline(admin.TabularInline):
    model               = CharacterStat
    extra               = 0
    max_num             = 6
    can_delete          = False
    fields              = ('name', 'level', 'current_exp', 'max_exp')
    readonly_fields     = ('name', 'max_exp')
    ordering            = ('name',)


@admin.register(PlayerStatsMatrix)
class PlayerStatsMatrixAdmin(NoAddAdminMixin, NoDeleteAdminMixin,
                             admin.ModelAdmin):
    # add / delete は PlayerProfileAdmin の役割なので本 admin 経由では禁止。
    list_display = (
        'name', 'friend_id',
        'stat_exercise', 'stat_learning', 'stat_health',
        'stat_mental', 'stat_creation', 'stat_contribution',
        'stat_total',
    )
    search_fields = ('name', 'friend_id', 'user__email')
    ordering = ('name',)
    list_per_page = 50
    # 【2026-07-09】詳細画面で 6 stat を inline 編集可能に。
    inlines = [CharacterStatInline]
    # 詳細画面の PlayerProfile 側 field は readonly (プロファイル編集は
    # PlayerProfileAdmin 側の役割、本 admin は「stat 編集専用画面」に純化)。
    readonly_fields = ('name', 'friend_id', 'user', 'gender', 'created_at')
    fieldsets = (
        ('プレイヤー情報 (readonly、編集は PlayerProfile admin で)', {
            'fields': ('name', 'friend_id', 'user', 'gender', 'created_at'),
        }),
    )

    def get_queryset(self, request):
        qs = super().get_queryset(request)
        return qs.annotate(
            _exercise    =_stat_subquery('運動力'),
            _learning    =_stat_subquery('学習力'),
            _health      =_stat_subquery('健康力'),
            _mental      =_stat_subquery('精神力'),
            _creation    =_stat_subquery('創造力'),
            _contribution=_stat_subquery('貢献力'),
        )

    def save_formset(self, request, form, formset, change):
        # 【2026-07-09 レビュー §2 P1 対応】CharacterStatInline 経由の save で
        # level が変更されたら max_exp を強制再計算 (compound int() 再現)。
        # readonly_fields で max_exp を触れない構造にしているため、
        # ここで level から必ず追従させる必要がある (=1 経路の構造ガード)。
        if formset.model is CharacterStat:
            instances = formset.save(commit=False)
            for instance in instances:
                instance.max_exp = stat_max_exp_at_level(instance.level)
                instance.save()
            for obj in formset.deleted_objects:
                obj.delete()
            formset.save_m2m()
        else:
            super().save_formset(request, form, formset, change)

    @admin.display(description='運動', ordering='_exercise')
    def stat_exercise(self, obj):
        return f'Lv.{obj._exercise or 1}'

    @admin.display(description='学習', ordering='_learning')
    def stat_learning(self, obj):
        return f'Lv.{obj._learning or 1}'

    @admin.display(description='健康', ordering='_health')
    def stat_health(self, obj):
        return f'Lv.{obj._health or 1}'

    @admin.display(description='精神', ordering='_mental')
    def stat_mental(self, obj):
        return f'Lv.{obj._mental or 1}'

    @admin.display(description='創造', ordering='_creation')
    def stat_creation(self, obj):
        return f'Lv.{obj._creation or 1}'

    @admin.display(description='貢献', ordering='_contribution')
    def stat_contribution(self, obj):
        return f'Lv.{obj._contribution or 1}'

    @admin.display(description='合計')
    def stat_total(self, obj):
        # 未初期化 stat (None) は default level=1 として扱う
        return sum([
            obj._exercise     or 1,
            obj._learning     or 1,
            obj._health       or 1,
            obj._mental       or 1,
            obj._creation     or 1,
            obj._contribution or 1,
        ])


# ──────────────────────────────────────────────────────────────────────────────
# 【FEAT-540 (2026-09-06)】User admin: `last_login` の誤情報を潰す
# ──────────────────────────────────────────────────────────────────────────────
#
# 🔴 **`User.last_login` はこのアプリでは一度も更新されない。**
# DRF の `TokenAuthentication` は `last_login` を触らず、
# `django.contrib.auth.login()` の呼び出しも api/ 配下に 0 件である。
# 更新するのは `user_logged_in` シグナルだけで、トークン認証はそこを通らない
# (実測 2026-09-05: User 3 件中、`last_login` が入っているのは 0 件)。
#
# それでも Django 既定の User admin は「最終ログイン: なし」を表示し続けるので、
# **運営は「このユーザーは一度もログインしていない」という嘘を見せられる**。
# FEAT-539 §2 の `login_streak_days` (誰も更新しないのに admin が実データの
# ように見せていた) とまったく同じ形である。
#
# 🔵 **表示から外すのではなく、理由を書く。** 外すと「なぜ無いのか」が
# 分からなくなり、**同じ疑問がまた出る** —— 今回まさにそれが起きた
# (ユーザー質問 2026-09-05「最終ログイン日時は表示されているか？」)。
# **嘘を消すより、嘘である理由を書くほうが情報が増える。**
_LAST_LOGIN_NOTE = (
    '🔴 <strong>last_login はこのアプリでは更新されません。</strong>'
    'DRF の Token 認証は last_login を触らないため、'
    '<strong>常に「なし」</strong>になります —— '
    '「一度もログインしていない」という意味ではありません。<br>'
    '実際に見たいのは「まだ使っているか」なので、'
    '<strong>プレイヤー一覧の「最終アクティブ」列</strong>を見てください '
    '(実体は PlayerStreakState.last_achievement_check_at、FEAT-540)。'
)


# ──────────────────────────────────────────────────────────────────────────────
# 【FEAT-541 (2026-09-06)】アカウント停止 (ban)
# ──────────────────────────────────────────────────────────────────────────────
#
# 🔴 **停止の真実値は `User.is_active` 単独である。**
# 認証がそれを見ており (`authentication.py` が 403 を返す)、ここに
# チェックボックスがあり、Django admin へのログインも塞ぐ。
# 2 つ目のフラグ (`is_suspended` 等) を作ると**必ず食い違う**。
# `AccountSuspensionLog` は**履歴**であって、状態の真実値ではない。
_SUSPENSION_NOTE = (
    '🔴 <strong>「有効」のチェックを外すとアカウント停止になります。</strong>'
    'API は 403 (<code>auth_account_suspended</code>) を返し、'
    'アプリには停止画面が出ます。Django admin へのログインも塞がれます。<br>'
    '⚠️ 切り替えると <strong>アカウント停止履歴</strong>に「いつ・誰が・理由」が'
    '1 行残ります。理由は<strong>運営内部用</strong>で、ユーザーの画面には出ません。<br>'
    '⚠️ ゲスト (未ログイン) は User を持たないため停止できません。'
)


class UserSuspensionForm(DjangoUserChangeForm):
    """`is_active` を切り替えるときの理由入力欄 (model 外)。

    ⚠️ **`forms.ModelForm` を直接継承しないこと。** Django の
    `UserChangeForm` は `password` を `ReadOnlyPasswordHashField`
    （ハッシュ表示のみ、`required=False`）に差し替えている。
    素の `ModelForm` にすると `password` が**必須の入力欄**に戻り、
    保存が「この項目は必須です。」で弾かれる ——
    しかも admin は 200 でフォームを再描画するだけなので、
    **エラーに見えず「保存したのに変わらない」ように見える**。
    最初にこれを踏んだ。
    """

    suspension_reason = forms.CharField(
        label='停止 / 解除の理由',
        required=False,
        widget=forms.Textarea(attrs={'rows': 2}),
        help_text='運営内部用の記録です。ユーザーの画面には表示されません。'
                  '未入力でも「いつ誰が」は記録されます。',
    )


@admin.register(AccountSuspensionLog)
class AccountSuspensionLogAdmin(ReadOnlyAdminMixin, admin.ModelAdmin):
    """⚠️ 履歴は追加・変更・削除すべて不可。

    後から書き換えられると証跡の意味が無い。記録は
    `UserWithLastLoginNoteAdmin.save_model` が自動で書く。
    """

    list_display  = ('created_at', 'user', 'action', 'performed_by', 'reason')
    list_filter   = ('action',)
    search_fields = ('user__username', 'user__email', 'reason')
    date_hierarchy = 'created_at'


class UserWithLastLoginNoteAdmin(DjangoUserAdmin):
    """`last_login` の誤情報を潰し (FEAT-540)、停止の切替を記録する (FEAT-541)。"""

    form = UserSuspensionForm
    readonly_fields = DjangoUserAdmin.readonly_fields + ('last_login',)
    fieldsets = tuple(
        (name, {**opts, 'description': _LAST_LOGIN_NOTE})
        if 'last_login' in opts.get('fields', ())
        else (name, {**opts, 'description': _SUSPENSION_NOTE})
        if 'is_active' in opts.get('fields', ())
        else (name, opts)
        for name, opts in DjangoUserAdmin.fieldsets
    )

    def get_fieldsets(self, request, obj=None):
        """変更画面にだけ理由の入力欄を出す (追加画面には出さない)。"""
        fieldsets = super().get_fieldsets(request, obj)
        if obj is None:
            return fieldsets
        return fieldsets + (
            ('アカウント停止 (FEAT-541)', {
                'fields': ('suspension_reason',),
                'description': _SUSPENSION_NOTE,
            }),
        )

    def save_model(self, request, obj, form, change):
        """`is_active` の**遷移**を検知して履歴を 1 行書く。

        🔴 理由・日時・実行者が残らない ban は運用できない ——
        解除の判断も、問い合わせへの回答もできなくなる。

        ⚠️ **理由が空でも行は作る。** 何も残らないより、
        「いつ誰が」だけでも残るほうが良い。

        ⚠️ 遷移が無い保存 (名前を直しただけ等) では**書かない**。
        毎回書くと履歴がノイズで埋まり、証跡として読めなくなる。
        """
        previous = None
        if change and obj.pk:
            previous = User.objects.filter(pk=obj.pk).values_list(
                'is_active', flat=True,
            ).first()
        super().save_model(request, obj, form, change)

        if previous is None or previous == obj.is_active:
            return
        AccountSuspensionLog.objects.create(
            user=obj,
            action='lift' if obj.is_active else 'suspend',
            reason=form.cleaned_data.get('suspension_reason', '') or '',
            performed_by=request.user if request.user.is_authenticated else None,
        )


admin.site.unregister(User)
admin.site.register(User, UserWithLastLoginNoteAdmin)

