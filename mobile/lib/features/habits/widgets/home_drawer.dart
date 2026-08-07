import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../../core/utils/friend_id_formatter.dart';  // 【2026-07-02】12 桁化 + 4-4-4 表示
import '../../social/providers/social_provider.dart';  // unreadNotifCountProvider
import '../providers/habits_provider.dart';  // playerNotifierProvider

/// 【FEAT-464 (2026-06-23)】ホーム画面右上のハンバーガーメニューから展開される
/// `endDrawer` 用ウィジェット。
///
/// 表示内容 (上から):
/// - ユーザ名 + friend_id (タップで ID をクリップボードコピー)
/// - 使い方ガイド / 眠る世界 / ステータス / キャラ変更 / 実績 / ガチャ /
///   フレンド / ダイヤを購入 / お知らせ / 設定 への ListTile 動線
/// - バージョン情報 (PackageInfo.fromPlatform、FutureBuilder で非同期取得)
///
/// 【2026-06-27】「フレンド」を設定画面のソーシャルセクションから本 Drawer に
/// 移管 (3 タップ → 2 タップに短縮)。配置は「個人 → 他者 → 経済 → システム」の
/// 流れで実績の次・ダイヤ購入の前。
///
/// 【2026-07-08 FEAT-485 拡張】使い方ガイド (アプリ内 WebView) を最上位に配置、
/// SettingsPage サポートセクションから移管:
/// - 「困った時にすぐ見られる」導線を「マイページ → サポート → 使い方ガイド」
///   (3 タップ) から「ホーム → ハンバーガー → 使い方ガイド」(2 タップ) に短縮
/// - 「困ったらまずここ」の user 期待に沿って **最上位** 配置 (Drawer の 1 番目)
/// - 同時に「ホーム」タイルを削除。ホーム画面から drawer を開く経路のため、
///   ホーム tile 自体が冗長 (BottomNav にもホームタブあり)
///
/// 配置: home_page.dart の Scaffold に `endDrawer: const HomeDrawer()` で設定。
/// 開閉: AppBar actions の `IconButton(Icons.menu)` から `Scaffold.of(ctx)
/// .openEndDrawer()` を呼び出す。
class HomeDrawer extends ConsumerStatefulWidget {
  const HomeDrawer({super.key});

  @override
  ConsumerState<HomeDrawer> createState() => _HomeDrawerState();
}

class _HomeDrawerState extends ConsumerState<HomeDrawer> {
  // 【FEAT-464 Pre-mortem #3】PackageInfo 取得は 1 回限りキャッシュ。
  // Drawer 開閉のたびに再取得すると体感遅延が出るため State に保持。
  Future<PackageInfo>? _packageInfoFuture;

  // 【FEAT-479 hotfix (2026-07-06)】スクロール直感 UI 用: Scrollbar と
  // ListView + 下端 chevron overlay で controller を共有し、scroll 位置に
  // 応じて chevron opacity をアニメーション。
  final ScrollController _drawerScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _packageInfoFuture = PackageInfo.fromPlatform();
  }

  @override
  void dispose() {
    _drawerScrollController.dispose();
    super.dispose();
  }

  Future<void> _copyFriendId(String friendId) async {
    // 【2026-07-02】コピーは常に `-` なしの raw 数字。
    await Clipboard.setData(
        ClipboardData(text: stripFriendIdSeparators(friendId)));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.habitDrawerCopyIdToast),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  void _navigateTo(String route) {
    // Drawer を閉じてから遷移 (showModalBottomSheet の whenComplete race
    // 等は endDrawer では発生しないが、UX として閉じる動きを明示する)。
    Navigator.of(context).pop();
    // BottomNav 配下 (ホーム) は go、それ以外は push。
    // 【FEAT-464 整合】マイページは FEAT-464 で BottomNav から外され HomeDrawer
    // 経由動線に集約された。push にすることで AppBar に自動的に戻るボタンが表示
    // され、システム back gesture でホームへ戻れるようにする。
    // 注: GuestLinkPromptCard / backup_prompt_sheet 等の `?openAccountLink=true`
    // 経路は引き続き `context.go` で動作 (本 HomeDrawer 経路だけ push 化)。
    if (route == AppRoutes.home) {
      context.go(route);
    } else {
      context.push(route);
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = ref.watch(playerNotifierProvider).valueOrNull;
    final l10n = AppLocalizations.of(context)!;

    return Drawer(
      // 【2026-07-05】Material 3 default (304) では ListTile の余白が目立って
      // いたため 260 に絞る。項目ラベル (最長「ダイヤを購入」) + trailing Badge
      // が全て収まる最小幅を目安に、視覚ノイズを削減。GuildDrawer と同値。
      width: 260,
      backgroundColor: AppTheme.surface,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── ユーザ情報カード (タップで ID コピー) ─────────────────
            _UserHeader(
              name: player?.name ?? '...',
              friendId: player?.friendId ?? '',
              onCopyTap: player?.friendId.isNotEmpty == true
                  ? () => _copyFriendId(player!.friendId)
                  : null,
            ),
            const Divider(color: Colors.white12, height: 1),

            // ── 画面遷移メニュー (縦長端末 overflow 対策で scrollable、
            //    【FEAT-479 hotfix (2026-07-06)】Phase 2b で「パズル世界」項目を
            //    追加した結果、小型画面で BOTTOM OVERFLOWED BY 43 PIXELS が
            //    発生していた。header + version を固定、間の tile 群のみ
            //    Expanded + ListView で scroll 可能にする) ──────────
            //
            // 【FEAT-479 hotfix (2026-07-06)】スクロール直感 UI 3 段構え:
            //   ① Scrollbar(thumbVisibility=true) で常時 bar 表示
            //   ② 下端に "▼ 続く" chevron を Stack overlay、scroll position に
            //      応じて opacity をアニメーション、bottom 到達で自動 fade out
            //
            // 【FEAT-479 hotfix v2 (2026-07-06)】ゲストモードで drawer 描画が
            // 破綻していた bug への対応で、以下を簡素化:
            //   - ShaderMask(BlendMode.dstIn) を撤去 (下端フェード効果は chevron
            //     で担保するため冗長)
            //   - Theme(ScrollbarThemeData WidgetStateProperty) wrapper を撤去、
            //     Scrollbar の inline プロパティに集約
            //   - Stack の複雑度を下げて subtree throw リスクを縮小
            Expanded(
              child: Stack(
                children: [
                  Scrollbar(
                    controller: _drawerScrollController,
                    thumbVisibility: true,
                    thickness: 4,
                    radius: const Radius.circular(4),
                    child: ListView(
                      controller: _drawerScrollController,
                      padding: const EdgeInsets.only(right: 6),
                      children: [
            // 【2026-07-08 FEAT-485】使い方ガイドを Drawer 最上位に配置
            // (旧 SettingsPage サポートセクションから移管):
            // - 「困った時にすぐ見られる」導線を 3 タップ → 2 タップに短縮
            // - 「困ったらまずここ」の user 期待に沿って最上位 (1 番目) 配置
            // - AppRoutes.help ('/settings/help') は go_router に top-level route
            //   として登録済 (path 名は /settings/ 接頭辞だが URL 構造上の慣習で、
            //   ShellRoute 配下ではなく context.push で全画面 push 遷移する)
            // - context.push → HelpWebViewPage (アプリ内 WebView) で
            //   sabiowl-home-pages の help.html を表示
            ListTile(
              leading: const Icon(Icons.help_center_outlined,
                  color: Colors.white70),
              title: Text(
                l10n.habitDrawerMenuGuide,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              onTap: () => _navigateTo(AppRoutes.help),
            ),
            // 【2026-07-08 FEAT-485】「ホーム」タイル削除 (最上位に居た):
            // - ホーム画面から drawer を開く経路のため、ホーム tile 自体が冗長
            // - BottomNav にも「ホーム」タブがあり drawer 経由の再導入は不要
            // - 削除により「使い方ガイド」を最上位配置 + drawer 全体を 1 段短縮
            //
            // 【FEAT-479 (2026-07-06)】「眠る世界」導線を最上位付近に配置。
            // 「習慣達成→かけら獲得」のコアループに直結するため、ユーザーの
            // 意識に上りやすい上位位置に昇格 (旧「ダイヤを購入」下配置から変更)。
            // 旧呼称「パズル世界」は Sabiowl 世界観 (Sabi 静穏原則) に合わせて
            // 「眠る世界」に統一 (route path / provider 等の物理識別子は
            // puzzle_world のまま維持)。
            ListTile(
              leading: const Icon(Icons.extension_outlined,
                  color: Colors.white70),
              title: Text(
                l10n.habitDrawerMenuSleepingWorld,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              onTap: () => _navigateTo(AppRoutes.puzzleWorld),
            ),
            // 【2026-07-05】設定は Drawer 最下部 (お知らせの下) に移動。
            // 「システム系」項目として GuildDrawer と統一 (設定は普段触らないため
            // 最上位からは外し、頻用のバトル準備系 (ステータス/キャラ変更/実績) を
            // 上部に集約)。
            // 【新規 (2026-06-26)】ステータス画面 (/stats) への導線。
            // 6 ステータス (運動力 / 学習力 / 健康力 / 精神力 / 創造力 / 貢献力)
            // の確認頻度が高く、設定経由 (実績タイルからクイックナビ
            // バナーを経る間接動線のみ) では到達コストが高い。HomeDrawer の
            // メインメニューに昇格させて 1 タップでアクセスできるよう改善。
            ListTile(
              leading: const Icon(Icons.bar_chart_outlined,
                  color: Colors.white70),
              title: Text(
                l10n.habitDrawerMenuStats,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              onTap: () => _navigateTo(AppRoutes.stats),
            ),
            // 【新規 (2026-07-05)】キャラ変更 (CharacterPage) への導線。
            // active_character の切替 = プレイヤーの「見た目とバトル参加者」を
            // 決めるコア動線。ステータスの直後に配置してキャラクター系の
            // 論理グループを形成 (ステータス → キャラ変更 → 実績)。
            // stats_page.dart の _EconomyCard 3 列 (2026-07-05 撤去) で提供
            // していた導線を Drawer 経由に集約。
            ListTile(
              leading:
                  const Icon(Icons.face_outlined, color: Colors.white70),
              title: Text(
                l10n.habitDrawerMenuCharacter,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              onTap: () => _navigateTo(AppRoutes.character),
            ),
            // 【新規 (2026-06-26)】実績画面 (/achievements) への導線。
            // 30 件 (FEAT-Z で 13 → 30 拡張済) のバッジ収集は習慣化アプリの
            // モチベ中核要素のため、設定経由の間接動線ではなく HomeDrawer 直結に。
            ListTile(
              leading: const Icon(Icons.emoji_events_outlined,
                  color: Colors.white70),
              title: Text(
                l10n.habitDrawerMenuAchievements,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              onTap: () => _navigateTo(AppRoutes.achievements),
            ),
            // 【新規 (2026-07-05)】ガチャ画面 (/gacha) への導線。
            // BottomNav に載っていない gacha を HomeDrawer 経由で 1 タップ到達可に。
            // ガチャチケット (daily + weekly + monthly) を所持している場合は Badge.count
            // で枚数を表示し「今すぐガチャを引けます」旨をユーザーに視覚的に伝える。
            // お知らせ trailing の Badge パターン (FEAT-309) と同じ Material 3 仕様。
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
                    l10n.habitDrawerMenuGacha,
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
                          padding: const EdgeInsets.symmetric(horizontal: 5),
                          // お知らせ Badge と同じ trailing パターン
                          child: const SizedBox(width: 1, height: 18),
                        )
                      : null,
                  onTap: () => _navigateTo(AppRoutes.gacha),
                );
              },
            ),
            // 【新規 (2026-06-27)】フレンド画面 (/friends) への導線。
            // 旧 settings_page の「ソーシャル」セクション → HomeDrawer に移管
            // (整合性 + 1 タップ短縮: 3 タップ → 2 タップ)。配置は「個人 (実績) →
            // 他者 (フレンド) → 経済 (ダイヤ購入)」の流れに沿う。
            ListTile(
              leading: const Icon(Icons.people_outline, color: Colors.white70),
              title: Text(
                l10n.habitDrawerMenuFriends,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              onTap: () => _navigateTo(AppRoutes.friendList),
            ),
            // 【新規 (2026-06-26)】ダイヤ購入画面 (/shop/diamond-pack) への導線。
            // v1.0.1 IAP 投入 (FEAT-436) に合わせて、購入導線を可視化。
            // 押し売り感を出さないよう icon は控えめ、ラベルも素朴な「ダイヤを購入」。
            ListTile(
              leading: const Icon(Icons.shopping_cart_outlined,
                  color: Colors.white70),
              title: Text(
                l10n.habitDrawerMenuBuyDiamonds,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              onTap: () => _navigateTo(AppRoutes.diamondPack),
            ),
            // 「お知らせ」項目 — 未読数があれば trailing に Badge.count で表示。
            // FEAT-309 と同じ Material 3 標準 Badge.count パターン (iOS 可読性
            // 確保のため largeSize/textStyle/padding を明示)。
            Consumer(
              builder: (_, ref, __) {
                final unread = ref.watch(unreadNotifCountProvider);
                return ListTile(
                  leading: const Icon(Icons.campaign_outlined, color: Colors.white70),
                  title: Text(
                    l10n.habitDrawerMenuNotifications,
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
                          padding: const EdgeInsets.symmetric(horizontal: 5),
                          // 数字の右側に十分な余白を取るため SizedBox(width: 1)
                          // を child に置く (Badge 単独で trailing 表示する慣用)。
                          child: const SizedBox(width: 1, height: 18),
                        )
                      : null,
                  onTap: () => _navigateTo(AppRoutes.notifications),
                );
              },
            ),
            // 【2026-07-05】設定 (SettingsPage) を Drawer 最下部に配置。
            // 旧位置: ホームの直後 (2 番目) → お知らせの下 (最下部) に移動。
            // 頻用のバトル準備系を上部に集約し、システム系を最下部の慣例的配置に統一。
            ListTile(
              leading: const Icon(Icons.settings_outlined, color: Colors.white70),
              title: Text(
                l10n.habitDrawerMenuSettings,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              onTap: () => _navigateTo(AppRoutes.settings),
            ),
                    ],
                  ),
                  ),
                  // 【FEAT-479 hotfix v3 (2026-07-06)】旧 AnimatedBuilder +
                  // ScrollController watch の chevron overlay を撤去。
                  //
                  // 症状: ゲストモードで drawer 開扉時に tile 領域が赤矩形化、
                  //      スクロールすると赤が消える。
                  // 診断: AnimatedBuilder が ScrollController の notify 経由で
                  //      毎フレーム rebuild → Flutter debug の repaint
                  //      highlighting (赤) が乗った可能性が高い。
                  //      通常ユーザーで見えないのは、通知内容 (badge count 等)
                  //      が異なり rebuild タイミングが違うため。
                  // 対応: chevron の scroll-driven opacity を撤廃、常時薄く
                  //      表示する静的 UI に変更。Scrollbar (常時可視) と
                  //      並行して「スクロール可能」を示す静的アイコン。
                  //      maxScrollExtent 判定は不要 (ListView 全 tile が
                  //      入りきる小型端末は現状想定なし、スクロール可能前提)。
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 6,
                    child: IgnorePointer(
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: AppTheme.primary.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            Icons.keyboard_arrow_down,
                            color: AppTheme.primary.withValues(alpha: 0.85),
                            size: 18,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white12, height: 1),

            // ── バージョン情報 (非同期取得、Pre-mortem S3) ───────────
            FutureBuilder<PackageInfo>(
              future: _packageInfoFuture,
              builder: (context, snapshot) {
                final l10n = AppLocalizations.of(context)!;
                final versionText = snapshot.hasData
                    ? l10n.habitDrawerVersion(snapshot.data!.version)
                    : l10n.habitDrawerVersionLoading;
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  child: Text(
                    versionText,
                    style: const TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// ユーザ名 + friend_id を 1 行にまとめた header。タップで ID コピー。
class _UserHeader extends StatelessWidget {
  const _UserHeader({
    required this.name,
    required this.friendId,
    required this.onCopyTap,
  });

  final String name;
  final String friendId;
  final VoidCallback? onCopyTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onCopyTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: AppTheme.primary.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.person, color: AppTheme.primary, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    // 【2026-07-02】12 桁化に伴い 4-4-4 (「0000-0000-0000」) 表示。
                    friendId.isEmpty
                        ? 'ID: -'
                        : 'ID: ${formatFriendId(friendId)}',
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
            ),
            if (onCopyTap != null)
              const Icon(Icons.copy_outlined, color: Colors.white38, size: 16),
          ],
        ),
      ),
    );
  }
}
