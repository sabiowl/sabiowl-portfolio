from .player import (
    PlayerProfile, CharacterStat, AccountDeletionFeedback, DELETION_REASON_CHOICES,
    PlayerStatsMatrix,  # 【2026-07-09】プレイヤーステータス pivot 用 proxy model
)
# 【FEAT-478 Phase 2 最終 (2026-07-06)】4 State モデルは player_state.py に集約
from .player_state import (
    PlayerEconomyState, PlayerBattleState, PlayerStreakState, PlayerSettings,
)
from .habits import Habit, HabitLog, HabitRewardLog, ChecklistItem, Achievement, PlayerAchievement, RestDay
from .gamification import Character, OwnedCharacter, PlayerItem
from .gacha import GachaReward, PlayerGachaStatus, GachaHistory, PendingDuplicateReward
from .social import Friendship, Message, Notification, Gift
from .auth import SocialAccount, GuestSession, GuestPromotePending
from .timeline import TimelineEvent, GoogleEventCompletion
from .battle import Job, Enemy, WeaponMaster, PlayerWeapon, Battle, BattleLog
from .iap import IAPReceipt  # FEAT-436 Phase 2
from .announcement import Announcement, PlayerAnnouncementRead  # FEAT-458
from .maintenance import MaintenanceConfig  # FEAT-463
from .challenge import Challenge, ChallengeParticipation  # FEAT-465
from .sabi import SabiMessage  # 【新規 (2026-06-26)】サビセリフ admin 編集対応
from .admin_mfa import AdminMFAChallenge  # 【2026-06-29】admin メール OTP MFA
from .task_suggestion import TaskSuggestion  # 【FEAT-467 (2026-07-02)】タスク候補 Backend 化
from .puzzle_world import (  # 【FEAT-479 (2026-07-06)】ジグソーパズル世界システム Ver1
    PuzzleWorldScene, PlayerPuzzleWorld, PlayerPuzzleSceneProgress, PlayerPuzzleWorldHistory,
)
from .free_memo import FreeMemo  # 【FEAT-493 (2026-07-25)】フリーメモ機能
from .job_mastery import PlayerJobMastery  # 【FEAT-511 Phase A (2026-07-30)】ジョブ熟練度

__all__ = [
    # player
    'PlayerProfile', 'CharacterStat', 'AccountDeletionFeedback', 'DELETION_REASON_CHOICES',
    'PlayerStatsMatrix',  # 【2026-07-09】プレイヤーステータス pivot 用 proxy model
    # 【FEAT-478 Phase 2】PlayerProfile 4 分割 (段階的 rewrite 前提、Phase 2a 時点は shadow)
    'PlayerEconomyState', 'PlayerBattleState', 'PlayerStreakState', 'PlayerSettings',
    # habits
    'Habit', 'HabitLog', 'HabitRewardLog', 'ChecklistItem',
    'Achievement', 'PlayerAchievement', 'RestDay',
    # gamification
    'Character', 'OwnedCharacter', 'PlayerItem',
    # gacha
    'GachaReward', 'PlayerGachaStatus', 'GachaHistory', 'PendingDuplicateReward',
    # social
    'Friendship', 'Message', 'Notification', 'Gift',
    # auth
    'SocialAccount', 'GuestSession', 'GuestPromotePending',
    # timeline
    'TimelineEvent', 'GoogleEventCompletion',
    # battle (FEAT-295) + Job (FEAT-299)
    'Job', 'Enemy', 'WeaponMaster', 'PlayerWeapon', 'Battle', 'BattleLog',
    # iap (FEAT-436)
    'IAPReceipt',
    # announcement (FEAT-458)
    'Announcement', 'PlayerAnnouncementRead',
    # maintenance (FEAT-463)
    'MaintenanceConfig',
    # challenge (FEAT-465)
    'Challenge', 'ChallengeParticipation',
    # sabi (新規 2026-06-26、サビセリフ admin 編集対応)
    'SabiMessage',
    # admin MFA (新規 2026-06-29、admin 画面ログイン強化)
    'AdminMFAChallenge',
    # task_suggestion (FEAT-467、2026-07-02、タスク候補 Backend 化)
    'TaskSuggestion',
    # free_memo (FEAT-493、2026-07-25、フリーメモ機能 Quick Capture → Later Triage)
    'FreeMemo',
    # job_mastery (FEAT-511 Phase A、2026-07-30、ジョブ熟練度システム)
    'PlayerJobMastery',
]
