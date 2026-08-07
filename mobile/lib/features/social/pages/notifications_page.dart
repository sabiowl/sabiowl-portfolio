import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';                     // 【BUG-101】通知タップ deep link
import '../../../core/services/notification_deep_link.dart';   // 【BUG-101】ルート解決
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/sabi_loading_skeleton.dart';   // FEAT-230
import '../../announcement/models/announcement.dart';          // 【FEAT-458】お知らせ
import '../../announcement/providers/announcement_provider.dart';  // 【FEAT-458】
import '../models/social_models.dart';
import '../providers/social_provider.dart';

class NotificationsPage extends ConsumerStatefulWidget {
  const NotificationsPage({super.key});

  @override
  ConsumerState<NotificationsPage> createState() =>
      _NotificationsPageState();
}

class _NotificationsPageState extends ConsumerState<NotificationsPage> {
  @override
  void initState() {
    super.initState();
    // 【FEAT-479 hotfix (2026-07-06)】ゲストモード対応。
    // 旧: ゲスト時は API 取得スキップ + GuestLinkPromptCard 表示だった。
    // 新: Backend view の IsAuthenticatedOrGuest 化に合わせて、ゲストでも
    //     自身の通知 (お知らせ等) を取得する経路に変更。
    // 非 autoDispose のためキャッシュが残っている場合があるが、
    // ページ表示のたびに最新データを取得して状態を更新する
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(notificationsProvider.notifier).refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // P0-6: unwrapPrevious で戻り遷移時のスピナーちらつきを防止
    final notifsAsync = ref.watch(notificationsProvider).unwrapPrevious();

    // 【FEAT-458 (2026-06-21)】「通知」「お知らせ」2 タブ構成。
    // 通知 = 個人通知 (フレンド申請 / レベルアップ / ギフト等)
    // お知らせ = 全ユーザー共通お知らせ (運営からの情報、ホーム popup と同期)
    return DefaultTabController(
      length: 2,
      child: Scaffold(
      appBar: AppBar(
        // 【FEAT-464 (2026-06-23)】画面タイトルを「通知」→「お知らせ」に変更。
        // ハンバーガーメニュー (HomeDrawer) からの動線名と一致させる。タブ内訳は
        // 「通知」(個人通知) / 「お知らせ」(全ユーザー共通) のまま維持。
        title: Text(l10n.socialNotificationsPageTitle),
        // 【2026-06-27 不具合修正】「すべて既読」タップ後に自動 BackButton が
        // 反応しない不具合への構造的修正。明示的に IconButton + go_router の
        // context.pop() で代替し、自動推論への依存を排除する。
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: l10n.socialNotificationsPageBackTooltip,
          onPressed: () {
            if (context.canPop()) {
              context.pop();
            } else {
              // 直接 deep link 等で開かれた場合のフォールバック (ホーム遷移)
              context.go('/home');
            }
          },
        ),
        bottom: TabBar(
          tabs: [
            Tab(text: l10n.socialNotificationsPageNotificationsTab, icon: const Icon(Icons.notifications_outlined, size: 18)),
            Tab(text: l10n.socialNotificationsPageAnnouncementsTab, icon: const Icon(Icons.campaign_outlined, size: 18)),
          ],
          indicatorColor: AppTheme.primary,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white54,
        ),
        actions: [
          TextButton(
            onPressed: notifsAsync.valueOrNull?.any((n) => !n.isRead) == true
                ? () => ref
                    .read(notificationsProvider.notifier)
                    .markAllRead()
                : null,
            child: Text(l10n.socialNotificationsPageMarkAllRead),
          ),
        ],
      ),
      body: SafeArea(
        child: TabBarView(
          children: [
            // ── タブ 1: 個人通知 (既存) ──────────────────
            _buildNotificationsTab(notifsAsync),
            // ── タブ 2: お知らせ (FEAT-458) ─────────────
            const _AnnouncementsTab(),
          ],
        ),
      ),
      ),
    );
  }

  /// 通知タブ (既存ロジック切り出し)。
  Widget _buildNotificationsTab(AsyncValue<List<AppNotification>> notifsAsync) {
    final l10n = AppLocalizations.of(context)!;
    return notifsAsync.when(
          data: (notifs) {
            if (notifs.isEmpty) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.notifications_none,
                        size: 64, color: Colors.white24),
                    const SizedBox(height: 12),
                    Text(l10n.socialNotificationsPageEmptyNotifications,
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 16)),
                  ],
                ),
              );
            }
            return RefreshIndicator(
              onRefresh: () =>
                  ref.read(notificationsProvider.notifier).refresh(),
              child: ListView.builder(
                padding:
                    const EdgeInsets.symmetric(vertical: 8),
                itemCount: notifs.length,
                itemBuilder: (_, i) => _NotificationTile(
                  notif: notifs[i],
                  onTap: () {
                    if (!notifs[i].isRead) {
                      ref
                          .read(notificationsProvider.notifier)
                          .markRead(notifs[i].id);
                    }
                    // 【BUG-101 (2026-06-14)】通知タイプに応じた画面へ遷移。
                    // 自画面 (/notifications) を返してきた場合は遷移しない (同じ画面に push しない)。
                    final route = NotificationDeepLink.resolveRoute(
                      notifs[i].notifType,
                      notifs[i].relatedId,
                    );
                    if (route != null && route != '/notifications') {
                      context.push(route);
                    }
                  },
                ),
              ),
            );
          },
          loading: () =>
              SabiWaitingPanel(message: l10n.socialNotificationsPageLoadingSabi_message),
          error: (e, _) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.notifications_none,
                  size:  64,
                  color: Colors.white24,
                ),
                const SizedBox(height: 12),
                Text(
                  l10n.socialNotificationsPageNotifLoadErrorSabi_message,
                  style: const TextStyle(color: Colors.white60, fontSize: 16),
                ),
                const SizedBox(height: 4),
                Text(
                  // STYLE GUIDE FIX: corrected from prohibited '〜ね' casual ending
                  // to '〜ますね' polite form per Sabi persona rules.
                  l10n.socialNotificationsPageRetryHintSabi_message,
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
                const SizedBox(height: 16),
                TextButton.icon(
                  onPressed: () =>
                      ref.read(notificationsProvider.notifier).refresh(),
                  icon:  const Icon(Icons.refresh,
                             size: 14, color: Colors.white38),
                  label: Text(
                    l10n.socialNotificationsPageRetryButton,
                    style: const TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        );
  }
}

// ── 【FEAT-458 (2026-06-21)】お知らせタブ ────────────────────────────────────

/// 通知画面の 2 つ目のタブ「お知らせ」(全ユーザー共通お知らせ一覧)。
///
/// announcementListProvider を watch して全件 + is_read 状態を表示。
/// 未読: 強調表示 + tap で markRead API → 既読化。
/// 既読: 薄表示 + tap で再閲覧可能 (markRead は no-op 冪等)。
class _AnnouncementsTab extends ConsumerWidget {
  const _AnnouncementsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final listAsync = ref.watch(announcementListProvider).unwrapPrevious();

    return listAsync.when(
      data: (announcements) {
        if (announcements.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.campaign_outlined, size: 64, color: Colors.white24),
                const SizedBox(height: 12),
                Text(l10n.socialNotificationsPageAnnouncementsEmptySabi_message,
                    style: const TextStyle(color: Colors.white54, fontSize: 14)),
              ],
            ),
          );
        }
        return RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(announcementListProvider);
          },
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: announcements.length,
            itemBuilder: (_, i) => _AnnouncementTile(
              announcement: announcements[i],
              onTap: () async {
                final a = announcements[i];
                // 詳細表示ダイアログ (既読化も実行)
                await showDialog<void>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    backgroundColor: AppTheme.surface,
                    title: Row(
                      children: [
                        const Icon(Icons.campaign_outlined,
                            color: AppTheme.primary, size: 22),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            a.title,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    content: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // 【2026-06-27】お知らせ画像 (任意)。
                          if (a.imageUrl != null && a.imageUrl!.isNotEmpty) ...[
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.network(
                                a.imageUrl!,
                                fit: BoxFit.cover,
                                width: double.infinity,
                                errorBuilder: (_, __, ___) =>
                                    const SizedBox.shrink(),
                              ),
                            ),
                            const SizedBox(height: 12),
                          ],
                          Text(
                            a.body,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                              height: 1.6,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            l10n.socialNotificationsPageAnnouncementDateFull(
                              a.publishedAt.year,
                              a.publishedAt.month,
                              a.publishedAt.day,
                            ),
                            style: const TextStyle(
                                color: Colors.white38, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        style: TextButton.styleFrom(
                            foregroundColor: AppTheme.primary),
                        child: Text(l10n.commonClose),
                      ),
                    ],
                  ),
                );
                // 既読化 (タップ時点で「読んだ」とみなす) + 一覧再フェッチ
                if (!a.isRead) {
                  try {
                    await ref
                        .read(announcementServiceProvider)
                        .markRead(a.id);
                    ref.invalidate(announcementListProvider);
                  } catch (_) {
                    // サイレント (既読化失敗は致命的でない)
                  }
                }
              },
            ),
          ),
        );
      },
      loading: () =>
          SabiWaitingPanel(message: l10n.socialNotificationsPageLoadingSabi_message),
      error: (e, _) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.campaign_outlined,
                size: 64, color: Colors.white24),
            const SizedBox(height: 12),
            Text(
              l10n.socialNotificationsPageNotifLoadErrorSabi_message,
              style: const TextStyle(color: Colors.white60, fontSize: 16),
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: () => ref.invalidate(announcementListProvider),
              icon: const Icon(Icons.refresh, size: 14, color: Colors.white38),
              label: Text(
                l10n.socialNotificationsPageRetryButton,
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// お知らせ 1 件のタイル (リスト表示用)。
class _AnnouncementTile extends StatelessWidget {
  const _AnnouncementTile({required this.announcement, required this.onTap});
  final Announcement announcement;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final a = announcement;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 未読バッジ (青円) or 既読プレースホルダー
            Container(
              width: 8, height: 8,
              margin: const EdgeInsets.only(top: 6, right: 10),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: a.isRead
                    ? Colors.transparent
                    : AppTheme.primary,
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    a.title,
                    style: TextStyle(
                      color: a.isRead ? Colors.white54 : Colors.white,
                      fontSize: 14,
                      fontWeight: a.isRead
                          ? FontWeight.normal
                          : FontWeight.bold,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    a.body,
                    style: TextStyle(
                      color: a.isRead
                          ? Colors.white38
                          : Colors.white60,
                      fontSize: 12,
                      height: 1.4,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l10n.socialNotificationsPageAnnouncementDateShort(
                      a.publishedAt.year,
                      a.publishedAt.month,
                      a.publishedAt.day,
                    ),
                    style: const TextStyle(
                        color: Colors.white38, fontSize: 10),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NotificationTile extends StatelessWidget {
  final AppNotification notif;
  final VoidCallback onTap;

  const _NotificationTile({required this.notif, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final iconData = _iconFor(notif.notifType);
    final iconColor = _colorFor(notif.notifType);

    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: notif.isRead
              ? Colors.transparent
              : AppTheme.primary.withValues(alpha: 0.06),
          border: Border(
              bottom: BorderSide(
                  color: Colors.white.withValues(alpha: 0.06))),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // アイコン
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(iconData, color: iconColor, size: 20),
            ),
            const SizedBox(width: 12),

            // テキスト
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          notif.title,
                          style: TextStyle(
                            color: notif.isRead
                                ? Colors.white60
                                : Colors.white,
                            fontWeight: notif.isRead
                                ? FontWeight.normal
                                : FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      if (!notif.isRead)
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: AppTheme.primary,
                            shape: BoxShape.circle,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    notif.body,
                    style: const TextStyle(
                        color: Colors.white38, fontSize: 12),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _formatTime(l10n, notif.createdAt),
                    style: const TextStyle(
                        color: Colors.white24, fontSize: 10),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 【BUG-63】Backend Notification.TYPE_CHOICES（api/models/social.py:51-61）と完全突合。
  IconData _iconFor(String type) {
    switch (type) {
      case 'friend_request':
        return Icons.person_add;
      case 'friend_accepted':
        return Icons.people;
      case 'message':
        return Icons.chat_bubble;
      case 'level_up':
        return Icons.arrow_upward;
      case 'streak_alert':
        return Icons.local_fire_department;
      case 'title_unlocked':
        return Icons.emoji_events;
      case 'gift':
        return Icons.card_giftcard;
      case 'quest':
        return Icons.assignment_turned_in;
      case 'achievement':
        return Icons.workspace_premium;
      default:
        return Icons.notifications;
    }
  }

  Color _colorFor(String type) {
    switch (type) {
      case 'friend_request':
      case 'friend_accepted':
        return AppTheme.primary;
      case 'message':
        return Colors.blue;
      case 'level_up':
        return AppTheme.expColor;
      case 'streak_alert':
        return Colors.orange;
      case 'title_unlocked':
        return AppTheme.expColor;
      case 'gift':
        return AppTheme.diamond;
      case 'quest':
        return AppTheme.primary;
      case 'achievement':
        return AppTheme.diamond;
      default:
        return Colors.white54;
    }
  }

  /// 【FEAT-489 Phase 2D】相対時刻ラベルを arb 化。build() で解決済みの [l10n] を
  /// 受け取る (StatelessWidget のヘルパーメソッドで BuildContext を持ち回さない)。
  String _formatTime(AppLocalizations l10n, String iso) {
    try {
      final dt = DateTime.parse(iso).toLocal();
      final now = DateTime.now();
      final diff = now.difference(dt);
      if (diff.inMinutes < 1) return l10n.socialNotificationsPageTimeJustNow;
      if (diff.inHours < 1) {
        return l10n.socialNotificationsPageTimeMinutesAgo(diff.inMinutes);
      }
      if (diff.inDays < 1) {
        return l10n.socialNotificationsPageTimeHoursAgo(diff.inHours);
      }
      if (diff.inDays < 7) {
        return l10n.socialNotificationsPageTimeDaysAgo(diff.inDays);
      }
      return '${dt.month}/${dt.day}';
    } catch (_) {
      return '';
    }
  }
}
