import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/character_asset.dart';            // 【BUG-100 followup】設定キャラアバター描画
import '../../../core/utils/friend_id_formatter.dart';         // 【2026-07-02】12 桁化 + 4-4-4 表示
// 【2026-06-29】ゲストモード開放に伴い GuestLinkPromptCard の連携誘導は撤去 (FEAT-180 反転)。
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/sabi_error_chip.dart';
import '../../../shared/widgets/sabi_loading_skeleton.dart';  // FEAT-202
import '../models/social_models.dart';
import '../providers/social_provider.dart';

class FriendListPage extends ConsumerWidget {
  const FriendListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    // 【2026-06-29】FEAT-180 のゲスト連携誘導ガードを撤去。
    // Backend の全フレンド view が IsAuthenticatedOrGuest に変更されたため、
    // ゲストモードでもフレンド ID 検索・申請・承認・プロフィール閲覧・ギフト送受信
    // すべてが動作する。ゲスト PlayerProfile は起動時に guest-init API で作成され、
    // その時点で friend_id (8 桁数字) が自動生成されているため、ゲスト同士 +
    // ゲスト⇄正規プレイヤーの全パターンでフレンド関係が構築可能。
    // P0-6: unwrapPrevious で戻り遷移時のスピナーちらつきを防止
    final friendsAsync = ref.watch(friendListProvider).unwrapPrevious();
    final requestsAsync = ref.watch(incomingRequestsProvider).unwrapPrevious();

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.socialFriendListPageTitle),
        // 【FEAT-448 (2026-06-20)】戻る IconButton を明示。
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: l10n.socialFriendListPageBackTooltip,
          onPressed: () {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go(AppRoutes.home);
            }
          },
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_add_outlined),
            tooltip: l10n.socialFriendListPageAddTooltip,
            onPressed: () => context.push(AppRoutes.friendAdd),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(friendListProvider);
          ref.invalidate(incomingRequestsProvider);
        },
        child: CustomScrollView(
          slivers: [
            // ── 受信中のフレンドリクエスト ─────────────────────────
            requestsAsync.when(
              data: (requests) {
                if (requests.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());
                return SliverToBoxAdapter(
                  child: _IncomingRequestsSection(
                    requests: requests,
                    onAccept: (id) async {
                      await ref.read(socialServiceProvider).acceptRequest(id);
                      ref.invalidate(incomingRequestsProvider);
                      ref.invalidate(friendListProvider);
                    },
                    onDecline: (id) async {
                      await ref.read(socialServiceProvider).declineRequest(id);
                      ref.invalidate(incomingRequestsProvider);
                    },
                  ),
                );
              },
              loading: () => const SliverToBoxAdapter(child: SizedBox.shrink()),
              // P0-2: 受信リクエスト取得に失敗した時は静かに通知する
              error: (_, __) => SabiErrorChipSliver(
                message: l10n.socialFriendListPageIncomingRequestLoadError,
              ),
            ),

            // ── フレンド一覧 ───────────────────────────────────────
            friendsAsync.when(
              data: (data) {
                if (data.friends.isEmpty && data.sentRequests.isEmpty) {
                  return SliverToBoxAdapter(child: _buildEmpty(context));
                }
                return SliverList(
                  delegate: SliverChildListDelegate([
                    if (data.friends.isNotEmpty) ...[
                      _sectionHeader(l10n.socialFriendListPageFriendsSectionHeader(data.friends.length)),
                      ...data.friends.map((f) => _FriendTile(
                            entry: f,
                            onTap: () => context.push(
                                AppRoutes.friendProfile
                                    .replaceFirst(':playerId', '${f.player.id}')),
                            // 【FEAT-446 (2026-06-20)】onMessage 廃止: フレンド間メッセージ
                            // 機能廃止に伴い _FriendTile からも message button 撤去。
                            onRemove: () async {
                              final ok = await _confirmRemove(context, f.player.name);
                              if (ok) {
                                await ref.read(socialServiceProvider).removeFriend(f.friendshipId);
                                ref.invalidate(friendListProvider);
                              }
                            },
                          )),
                    ],
                    if (data.sentRequests.isNotEmpty) ...[
                      _sectionHeader(l10n.socialFriendListPageSentRequestsSectionHeader),
                      ...data.sentRequests.map((r) => _SentRequestTile(request: r)),
                    ],
                    const SizedBox(height: 24),
                  ]),
                );
              },
              // 【FEAT-202】読み込み中の温度統一。回転する円ではなく実カード形状を
              // Shimmer でモックし、「もうすぐここに来ます」を予告する。
              loading: () => const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: FriendListSkeleton(count: 5),
                ),
              ),
              error: (e, _) => SliverFillRemaining(
                child: Center(
                  child: Text(l10n.socialFriendListPageLoadErrorSabi_message,
                      style: const TextStyle(color: Colors.red)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(String label) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
        child: Text(label,
            style: const TextStyle(
                color: Colors.white54,
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 1)),
      );

  Widget _buildEmpty(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.people_outline,
                size: 64, color: Colors.white.withValues(alpha: 0.3)),
            const SizedBox(height: 16),
            Text(l10n.socialFriendListPageEmptyTitle,
                style: const TextStyle(fontSize: 18, color: Colors.white70)),
            const SizedBox(height: 8),
            Text(l10n.socialFriendListPageEmptySubtitle,
                style: const TextStyle(fontSize: 14, color: Colors.white38)),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => context.push(AppRoutes.friendAdd),
              icon: const Icon(Icons.person_add),
              label: Text(l10n.socialFriendListPageEmptyAddButton),
            ),
          ],
        ),
      ),
    );
  }

  Future<bool> _confirmRemove(BuildContext context, String name) async {
    final l10n = AppLocalizations.of(context)!;
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(l10n.socialFriendListPageRemoveDialogTitle),
            content: Text(l10n.socialFriendListPageRemoveDialogBody(name)),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(l10n.commonCancel)),
              TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  style:
                      TextButton.styleFrom(foregroundColor: Colors.red),
                  child: Text(l10n.socialFriendListPageRemoveButton)),
            ],
          ),
        ) ??
        false;
  }
}

// ── 受信リクエストセクション ─────────────────────────────────────────────────

class _IncomingRequestsSection extends StatelessWidget {
  final List<IncomingRequest> requests;
  final void Function(int) onAccept;
  final void Function(int) onDecline;

  const _IncomingRequestsSection({
    required this.requests,
    required this.onAccept,
    required this.onDecline,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.person_add,
                  color: AppTheme.primary, size: 16),
              const SizedBox(width: 6),
              Text(
                l10n.socialFriendListPageIncomingRequestsHeader(requests.length),
                style: TextStyle(
                    color: AppTheme.primary,
                    fontWeight: FontWeight.bold,
                    fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...requests.map((r) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    // 【BUG-100 followup (2026-06-14)】受信リクエスト送信者の設定キャラ
                    CharacterAsset.circleWidget(
                      identifier: r.fromPlayer.activeCharacterImagePath,
                      keyFallback: r.fromPlayer.activeCharacterKey,
                      size: 36,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(r.fromPlayer.name,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13)),
                          Text('Lv.${r.fromPlayer.level}',
                              style: const TextStyle(
                                  color: Colors.white38, fontSize: 11)),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: () => onDecline(r.id),
                      style: TextButton.styleFrom(
                          foregroundColor: Colors.white38,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8)),
                      child: Text(l10n.socialFriendListPageDeclineButton,
                          style: const TextStyle(fontSize: 12)),
                    ),
                    ElevatedButton(
                      onPressed: () => onAccept(r.id),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primary,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(l10n.socialFriendListPageAcceptButton,
                          style: const TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              )),
        ],
      ),
    );
  }
}

// ── フレンドタイル ───────────────────────────────────────────────────────────

class _FriendTile extends StatelessWidget {
  final FriendEntry entry;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _FriendTile({
    required this.entry,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final p = entry.player;
    return ListTile(
      onTap: onTap,
      // 【BUG-100 followup (2026-06-14)】フレンドの設定キャラアバター
      leading: CharacterAsset.circleWidget(
        identifier: p.activeCharacterImagePath,
        keyFallback: p.activeCharacterKey,
        size: 44,
      ),
      title: Text(p.name,
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.bold)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Lv.${p.level}  ID: ${formatFriendId(p.friendId)}',
              style: const TextStyle(color: Colors.white38, fontSize: 11)),
          if (p.title != null)
            Text(p.title!,
                style: const TextStyle(
                    color: Colors.orange, fontSize: 11)),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 【FEAT-446 (2026-06-20)】メッセージ IconButton 削除: メッセージ機能廃止。
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert,
                color: Colors.white38, size: 20),
            onSelected: (v) {
              if (v == 'remove') onRemove();
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                  value: 'remove',
                  child: Text(l10n.socialFriendListPageRemoveFriendMenu,
                      style: const TextStyle(color: Colors.red))),
            ],
          ),
        ],
      ),
    );
  }
}

// ── 送信済みリクエストタイル ─────────────────────────────────────────────────

class _SentRequestTile extends StatelessWidget {
  final SentRequest request;
  const _SentRequestTile({required this.request});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final p = request.toPlayer;
    return ListTile(
      // 【BUG-100 followup (2026-06-14)】送信先フレンドの設定キャラアバター
      // (承認待ち状態を示すため Opacity で薄く表示)
      leading: Opacity(
        opacity: 0.6,
        child: CharacterAsset.circleWidget(
          identifier: p.activeCharacterImagePath,
          keyFallback: p.activeCharacterKey,
          size: 40,
        ),
      ),
      title: Text(p.name,
          style: const TextStyle(color: Colors.white60)),
      subtitle: Text('ID: ${formatFriendId(p.friendId)}',
          style: const TextStyle(color: Colors.white38, fontSize: 11)),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.white12,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(l10n.socialFriendListPagePendingChip,
            style: const TextStyle(color: Colors.white38, fontSize: 11)),
      ),
    );
  }
}
