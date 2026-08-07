import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../habits/providers/habits_provider.dart';  // 【2026-07-05】ガチャチケット合計計算用
import '../../social/providers/social_provider.dart';  // unreadNotifCountProvider

/// 【新規 (2026-07-05)】ギルド画面右上のハンバーガーメニューから展開される
/// `endDrawer` 用ウィジェット。
///
/// バトル準備 (装備・所持品・ステータス確認等) の動線を集約する目的で、
/// AppBar に散らばっていた「編成・装備」「ショップ」アイコンを本 Drawer に統合。
///
/// 表示内容 (上から、バトル準備 → 経済 → ソーシャル → システムの順):
/// - ステータス (キャラクター 6 stat の Lv 確認、バトル能力の根拠)
/// - 装備・編成 (PartyEditDialog、剣アイコン)
/// - キャラ変更 (CharacterPage、active_character の切替)
/// - 所持品リスト (ShopPage の inventory モード、所持ポーション/武器/チケット)
/// - ショップ (ShopPage の shop モード、購入)
/// - ガチャ (GachaPage、所持チケット数 Badge 付き、HomeDrawer と同パターン)
/// - フレンド (フレンド一覧、ソーシャル動線)
/// - お知らせ (未読 Badge 付き)
/// - 設定 (SettingsPage、システム系)
///
/// HomeDrawer (features/habits/widgets/home_drawer.dart) と同 Material 3 パターン。
/// 配置: guild_page.dart の Scaffold に `endDrawer: const GuildDrawer(...)` で設定。
class GuildDrawer extends ConsumerWidget {
  const GuildDrawer({
    super.key,
    required this.onOpenPartyEdit,
  });

  /// 「装備・編成」タップ時に guild_page の PartyEditDialog を開くコールバック。
  /// Drawer 側から showGeneralDialog を呼ぶと context 分離 (root vs ShellRoute) の
  /// 制約があるため、guild_page が既に持っている `_openPartyEditDialog` を経由。
  /// Drawer は Navigator.pop 後にコールバックを呼ぶだけ、context 選択は呼出側に任せる。
  final VoidCallback onOpenPartyEdit;

  /// Drawer を閉じてから route push (BUG-65 系の dialog 内 navigation race 対策と
  /// 同じ配慮: endDrawer では発生しないが UX として閉じる動きを明示)。
  void _navigateTo(BuildContext context, String route) {
    Navigator.of(context).pop();
    context.push(route);
  }

  /// Drawer を閉じてから callback 実行 (装備・編成 dialog 開放用)。
  void _closeAndInvoke(BuildContext context, VoidCallback callback) {
    Navigator.of(context).pop();
    callback();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return Drawer(
      // 【2026-07-05】Material 3 default (304) では ListTile の余白が目立って
      // いたため 260 に絞る。最長ラベル (「装備・編成」「所持品リスト」等) が
      // 収まる最小幅を目安に、視覚ノイズを削減。HomeDrawer と同値。
      width: 260,
      backgroundColor: AppTheme.surface,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── ヘッダー ─────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
              child: Row(
                children: [
                  const Icon(Icons.castle_outlined,
                      color: AppTheme.primary, size: 22),
                  const SizedBox(width: 10),
                  Text(
                    l10n.guildDrawerTitle,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white12, height: 1),

            // ── ステータス ────────────────────────────────────────────
            // 6 stat (運動力 / 学習力 / 健康力 / 精神力 / 創造力 / 貢献力) の Lv
            // 確認。バトル能力の根拠 (FEAT-333 で HP / ATK 等に連動) を可視化。
            ListTile(
              leading:
                  const Icon(Icons.bar_chart_outlined, color: Colors.white70),
              title: Text(
                l10n.guildDrawerStatusLabel,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              onTap: () => _navigateTo(context, AppRoutes.stats),
            ),
            // ── 装備・編成 (剣アイコン、PartyEditDialog) ────────────────
            // FEAT-304 の PartyEditDialog を呼び出す。ジョブ動的変更 + 装備閲覧の
            // v1.0 軽量版。ユーザー指定「剣アイコン」を採用。
            ListTile(
              leading: const Icon(Icons.gavel, color: Colors.white70),
              title: Text(
                l10n.guildDrawerEquipmentLabel,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              onTap: () => _closeAndInvoke(context, onOpenPartyEdit),
            ),
            // ── キャラ変更 (CharacterPage、active_character 切替) ──────
            // 装備・編成の直後に配置。「誰が戦うか」の選択は装備選択と並ぶ
            // バトル準備のコア動線。所持キャラ一覧 + active 切替 UI (character_page)。
            ListTile(
              leading:
                  const Icon(Icons.face_outlined, color: Colors.white70),
              title: Text(
                l10n.guildDrawerCharacterLabel,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              onTap: () => _navigateTo(context, AppRoutes.character),
            ),
            // ── 所持品リスト (Shop inventory モード) ────────────────────
            // ShopPage を ?inventory=true で開き、FEAT-126 の inventory モードで
            // 初期表示。所持ポーション / 武器 / チケット等の一覧確認用。
            ListTile(
              leading: const Icon(Icons.inventory_2_outlined,
                  color: Colors.white70),
              title: Text(
                l10n.guildDrawerInventoryLabel,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              onTap: () =>
                  _navigateTo(context, '${AppRoutes.shop}?inventory=true'),
            ),
            // ── ショップ (Shop 購入モード) ─────────────────────────────
            ListTile(
              leading: const Icon(Icons.shopping_bag_outlined,
                  color: Colors.white70),
              title: Text(
                l10n.guildDrawerShopLabel,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              onTap: () => _navigateTo(context, AppRoutes.shop),
            ),
            // ── ガチャ (所持チケット合計 Badge 付き) ────────────────────
            // ショップの直後、経済系グループに配置。HomeDrawer「ガチャ」と同じ
            // 所持チケット合計 (daily + weekly + monthly) の Badge.count パターン。
            // ギルド (バトル) で得たコイン → ショップでチケット交換 → ガチャで報酬
            // という自然な循環動線を drawer 内で完結させる。
            Consumer(
              builder: (_, ref, __) {
                final player = ref.watch(playerNotifierProvider).valueOrNull;
                final totalTickets = (player?.dailyTickets ?? 0) +
                    (player?.weeklyTickets ?? 0) +
                    (player?.monthlyTickets ?? 0);
                return ListTile(
                  leading: const Icon(Icons.card_giftcard_outlined,
                      color: Colors.white70),
                  title: Text(
                    l10n.guildDrawerGachaLabel,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  trailing: totalTickets > 0
                      ? Badge.count(
                          count: totalTickets,
                          textStyle: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            height: 1.0,
                          ),
                          largeSize: 18,
                          padding:
                              const EdgeInsets.symmetric(horizontal: 5),
                          child: const SizedBox(width: 1, height: 18),
                        )
                      : null,
                  onTap: () => _navigateTo(context, AppRoutes.gacha),
                );
              },
            ),
            // ── フレンド ─────────────────────────────────────────────
            ListTile(
              leading:
                  const Icon(Icons.people_outline, color: Colors.white70),
              title: Text(
                l10n.guildDrawerFriendsLabel,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              onTap: () => _navigateTo(context, AppRoutes.friendList),
            ),
            // ── お知らせ (未読 Badge) ──────────────────────────────────
            // HomeDrawer の「お知らせ」と同 Material 3 Badge.count パターン。
            Consumer(
              builder: (_, ref, __) {
                final unread = ref.watch(unreadNotifCountProvider);
                return ListTile(
                  leading: const Icon(Icons.campaign_outlined,
                      color: Colors.white70),
                  title: Text(
                    l10n.guildDrawerAnnouncementsLabel,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  trailing: unread > 0
                      ? Badge.count(
                          count: unread,
                          textStyle: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            height: 1.0,
                          ),
                          largeSize: 18,
                          padding:
                              const EdgeInsets.symmetric(horizontal: 5),
                          child: const SizedBox(width: 1, height: 18),
                        )
                      : null,
                  onTap: () => _navigateTo(context, AppRoutes.notifications),
                );
              },
            ),
            // ── 設定 (SettingsPage、システム系、Drawer 最下部の慣例) ────
            ListTile(
              leading:
                  const Icon(Icons.settings_outlined, color: Colors.white70),
              title: Text(
                l10n.guildDrawerSettingsLabel,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              onTap: () => _navigateTo(context, AppRoutes.settings),
            ),

            const Spacer(),
            const Divider(color: Colors.white12, height: 1),
            // ── フッター (画面案内) ────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Text(
                l10n.guildDrawerFooterSabi_message,
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
