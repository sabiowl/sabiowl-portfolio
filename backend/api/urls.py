from django.urls import path
from . import views

urlpatterns = [
    # ── ヘルスチェック ──────────────────────────────────────
    path('health/',
         views.HealthCheckView.as_view(),       name='health'),

    # ── ホーム集約エンドポイント ────────────────────────────
    path('home/',
         views.HomeBootstrapView.as_view(),     name='home-bootstrap'),

    # ── プレイヤー ──────────────────────────────────────────
    # NOTE: player/stats/ 等は player/ より先に定義（前方一致対策）
    path('player/stats/',
         views.PlayerStatsView.as_view(),          name='player-stats'),
    # 【廃止 (2026-06-26)】 player/titles/ (TitlesView) は実績 30 件統合により撤去。
    # 【FEAT-407 (2026-06-01)】ResetSettingsView 削除: Flutter caller ゼロ確認済 (dead endpoint)
    # grep -rn "reset-settings|ResetSettings" mobile/lib → ゼロ件 (2026-06-01 確認)
    # 【FEAT-304】PartyEditDialog からのジョブ切替（player/ より先に定義 = 前方一致対策）
    path('player/active-job/',
         views.ActiveJobUpdateView.as_view(),      name='player-active-job'),
    # 【FEAT-326】PartyEditDialog 装備変更 BottomSheet からの武器切替
    path('player/equip-weapon/',
         views.EquipWeaponView.as_view(),          name='player-equip-weapon'),
    # 【FEAT-327】所持武器全件取得 (EquipmentSelectionOverlay 用、player/ より前)
    path('player/weapons/',
         views.PlayerWeaponsView.as_view(),        name='player-weapons'),
    # 【FEAT-511 Phase A (2026-07-30)】ジョブ熟練度一覧 (player/ より前に定義)
    path('player/job_masteries/',
         views.JobMasteryListView.as_view(),       name='player-job-masteries'),
    path('player/',
         views.PlayerProfileView.as_view(),        name='player'),

    # ── ステータス割り振り ──────────────────────────────────
    path('stats/<int:pk>/allocate/',
         views.StatAllocateView.as_view(),       name='stat-allocate'),

    # ── 習慣 ────────────────────────────────────────────────
    # NOTE: 固定パス（summary/, reorder/, archived/）は <int:pk>/ より前に定義すること
    path('habits/todos/done/',
         views.TodoDoneListView.as_view(),       name='todo-done-list'),
    path('habits/summary/',
         views.HabitSummaryView.as_view(),       name='habit-summary'),
    path('habits/reorder/',
         views.HabitOrderView.as_view(),         name='habit-reorder'),
    path('habits/archived/',
         views.ArchivedHabitListView.as_view(),  name='habit-archived-list'),
    path('habits/trash/',
         views.TrashHabitListView.as_view(),     name='habit-trash'),
    path('habits/categories/',
         views.HabitCategoriesView.as_view(),    name='habit-categories'),
    path('habits/',
         views.HabitListCreateView.as_view(),    name='habit-list'),
    path('habits/<int:pk>/',
         views.HabitDetailView.as_view(),        name='habit-detail'),
    path('habits/<int:pk>/count/',
         views.HabitCountView.as_view(),         name='habit-count'),
    path('habits/<int:pk>/checklist/<int:item_pk>/toggle/',
         views.ChecklistItemToggleView.as_view(), name='checklist-toggle'),
    path('habits/<int:pk>/shield/',
         views.ShieldActivateView.as_view(),      name='habit-shield'),
    path('habits/<int:pk>/archive/',
         views.HabitArchiveView.as_view(),        name='habit-archive'),
    path('habits/<int:pk>/restore/',
         views.HabitRestoreView.as_view(),        name='habit-restore'),

    # ── ショップ ─────────────────────────────────────────────────
    # NOTE: purchase/ / sell/ は shop/ より先に定義
    path('shop/purchase/',
         views.ShopPurchaseView.as_view(),        name='shop-purchase'),
    # 【FEAT-443 (2026-06-20)】アイテム売却 (持ち物リストから)。
    path('shop/sell/',
         views.ShopSellView.as_view(),            name='shop-sell'),
    path('shop/',
         views.ShopItemsView.as_view(),           name='shop-items'),

    # ── アイテム使用 (FEAT-318 再活性化) ─────────────────────────
    path('items/use-xp-boost/',
         views.UseXpBoostView.as_view(),          name='use-xp-boost'),

    # ── カレンダー ───────────────────────────────────────────────
    # NOTE: サブパスは calendar/ より先に定義
    path('calendar/streak/',
         views.StreakView.as_view(),                    name='calendar-streak'),
    path('calendar/stats/',
         views.StatsView.as_view(),                    name='calendar-stats'),
    # 【20260729 review §3 C-1】旧 calendar/monthly-summary/ は削除 (dead code +
    # grade 閾値二重管理 drift。Mobile 側 MonthlySummaryCard がクライアント計算)
    path('calendar/heatmap/',
         views.CalendarHeatmapView.as_view(),          name='calendar-heatmap'),
    path('calendar/daily/',
         views.CalendarDailyView.as_view(),             name='calendar-daily'),
    # P1-3: カレンダー画面初回表示用の集約エンドポイント
    path('calendar/bootstrap/',
         views.CalendarBootstrapView.as_view(),         name='calendar-bootstrap'),
    # BUG-17: 外部カレンダー（Google/Apple）のイベントインポート
    # 【FEAT-426 (2026-06-11)】廃止 (410 Gone)。Google 予定本文は Mobile ローカル DB に保存。
    path('calendar/import/',
         views.ExternalCalendarImportView.as_view(),    name='calendar-import'),
    # 【FEAT-212】Google カレンダー同期解除（source='google' な TimelineEvent を一括削除）
    # 【FEAT-426 (2026-06-11)】廃止 (410 Gone)。
    path('calendar/import/google/',
         views.GoogleCalendarUnsyncView.as_view(),      name='calendar-import-google-unsync'),
    # 【FEAT-426 (2026-06-11)】Google カレンダー予定の完了状態 (Multi-device 同期用)
    path('google-events/completions/',
         views.GoogleEventCompletionListView.as_view(), name='google-event-completion-list'),
    path('google-events/<str:google_event_id>/complete/',
         views.GoogleEventCompletionView.as_view(),     name='google-event-completion'),
    # FEAT-204: 30 日累積完了数 + マイルストーン（ホーム画面の積み上げグラフ用）
    path('stats/30d/',
         views.Stats30DayView.as_view(),                name='stats-30day'),
    path('calendar/',
         views.CalendarView.as_view(),                  name='calendar'),

    # ── フレンド ─────────────────────────────────────────────────
    path('friends/search/',
         views.FriendSearchView.as_view(),             name='friend-search'),
    path('friends/requests/',
         views.FriendRequestView.as_view(),            name='friend-requests'),
    path('friends/requests/<int:pk>/<str:action>/',
         views.FriendRequestActionView.as_view(),      name='friend-request-action'),
    path('friends/<int:pk>/',
         views.FriendListView.as_view(),               name='friend-delete'),
    path('friends/<int:player_id>/profile/',
         views.FriendProfileView.as_view(),            name='friend-profile'),
    path('friends/<int:player_id>/gift/',
         views.GiftView.as_view(),                     name='friend-gift'),
    path('friends/',
         views.FriendListView.as_view(),               name='friend-list'),

    # 【FEAT-446 (2026-06-20)】メッセージ機能廃止: トラブル / 悪用未然防止のため。
    # 旧 path('messages/<int:player_id>/', views.MessageView.as_view(), ...) を撤去。

    # ── 公開設定 ──────────────────────────────────────────────────
    # 【FEAT-407 (2026-06-01)】PrivacySettingsView 削除: Flutter caller ゼロ確認済 (dead endpoint)
    # FEAT-396 で Flutter 公開設定 UI 撤廃 → Backend API も不要。
    # grep -rn "privacy/|PrivacySettings" mobile/lib → ゼロ件 (2026-06-01 確認)

    # ── 通知 ──────────────────────────────────────────────────────
    # NOTE: <int:pk>/read/ は notifications/ より先に定義
    path('notifications/<int:pk>/read/',
         views.NotificationReadView.as_view(),       name='notification-read'),
    path('notifications/read-all/',
         views.NotificationListView.as_view(),       name='notification-read-all'),
    path('notifications/',
         views.NotificationListView.as_view(),       name='notification-list'),

    # ── 【FEAT-458 (2026-06-21)】お知らせ ───────────────────────
    # NOTE: unread/ / <pk>/read/ は announcements/ より先に定義 (前方一致対策)
    path('announcements/unread/',
         views.AnnouncementUnreadView.as_view(),     name='announcement-unread'),
    path('announcements/<int:pk>/read/',
         views.AnnouncementReadView.as_view(),       name='announcement-read'),
    path('announcements/',
         views.AnnouncementListView.as_view(),       name='announcement-list'),

    # ── 認証（Google / Apple サインインのみ）────────────────────────
    # FEAT-178: Magic Link / メール連携 / 連携解除 / マージは完全廃止。
    path('auth/logout/',
         views.LogoutView.as_view(),                   name='auth-logout'),
    # ── 開発用（DEBUG=True 専用 / View 内で DEBUG チェック済み）────
    path('auth/dev-login/',
         views.DevLoginView.as_view(),                 name='auth-dev-login'),
    path('auth/guest-init/',
         views.GuestInitView.as_view(),                name='auth-guest-init'),
    # FEAT-189: guest-migrate API は廃止（ゲスト基盤サーバー化により不要）
    path('auth/social/verify/',
         views.SocialAuthView.as_view(),               name='auth-social-verify'),
    path('auth/social/promote-confirm/',
         views.SocialPromoteConfirmView.as_view(),     name='auth-social-promote-confirm'),
    path('auth/social/accounts/',
         views.SocialAccountListView.as_view(),        name='auth-social-accounts'),
    path('auth/social/link/',
         views.SocialLinkView.as_view(),               name='auth-social-link'),
    # 【BUG-129 (2026-06-14)】社会的連携解除 (誤連携救済、PlayerProfile はゲストに戻る)
    path('auth/social/unlink/',
         views.SocialUnlinkView.as_view(),             name='auth-social-unlink'),

    # ── キャラクター ───────────────────────────────────────────
    path('characters/',
         views.CharacterListView.as_view(),            name='character-list'),
    path('characters/<int:pk>/select/',
         views.CharacterSelectView.as_view(),          name='character-select'),
    path('characters/<int:pk>/purchase/',
         views.CharacterPurchaseView.as_view(),        name='character-purchase'),
    path('characters/<int:pk>/exchange/',
         views.CharacterExchangeView.as_view(),        name='character-exchange'),

    # ── お問い合わせ ──────────────────────────────────────────
    path('contact/',
         views.ContactView.as_view(),                  name='contact'),

    # ── ガチャ ────────────────────────────────────────────────
    # NOTE: gacha/pending/ と gacha/exchange/ は gacha/pull/ より先に定義
    path('gacha/status/',
         views.GachaStatusView.as_view(),              name='gacha-status'),
    path('gacha/pending/',
         views.PendingRewardListView.as_view(),        name='gacha-pending'),
    # 【FEAT-518】排出確率の開示。購入前に到達できる必要があるため認証はゲスト可。
    path('gacha/odds/',
         views.GachaOddsView.as_view(),                name='gacha-odds'),
    path('gacha/exchange/<int:pk>/',
         views.DuplicateExchangeView.as_view(),        name='gacha-exchange'),
    path('gacha/pull/',
         views.GachaPullView.as_view(),                name='gacha-pull'),
    # 【FEAT-374】直近ガチャもう 1 度引き直し (💎 50)
    path('gacha/redo/',
         views.GachaRedoView.as_view(),                name='gacha-redo'),

    # ── 実績 ──────────────────────────────────────────────────
    path('achievements/<str:key>/claim/',
         views.AchievementClaimView.as_view(),         name='achievement-claim'),
    path('achievements/',
         views.AchievementListView.as_view(),          name='achievement-list'),

    # ── Sabi ──────────────────────────────────────────────────
    path('sabi/message/',
         views.SabiMessageView.as_view(),              name='sabi-message'),
    # 【SEC-11】sabi/navigate/ は SabiNavigate(LLM) 完全廃止に伴い削除（2026-05-15）

    # ── ストリーク保護 (FEAT-377 / FEAT-420) ─────────────────────
    # 予約: streak_protection_pending=True を立てるのみ (即時消費なし)。
    # 翌日の習慣達成判定で「途切れていた」場合のみ在庫 1 個を消費して保護発動。
    path('streak-protection/use/',
         views.StreakProtectionManualUseView.as_view(), name='streak-protection-use'),
    # 予約取消: streak_protection_pending=False に戻すのみ (冪等)
    path('streak-protection/cancel/',
         views.StreakProtectionCancelView.as_view(), name='streak-protection-cancel'),

    # ── 休息日 ────────────────────────────────────────────────
    path('rest-day/buy-fruit/',
         views.RestDayBuyFruitView.as_view(),          name='rest-day-buy-fruit'),
    path('rest-day/',
         views.RestDayView.as_view(),                  name='rest-day'),

    # ── タイムライン ──────────────────────────────────────────
    path('timeline/',
         views.TimelineListView.as_view(),              name='timeline-list'),
    path('timeline/<int:pk>/',
         views.TimelineDetailView.as_view(),            name='timeline-detail'),
    path('timeline/<int:pk>/complete/',
         views.TimelineCompleteView.as_view(),          name='timeline-complete'),
    path('timeline/<int:pk>/uncomplete/',
         views.TimelineUncompleteView.as_view(),        name='timeline-uncomplete'),
    # 【FEAT-244】Sabiowl → Google push 後の Google Event ID 保存専用エンドポイント
    path('timeline/<int:pk>/google-link/',
         views.TimelineGoogleLinkView.as_view(),        name='timeline-google-link'),
    # 【FEAT-295】バトルシステム MVP
    path('battle/start/',
         views.BattleStartView.as_view(),               name='battle-start'),
    path('battle/finish/',
         views.BattleFinishView.as_view(),              name='battle-finish'),
    path('battle/logs/',
         views.BattleLogListView.as_view(),             name='battle-logs'),
    # 【FEAT-296】Enemy 一覧（ギルド画面でボス選択時に使用、5 分キャッシュ）
    path('battle/enemies/',
         views.EnemyListView.as_view(),                 name='battle-enemies'),
    # 【FEAT-436 Phase 2】RevenueCat webhook 受信 (Authorization ヘッダーで認証)
    path('iap/webhook/',
         views.RevenueCatWebhookView.as_view(),         name='iap-webhook'),
    # 【FEAT-463】緊急メンテナンスモード (AllowAny、起動時 + 再試行ボタン用)
    path('maintenance/',
         views.MaintenanceStatusView.as_view(),         name='maintenance-status'),

    # 【FEAT-465 (2026-06-24)】月次カテゴリチャレンジ
    path('challenges/',
         views.ChallengeListView.as_view(),             name='challenge-list'),

    # 【FEAT-479 (2026-07-06)】ジグソーパズル世界システム
    # NOTE: 固定パス (scenes/ active/ displayed/) は base path より前に定義（前方一致対策）
    path('puzzle-world/scenes/',
         views.PuzzleWorldSceneListView.as_view(),      name='puzzle-world-scenes'),
    path('puzzle-world/active/',
         views.PuzzleWorldActiveSelectView.as_view(),   name='puzzle-world-active'),
    path('puzzle-world/displayed/',
         views.PuzzleWorldDisplayedSelectView.as_view(), name='puzzle-world-displayed'),
    path('puzzle-world/',
         views.PuzzleWorldStatusView.as_view(),         name='puzzle-world-status'),

    # 【FEAT-467 (2026-07-02)】タスク候補 Backend 化
    path('task-suggestions/',
         views.TaskSuggestionListView.as_view(),        name='task-suggestion-list'),

    # 【FEAT-477 (2026-07-03)】Feature Flag 一覧 (django-waffle Switch/Sample/Flag)
    path('feature-flags/',
         views.FeatureFlagsView.as_view(),              name='feature-flags'),

    # 【FEAT-493 (2026-07-25)】フリーメモ (Quick Capture → Later Triage)
    # NOTE: 固定サブパス (convert / convert-to-*) は <int:pk>/ より前に定義 (前方一致対策)
    # 【2026-07-25 P3 #6】新 URL: POST /free-memos/<id>/convert/ body {to_type}
    path('free-memos/<int:pk>/convert/',
         views.FreeMemoConvertView.as_view(),           name='free-memo-convert'),
    # 【2026-07-25 P3 #6】旧 3 URL 互換 (Flutter 側移行済むまで維持、to_type を kwarg で渡す)
    path('free-memos/<int:pk>/convert-to-event/',
         views.FreeMemoConvertView.as_view(),           name='free-memo-convert-event',
         kwargs={'to_type': 'event'}),
    path('free-memos/<int:pk>/convert-to-todo/',
         views.FreeMemoConvertView.as_view(),           name='free-memo-convert-todo',
         kwargs={'to_type': 'todo'}),
    path('free-memos/<int:pk>/convert-to-habit/',
         views.FreeMemoConvertView.as_view(),           name='free-memo-convert-habit',
         kwargs={'to_type': 'habit'}),
    # 【FEAT-500 (2026-07-26)】ソフト削除 → trash → 復元 / 完全削除の 3 endpoint
    path('free-memos/<int:pk>/restore/',
         views.FreeMemoRestoreView.as_view(),           name='free-memo-restore'),
    path('free-memos/<int:pk>/purge/',
         views.FreeMemoPurgeView.as_view(),             name='free-memo-purge'),
    # 【FEAT-498 §2.6 (2026-07-31)】trash 一括完全削除。<int:pk> は int 限定なので
    # 'trash' が pk として誤解釈されることは無いが、可読性のため purge / restore
    # 系 endpoint と近接配置する。
    path('free-memos/trash/purge-all/',
         views.FreeMemoTrashPurgeAllView.as_view(),     name='free-memo-trash-purge-all'),
    path('free-memos/<int:pk>/',
         views.FreeMemoDetailView.as_view(),            name='free-memo-detail'),
    path('free-memos/',
         views.FreeMemoListCreateView.as_view(),        name='free-memo-list'),
]
