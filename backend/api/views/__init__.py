from .health import HealthCheckView, ContactView
from .player import (
    PlayerProfileView,
    # ResetSettingsView 削除 (FEAT-407: Flutter caller ゼロ確認済)
    PlayerStatsView, StatAllocateView,
    # 【廃止 (2026-06-26)】 TitlesView は実績 30 件統合で撤去済
    ActiveJobUpdateView,               # 【FEAT-304】PartyEditDialog のジョブ切替
    EquipWeaponView,                   # 【FEAT-326】装備変更 BottomSheet からの武器切替
    PlayerWeaponsView,                 # 【FEAT-327】所持武器全件取得 (EquipmentSelectionOverlay 用)
    StreakProtectionManualUseView,     # 【FEAT-377】ストリーク保護 予約 (FEAT-420 で予約モード化)
    StreakProtectionCancelView,        # 【FEAT-420】ストリーク保護 予約取消
)
from .habits import (
    HabitListCreateView, HabitSummaryView, HabitDetailView,
    HabitArchiveView, HabitRestoreView,
    ArchivedHabitListView, TrashHabitListView, HabitCategoriesView,
    HabitCountView, HabitOrderView,
    ChecklistItemToggleView, ShieldActivateView,
    TodoDoneListView,
)
from .shop import ShopItemsView, ShopPurchaseView, ShopSellView, UseXpBoostView
from .calendar import (
    CalendarView, StreakView, StatsView,
    CalendarHeatmapView, CalendarDailyView,
    ExternalCalendarImportView,
    GoogleCalendarUnsyncView,  # FEAT-212
    CalendarBootstrapView,  # P1-3
    Stats30DayView,         # FEAT-204
    GoogleEventCompletionListView,  # FEAT-426
    GoogleEventCompletionView,      # FEAT-426
)
from .social import (
    FriendSearchView, FriendRequestView, FriendRequestActionView,
    FriendListView, FriendProfileView, GiftView,
    # 【FEAT-446 (2026-06-20)】MessageView 削除: フレンド間メッセージ機能廃止
    # (トラブル / 悪用未然防止)
    # PrivacySettingsView 削除 (FEAT-407: Flutter caller ゼロ確認済、FEAT-396 で UI 撤廃済)
)
from .notifications import NotificationListView, NotificationReadView
from .announcements import (  # 【FEAT-458】お知らせ機能
    AnnouncementUnreadView, AnnouncementListView, AnnouncementReadView,
)
from .auth import (
    LogoutView,
    DevLoginView, GuestInitView,
    SocialAuthView,
    SocialAccountListView, SocialLinkView, SocialPromoteConfirmView,
    SocialUnlinkView,  # 【BUG-129 (2026-06-14)】社会的連携解除
)

from .gamification import CharacterListView, CharacterSelectView, CharacterPurchaseView, CharacterExchangeView
from .gacha import (
    GachaStatusView, GachaPullView, PendingRewardListView, DuplicateExchangeView,
    GachaRedoView,  # 【FEAT-374】ガチャ「もう 1 度」💎 50
    GachaOddsView,  # 【FEAT-518】排出確率の開示 (App Store Guideline 3.1.1)
)
from .achievements import AchievementListView, AchievementClaimView
from .sabi import SabiMessageView  # 【SEC-11】SabiNavigateView は 2026-05-15 廃止
from .rest_day import RestDayView, RestDayBuyFruitView
from .timeline import (
    TimelineListView, TimelineDetailView,
    TimelineCompleteView, TimelineUncompleteView,
    TimelineGoogleLinkView,  # 【FEAT-244】Sabiowl → Google push 後の ID 保存用
)
from .home import HomeBootstrapView
from .battle import (
    BattleStartView, BattleFinishView, BattleLogListView,  # FEAT-295
    EnemyListView,  # FEAT-296
)
from .iap import RevenueCatWebhookView  # FEAT-436 Phase 2
from .maintenance import MaintenanceStatusView  # FEAT-463
from .challenge import ChallengeListView  # FEAT-465
from .task_suggestion import TaskSuggestionListView  # 【FEAT-467 (2026-07-02)】タスク候補 Backend 化
from .feature_flags import FeatureFlagsView  # 【FEAT-477 (2026-07-03)】Feature Flag 一覧
from .puzzle_world import (  # 【FEAT-479 (2026-07-06)】ジグソーパズル世界システム
    PuzzleWorldStatusView, PuzzleWorldSceneListView,
    PuzzleWorldActiveSelectView, PuzzleWorldDisplayedSelectView,
)
from .job_mastery import JobMasteryListView  # 【FEAT-511 Phase A (2026-07-30)】ジョブ熟練度
from .free_memo import (  # 【FEAT-493 (2026-07-25)】フリーメモ機能
    FreeMemoListCreateView,
    FreeMemoDetailView,
    FreeMemoConvertView,  # 【2026-07-25 P3 #6】旧 3 view を統合
    FreeMemoRestoreView,  # 【FEAT-500 (2026-07-26)】trash からの復元
    FreeMemoPurgeView,    # 【FEAT-500 (2026-07-26)】完全削除 (hard)
    FreeMemoTrashPurgeAllView,  # 【FEAT-498 §2.6 (2026-07-31)】trash 一括完全削除
)

__all__ = [
    'HealthCheckView', 'ContactView',
    'PlayerProfileView', 'PlayerStatsView',
    # 'ResetSettingsView' 削除 (FEAT-407: dead endpoint)
    'StatAllocateView',
    # 'TitlesView' 廃止 (2026-06-26): 実績 30 件統合により撤去
    'ActiveJobUpdateView',              # 【FEAT-304】
    'EquipWeaponView',                  # 【FEAT-326】
    'PlayerWeaponsView',                # 【FEAT-327】
    'StreakProtectionManualUseView',    # 【FEAT-377】(FEAT-420 で予約モード化)
    'StreakProtectionCancelView',       # 【FEAT-420】
    'HabitListCreateView', 'HabitSummaryView', 'HabitDetailView',
    'HabitArchiveView', 'HabitRestoreView',
    'ArchivedHabitListView', 'TrashHabitListView',
    'HabitCountView', 'HabitOrderView',
    'ChecklistItemToggleView', 'ShieldActivateView',
    'TodoDoneListView',
    'ShopItemsView', 'ShopPurchaseView', 'ShopSellView',
    'CalendarView', 'StreakView', 'StatsView',
    'CalendarHeatmapView', 'CalendarDailyView',
    'ExternalCalendarImportView',
    'GoogleCalendarUnsyncView',  # FEAT-212
    'CalendarBootstrapView',  # P1-3
    'Stats30DayView',         # FEAT-204
    'GoogleEventCompletionListView',  # FEAT-426
    'GoogleEventCompletionView',      # FEAT-426
    'FriendSearchView', 'FriendRequestView', 'FriendRequestActionView',
    'FriendListView', 'FriendProfileView', 'GiftView',
    # 'MessageView' 削除 (FEAT-446: フレンド間メッセージ機能廃止)
    # 'PrivacySettingsView' 削除 (FEAT-407: dead endpoint)
    'NotificationListView', 'NotificationReadView',
    # 【FEAT-458】お知らせ機能 (全ユーザー共通お知らせ)
    'AnnouncementUnreadView', 'AnnouncementListView', 'AnnouncementReadView',
    'LogoutView',
    'DevLoginView', 'GuestInitView',
    'SocialAuthView',
    'SocialAccountListView', 'SocialLinkView', 'SocialPromoteConfirmView',
    'SocialUnlinkView',  # 【BUG-129 (2026-06-14)】
    'CharacterListView', 'CharacterSelectView', 'CharacterPurchaseView', 'CharacterExchangeView',
    'GachaStatusView', 'GachaPullView', 'PendingRewardListView', 'DuplicateExchangeView',
    'AchievementListView', 'AchievementClaimView',
    'SabiMessageView',
    'RestDayView', 'RestDayBuyFruitView',
    'TimelineListView', 'TimelineDetailView',
    'TimelineCompleteView', 'TimelineUncompleteView',
    'TimelineGoogleLinkView',  # FEAT-244
    'HomeBootstrapView',
    # 【FEAT-295】バトルシステム
    'BattleStartView', 'BattleFinishView', 'BattleLogListView',
    # 【FEAT-296】ギルド画面ボスリスト
    'EnemyListView',
    # 【FEAT-436 Phase 2】IAP webhook
    'RevenueCatWebhookView',
    # 【FEAT-463】緊急メンテナンスモード
    'MaintenanceStatusView',
    # 【FEAT-465】月次カテゴリチャレンジ
    'ChallengeListView',
    # 【FEAT-467】タスク候補 Backend 化
    'TaskSuggestionListView',
    # 【FEAT-477】Feature Flag 一覧
    'FeatureFlagsView',
    # 【FEAT-479】ジグソーパズル世界システム
    'PuzzleWorldStatusView', 'PuzzleWorldSceneListView',
    'PuzzleWorldActiveSelectView', 'PuzzleWorldDisplayedSelectView',
    # 【FEAT-493】フリーメモ機能
    'FreeMemoListCreateView', 'FreeMemoDetailView',
    'FreeMemoConvertView',
    'FreeMemoRestoreView', 'FreeMemoPurgeView',  # 【FEAT-500 (2026-07-26)】
    'FreeMemoTrashPurgeAllView',  # 【FEAT-498 §2.6 (2026-07-31)】trash 一括完全削除
    # 【FEAT-511 Phase A】ジョブ熟練度
    'JobMasteryListView',
]
