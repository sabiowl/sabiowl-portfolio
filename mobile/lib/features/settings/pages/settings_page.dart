import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';  // 【BUG-121】リリースノート Web 起動
import '../../../core/analytics/posthog_service.dart';  // 【FEAT-493】
import '../../../core/constants/app_urls.dart';  // 【FEAT-463】URL 定数集約
import '../../../core/l10n/app_locale.dart';  // 【FEAT-489 Phase 2G-a】表示言語切替
import '../../../core/providers/app_version_provider.dart';  // 【BUG-151】バージョンは pubspec が真実値
import '../../../core/router/app_router.dart';
import '../../../core/services/toast_center.dart';  // 【BUG-121】サビ口調エラー表示
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../../core/utils/email_mask.dart';            // FEAT-289
import '../../../shared/widgets/guest_promote_conflict_dialog.dart';  // 【2026-07-02】
import '../../auth/providers/auth_provider.dart';         // FEAT-183: isGuestModeProvider
import '../../auth/services/auth_service.dart';           // FEAT-189: GuestPromoteConflictException
import '../../auth/widgets/social_sign_in_button.dart';
import '../../habits/providers/habits_provider.dart';   // FEAT-181/183: playerNotifierProvider / habitsNotifierProvider
import '../../habits/providers/home_bootstrap_provider.dart';  // FEAT-183: homeBootstrapRawProvider
import '../providers/settings_provider.dart';
import '../../../core/api/api_client.dart';  // 【BUG-154】isGuestMode fallback
import '../logout_guard.dart';  // 【BUG-154】
import '../services/settings_service.dart';
import '../../challenge/services/challenge_notification_service.dart';  // 【FEAT-509】

// 【FEAT-249】`_kHealthEnabled` フラグ + ヘルスケアセクションは FEAT-71 で
// 隠蔽済みだった死コードのため物理削除。復元する場合は git history から取得可能。

class SettingsPage extends ConsumerStatefulWidget {
  /// 【FEAT-243】true のとき初回 build 完了後にアカウント連携シートを自動展開する。
  /// `app_router.dart` で `state.uri.queryParameters['openAccountLink'] == 'true'` のとき
  /// 注入される。ホーム上部バナー / GuestLinkPromptCard / バックアップシート の 3 経路から
  /// `context.go('${AppRoutes.settings}?openAccountLink=true')` で共通動線を提供。
  final bool openAccountLink;

  const SettingsPage({super.key, this.openAccountLink = false});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  // 【FEAT-420 → BUG-88 (2026-06-10)】予約 Switch UI 撤去に伴い _streakPendingLoading
  // 状態変数も削除。Backend の予約経路 (setStreakProtectionPending 等) は温存され
  // ているため、将来 UI 復活時はここに再追加する。

  // 【FEAT-506 (2026-07-29) 移動履歴】旧 Global toggle 状態 (_autoCreateEnabled) は
  // 本画面から削除。UI は timeline_defaults_page.dart 画面上部に集約 (Single source
  // of truth、コンテキスト近接配置)。SharedPreferences key `timeline_auto_create_enabled`
  // 自体は継続利用、timelineAutoCreateProvider の early return 判定は不変。

  // 【FEAT-509】チャレンジ結果通知 opt-in 状態
  bool _challengeResultNotifEnabled = false;

  @override
  void initState() {
    super.initState();
    // 【FEAT-243】クエリパラメータ経由で渡された openAccountLink=true なら
    // 初回 build 完了後にアカウント連携シートを自動展開（ゲストモードのホーム
    // 上部バナー / GuestLinkPromptCard / バックアップ案内 シートから共通動線）。
    if (widget.openAccountLink) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showAccountLinkSheet(context);
      });
    }
    // 【FEAT-509】チャレンジ結果通知の opt-in 状態を読み込む
    _loadChallengeNotifEnabled();
  }

  Future<void> _loadChallengeNotifEnabled() async {
    final service = ref.read(challengeNotificationServiceProvider);
    final enabled = await service.isEnabled();
    if (mounted) setState(() => _challengeResultNotifEnabled = enabled);
  }

  @override
  void didUpdateWidget(covariant SettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 【FEAT-243 hotfix】GuestLinkPromptCard 経路（/friends → /settings?openAccountLink=true）で
    // SettingsPage インスタンスが再利用されると initState が走らないため、props 更新でも
    // 自動展開を発火させる。
    //
    // 経緯: `AppRoutes.friendList` (/friends) は ShellRoute 外のフルスクリーンルート
    // （app_router.dart の friendList は ShellRoute から移動済）。`context.push('/friends')`
    // で friends ページが上に積まれるが、裏の SettingsPage は dispose されず mounted のまま。
    // そこから `context.go('/settings?openAccountLink=true')` で戻ると、Flutter の widget
    // reconciliation が「同じ型・同じ position・同じ key」を検出し既存 SettingsPage インスタンスを
    // 再利用 → openAccountLink prop は false→true に更新されるが initState は再実行されない。
    //
    // openAccountLink が false→true へのエッジトリガーで限定し、props が true 維持の状態で
    // 何度も rebuild されても再展開しない（多重 sheet 防止）。
    if (widget.openAccountLink && !oldWidget.openAccountLink) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showAccountLinkSheet(context);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      // 【SEC-12 (2026-XX-XX) → 撤回 (2026-06-26)】「設定」→「マイページ」改名は
      // ユーザー判断で撤回し、再度「設定」表示に戻した。HomeDrawer のラベルも
      // 同期 (home_drawer.dart)。URL `/settings` とクラス名 `SettingsPage` は
      // 後方互換のため当初から変更していない (本ラベル変更で実装と整合)。
      appBar: AppBar(title: Text(l10n.settingsPageTitle)),
      // 【FEAT-442 (2026-06-17)】プル to リフレッシュ。ホーム / カレンダー画面と
      // 同様に最上部より上にスクロールすると画面再読み込みできるよう対応。
      // 主要 provider (player / linkedAccounts / isGuestMode) を一斉 invalidate
      // することで、プロフィール / 連携状態 / ストリーク保護等のセクションが
      // 最新値で再描画される。
      body: RefreshIndicator(
        color: AppTheme.primary,
        onRefresh: () async {
          ref.invalidate(playerNotifierProvider);
          ref.invalidate(linkedAccountsProvider);
          ref.invalidate(isGuestModeProvider);
        },
        child: ListView(
          // ListView は default で AlwaysScrollableScrollPhysics 非適用なので、
          // 内容が画面に収まる場合でもプルできるよう明示。
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
          // ── アカウント ─────────────────────────────────────
          _SectionHeader(label: l10n.settingsPageSectionAccount),
          _SettingsTile(
            icon: Icons.person_outline,
            label: l10n.settingsPageTileProfileEdit,
            onTap: () => context.push(AppRoutes.profileEdit),
          ),
          // 【FEAT-396 (2026-05-31)】プライバシー設定タイル廃止。
          // 「習慣内容は常に非公開、継続日数は常に公開」固定化により設定 UI 不要。
          // プライバシーポリシー (アプリ情報セクション) でユーザーに明示。

          _SettingsTile(
            icon: Icons.link_outlined,
            label: l10n.settingsPageTileAccountLink,
            onTap: () => _showAccountLinkSheet(context),
          ),

          // 【FEAT-257 / FEAT-274 / FEAT-278 / FEAT-281】Google 連携済の場合のみ
          // Google カレンダーへ自動反映トグルを表示。
          // 旧仕様 (FEAT-258): 【Sabiowl】プレフィックス Tooltip → FEAT-274 で
          // extendedProperties 方式に移行したため Tooltip は FEAT-278 で削除済み。
          // 連携状態は `linkedAccountsProvider` から取得（FEAT-184 互換）。
          ..._buildGcalPushSection(context, ref),

          // 【FEAT-377 (2026-05-29)】ストリーク自動保護トグル。
          ..._buildStreakProtectionSection(context, ref),

          // 【削除 (2026-06-27)】「ダイヤを購入する」「達成 → 実績」「ソーシャル
          // → フレンド」タイル / セクションを HomeDrawer の動線重複として撤去。
          // HomeDrawer 側に集約 (home_drawer.dart の docstring 参照)。
          //   - 「ダイヤを購入する」 → AppRoutes.diamondPack (HomeDrawer から push)
          //   - 「実績」              → AppRoutes.achievements (HomeDrawer から push)
          //   - 「フレンド」          → AppRoutes.friendList (HomeDrawer から push)
          // 旧 FEAT-222 (達成セクション) / 旧「ソーシャル」セクションは本コミットで
          // 完全廃止。設定は「設定値変更 (リマインダー / ストリーク保護 / 連携 /
          // 各種法務リンク)」に純化。
          // 旧 FEAT-331 → FEAT-436 のダイヤ購入導線コメントは home_drawer.dart 側
          // (ダイヤを購入 ListTile) に移植済。

          // ── β 機能 ────────────────────────────────────────────
          ..._buildBetaFeaturesSection(context, ref),

          // 【FEAT-506 (2026-07-29) 移動履歴】タイムライン設定セクションは
          // timeline_defaults_page.dart (歯車ボタンから遷移) に集約したため削除。
          // 旧 _buildTimelineSettingsSection() も同時撤去。
          //
          // 【20260729 gameplay-review §2-2 対応】toggle 実体は移動維持
          // (Single source of truth) しつつ、settings からの発見性を回復する
          // ため 1 行ナビ項目のみ復活。tap で timeline_defaults_page へ push。
          // 「毎朝勝手に増える予定を止めたい」user が最初に開くのは settings
          // の想定に応える。歯車 (timeline_page ヘッダー) との 2 経路を確保。
          _SectionHeader(label: l10n.settingsPageSectionTimeline),
          _SettingsTile(
            icon: Icons.schedule_outlined,
            label: l10n.settingsPageTileTimelineDefaults,
            onTap: () => context.push(AppRoutes.timelineDefaults),
          ),

          // ── 通知 ──────────────────────────────────────────────
          _SectionHeader(label: l10n.settingsPageSectionNotifications),
          _SettingsTile(
            icon: Icons.notifications_outlined,
            label: l10n.settingsPageTileReminderSettings,
            onTap: () => context.push(AppRoutes.reminderSettings),
          ),
          // 【FEAT-509】チャレンジ結果 opt-in 通知 (default OFF、Sabi 哲学「押し付けない」)
          _SettingsTile(
            icon: Icons.emoji_events_outlined,
            label: l10n.settingsPageTileChallengeNotif,
            trailing: Switch(
              value: _challengeResultNotifEnabled,
              activeColor: AppTheme.primary,
              onChanged: (v) async {
                HapticFeedback.selectionClick();
                setState(() => _challengeResultNotifEnabled = v);
                final service = ref.read(challengeNotificationServiceProvider);
                final messenger = ScaffoldMessenger.of(context);
                await service.setEnabled(v);
                PosthogService.instance.capture(
                  'challenge_notif_toggled',
                  properties: {'enabled': v},
                );
                messenger.showSnackBar(
                  SnackBar(
                    content: Text(
                      v
                          ? l10n.settingsPageChallengeNotifOnSnackbarSabi_message
                          : l10n.settingsPageChallengeNotifOffSnackbarSabi_message,
                    ),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              },
            ),
          ),

          // ── サポート ───────────────────────────────────────
          _SectionHeader(label: l10n.settingsPageSectionSupport),
          // 【2026-07-08 FEAT-485 拡張】使い方ガイド タイルは HomeDrawer
          // (ハンバーガーメニュー最上位) に移動。
          // 経緯: 「困った時にすぐ見られる」導線を「マイページ → サポート →
          // 使い方ガイド」(3 タップ) から「ホーム → ハンバーガー → 使い方ガイド」
          // (2 タップ) に短縮するため、Drawer への移管が UX 改善に直結すると
          // PM 判断で決定。移動先: home_drawer.dart 最上位 (1 番目) 配置。
          //
          // 本サポートセクションは「よくあるご質問」(FAQ、外部ブラウザ) +
          // 「お問い合わせ」の 2 タイルに絞り、旧「使い方 vs FAQ どちらを開くか」
          // の判断分岐そのものを本セクションから除去して user 摩擦を解消。
          // 「よくあるご質問」は「一度読めば済む」性質のため設定内で十分な設計。
          //
          // 【FEAT-440 (2026-06-17)】よくあるご質問ページ (sabiowl-home-pages の faq.html)
          // 「お問い合わせ」の手前に配置することで、まず FAQ を見てもらう動線を自然に
          // 構築し、PM への問い合わせ流入を減らす設計。release_notes / 特商法と同パターン
          // で Web ページに直接遷移 (アプリ内ページは作らず、Markdown 編集 + push だけで
          // 随時更新できる運用、アプリのバージョンアップ不要)。
          _SettingsTile(
            icon: Icons.help_outline,
            label: l10n.settingsPageTileFaq,
            onTap: _openFaq,
            trailing: const Icon(Icons.open_in_new, size: 14, color: Colors.white38),
          ),
          _SettingsTile(
            icon: Icons.mail_outline,
            label: l10n.settingsPageTileContact,
            onTap: () => context.push(AppRoutes.contact),
          ),

          // 【FEAT-249】ヘルスケアセクションは FEAT-71 で隠蔽 → FEAT-249 で物理削除。

          // ── 言語 ───────────────────────────────────────────
          // 【FEAT-489 Phase 2G-a】表示言語の切替。アプリ情報の直前に置くことで
          // 「アプリ全体の設定」というまとまりを作る (通知/サポートより下、
          // バージョン等の情報表示より上)。
          _SectionHeader(label: l10n.settingsPageSectionLanguage),
          _SettingsTile(
            icon: Icons.language,
            label: l10n.settingsPageTileLanguage,
            onTap: () => _showLanguageDialog(context, ref),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  ref.watch(appLocaleProvider).languageCode == 'en'
                      ? l10n.settingsLanguageOptionEn
                      : l10n.settingsLanguageOptionJa,
                  style: const TextStyle(color: Colors.white38, fontSize: 13),
                ),
                const SizedBox(width: 6),
                const Icon(Icons.chevron_right, color: Colors.white24, size: 20),
              ],
            ),
          ),

          // ── アプリ情報 ─────────────────────────────────────
          _SectionHeader(label: l10n.settingsPageSectionAppInfo),
          // 【BUG-121 (2026-06-14)】バージョンをタップで Web のリリースノートを開く。
          // 外部ブラウザ起動 (LaunchMode.externalApplication)、失敗時はサビ口調 SnackBar。
          // privacy_policy / terms_of_service と同パターン (FEAT-271/272 踏襲)。
          _SettingsTile(
            icon: Icons.info_outline,
            label: l10n.settingsPageTileVersion,
            onTap: _openReleaseNotes,
            // 【BUG-151 (2026-09-02)】旧実装は `Text('1.0.0')` のリテラルで、
            // v1.1.0 / v1.1.1 を出しても**ここだけ 1.0.0 のまま**だった。
            // 🔴 真実値は `pubspec.yaml` の `version:`。リテラルで書かないこと。
            // 取得できるまでは何も出さない (「取得中…」は trailing には長すぎる。
            // ドロワーは行全体がバージョン表示なので loading 文言を出している)。
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  ref.watch(appVersionProvider).valueOrNull ?? '',
                  style: const TextStyle(color: Colors.white38, fontSize: 13),
                ),
                const SizedBox(width: 6),
                const Icon(Icons.open_in_new, size: 14, color: Colors.white38),
              ],
            ),
          ),
          // 【2026-07-05】プライバシーポリシー / 利用規約はアプリ内ネイティブ描画を
          // 廃止し GitHub Pages へ launchUrl 遷移に統一 (release_notes / 特商法 / FAQ と
          // 同パターン)。Web 版 (sabiowl-home-pages) を Single Source of Truth 化する
          // ことで、法務文書更新時のアプリ内表示との drift リスクを構造解消。
          _SettingsTile(
            icon: Icons.privacy_tip_outlined,
            label: l10n.settingsPageTilePrivacyPolicy,
            onTap: _openPrivacyPolicy,
            trailing: const Icon(Icons.open_in_new, size: 14, color: Colors.white38),
          ),
          _SettingsTile(
            icon: Icons.gavel_outlined,
            label: l10n.settingsPageTileTermsOfService,
            onTap: _openTermsOfService,
            trailing: const Icon(Icons.open_in_new, size: 14, color: Colors.white38),
          ),
          // 【FEAT-436 Phase 3 (2026-06-17)】特定商取引法に基づく表示。
          // IAP ダイヤパック販売 (v1.0.1) に伴う法務必須項目。Web ページに直接遷移
          // (アプリ内ページは作らず、release_notes と同パターンで外部ブラウザ起動)。
          _SettingsTile(
            icon: Icons.storefront_outlined,
            label: l10n.settingsPageTileSpecifiedCommercial,
            onTap: _openSpecifiedCommercialTransactions,
            trailing: const Icon(Icons.open_in_new, size: 14, color: Colors.white38),
          ),
          // 【2026-06-27】公式 X (旧 Twitter) アカウント @sabiowlapp。
          // sabiowl-home-pages の index.md / _config.yml にも同じハンドルを記載済み。
          // release_notes / 特商法 / FAQ と同じ launchUrl パターン (外部ブラウザ起動)、
          // 失敗時はサビ口調 SnackBar。
          _SettingsTile(
            icon: Icons.alternate_email,
            label: l10n.settingsPageTileOfficialX,
            onTap: _openOfficialX,
            trailing: const Icon(Icons.open_in_new, size: 14, color: Colors.white38),
          ),

          // ── アカウント管理 ─────────────────────────────────
          // 【BUG-129 (2026-06-14)】社会的連携解除は「アカウント連携シート → 連携済
          // タイル → 連携を解除する ボタン」の階層動線に統合 (Settings トップの
          // 独立ボタンは廃止)。`_AccountLinkTileState._showLinkedAccountDialog` /
          // `_confirmAndUnlink` 参照。
          _SectionHeader(label: l10n.settingsPageSectionAccountManagement),
          _SettingsTile(
            icon: Icons.logout,
            label: l10n.settingsPageTileLogout,
            iconColor: Colors.orange,
            labelColor: Colors.orange,
            onTap: () => _confirmLogout(context),
          ),
          _SettingsTile(
            icon: Icons.delete_forever_outlined,
            label: l10n.settingsPageTileDeleteAccount,
            iconColor: AppTheme.danger,
            labelColor: AppTheme.danger,
            onTap: () => context.push(AppRoutes.accountDelete),
          ),
          const SizedBox(height: 32),
        ],
        ),
      ),
    );
  }

  // ── 【FEAT-257 / FEAT-258】Google カレンダー push トグル + 説明 Tooltip ────
  //
  // Google 連携あり + Player ロード済のときだけ表示する。連携なし時はトグル自体を
  // 描画しない（読み取り経路は別軸で、本トグルは push のみを制御する設計）。
  List<Widget> _buildGcalPushSection(BuildContext context, WidgetRef ref) {
    final accountsAsync = ref.watch(linkedAccountsProvider);
    final playerAsync   = ref.watch(playerNotifierProvider);
    final isGoogleLinked =
        accountsAsync.valueOrNull?.google.isLinked ?? false;
    if (!isGoogleLinked) return const [];
    final player = playerAsync.valueOrNull;
    if (player == null) return const [];

    return [
      // 【FEAT-257】Sabiowl → Google push の明示トグル。default=true なので
      // 既存ユーザーは体験不変、OFF にした人だけ書き出しが止まる。
      //
      // 【FEAT-278】UI 統一: ListTile + trailing Switch にし、他の _SettingsTile
      // (icon + label + trailing chevron) と視覚的に揃える。
      //
      // 【FEAT-373 (2026-05-29)】v1.0 で Google Calendar push (Sabiowl → Google) 機能廃止。
      // 「Google カレンダーへ自動反映」トグル ListTile を完全非表示化 (案 a、PM 推奨)。
      // Backend `_initial_pending_google_push` が常時 False + Flutter FeatureFlags.gcalPushEnabled=false
      // で構造的に push されないため、UI トグルは混乱の元として撤去。
      // 復元: git history (FEAT-373 commit 直前) + feature_flags.dart の変更で再表示可能。
      // 【FEAT-258】旧「【Sabiowl】について」Tooltip は FEAT-274 でタイトル
      // プレフィックスを廃止 (extendedProperties.private.source 方式に移行)
      // した時点で内容が嘘になったため削除。
    ];
  }

  // ── 【FEAT-377】ストリーク自動保護トグルセクション ───────────────────────
  //
  // Player ロード済のときのみ表示。
  // トグル ON = 途切れ瞬間に在庫から自動消費 (在庫ゼロ時は静かに何もしない)。
  // Pre-mortem #4 遵守: 在庫ゼロ + ダイヤ不足時はオーバーレイ誘導禁止。
  List<Widget> _buildStreakProtectionSection(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final playerAsync = ref.watch(playerNotifierProvider);
    final player = playerAsync.valueOrNull;
    if (player == null) return const [];
    final count = player.streakProtectionCount;
    return [
      // 【FEAT-456 (2026-06-21)】「アカウント連携」と「連続記録の保護」の間の
      // Divider を削除 (UI の視覚的ノイズ削減、PM 要望)。
      // 他セクション間に Divider があれば、本セクションだけ外すと不整合になるが、
      // 既存実装でも _SectionHeader は label のみ表示で Divider 不使用のため整合維持。
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(
          l10n.settingsPageStreakSection,
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
      ),
      // 【FEAT-320 スタイルと整合】SwitchListTile → ListTile + trailing Switch
      ListTile(
        leading: const Icon(Icons.shield_outlined, color: Colors.white54, size: 22),
        title: Text(
          l10n.settingsPageStreakAutoTitle,
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
        subtitle: Text(
          count > 0
              ? l10n.settingsPageStreakAutoSubtitleHasItems(count)
              : l10n.settingsPageStreakAutoSubtitleNoItems,
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        trailing: Switch(
          value: player.streakProtectionAutoEnabled,
          activeColor: AppTheme.primary,
          onChanged: (newValue) async {
            final l10nCb = AppLocalizations.of(context)!;
            HapticFeedback.selectionClick();
            try {
              await ref
                  .read(playerNotifierProvider.notifier)
                  .setStreakProtectionAutoEnabled(newValue);
            } catch (e) {
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(l10nCb.settingsSaveErrorSnackbarSabi_message),
                ),
              );
            }
          },
        ),
      ),
      // 【FEAT-420 → BUG-88 (2026-06-10)】ストリーク保護「予約 Switch」UI を撤去。
      // ユーザー報告「予約は不要、既に自動保護があり同じ役割」(2026-06-10) を受けた
      // 機能整理。自動保護 (FEAT-377) の挙動「途切れた瞬間 = 翌日初回達成判定時に
      // 在庫消費」と、予約 (FEAT-420) の挙動「翌日初回達成判定時に在庫消費」は
      // ユーザー視点で同一に見え、UI 上の二重 Switch が混乱を招いていた。
      // Backend (PlayerProfile.streak_protection_pending + StreakProtectionManualUseView +
      // StreakProtectionCancelView + habit_count_service の pending 判定) は将来の
      // 差別化アイデア (例: 「1 日だけ予約」vs「常時自動」の使い分け) に備えて
      // 温存。本撤去は Mobile UI のみで、migration 0123 / view / habit_count_service
      // の pending 経路には触らない。
    ];
  }

  // ── 【FEAT-493】β 機能セクション ─────────────────────────────────────────
  //
  // フリーメモ機能 (Quick Capture) の 有効/無効トグル。Player ロード済のときのみ表示。
  // 【方針変更 (2026-07-25 hotfix)】default=OFF (opt-in β) → default=ON へ変更。
  // 「β 機能セクション最下部にあると気付かれない」ため全ユーザー即時有効化、
  // トグルは残置して無効化 (opt-out) は可能。
  List<Widget> _buildBetaFeaturesSection(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final playerAsync = ref.watch(playerNotifierProvider);
    final player = playerAsync.valueOrNull;
    if (player == null) return const [];

    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(
          l10n.settingsPageBetaSection,
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
      ),
      ListTile(
        leading: const Icon(Icons.science_outlined, color: Colors.white54, size: 22),
        title: Text(
          l10n.settingsPageFreeMemoTitle,
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
        subtitle: Text(
          l10n.settingsPageFreeMemoDescSabi_message,
          style: const TextStyle(color: Colors.white54, fontSize: 12, height: 1.4),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        trailing: Switch(
          value: player.freeMemoEnabled,
          activeColor: AppTheme.primary,
          onChanged: (newValue) async {
            final l10nCb = AppLocalizations.of(context)!;
            HapticFeedback.selectionClick();
            try {
              await ref
                  .read(playerNotifierProvider.notifier)
                  .setFreeMemoEnabled(newValue);
              // 【FEAT-493】PostHog 計測
              await PosthogService.instance.capture(
                'free_memo_opt_in_toggled',
                properties: {'enabled': newValue},
              );
            } catch (e) {
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(l10nCb.settingsSaveErrorSnackbarSabi_message),
                ),
              );
            }
          },
        ),
      ),
    ];
  }

  // 【FEAT-506 (2026-07-29) 移動履歴】_buildTimelineSettingsSection() は
  // timeline_defaults_page.dart (画面上部 Global toggle) に集約したため削除。
  // 復活が必要な場合は git history から取得可能 (settings_page.dart:448-494 相当)。

  /// 【FEAT-489 Phase 2G-a】表示言語の選択ダイアログ。
  ///
  /// 選択肢のラベルは **その言語自身で表記** する (「日本語」「English」)。
  /// 現在の表示言語で訳してしまうと、間違えて切り替えた人が元に戻せなくなる。
  Future<void> _showLanguageDialog(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final current = ref.read(appLocaleProvider).languageCode;

    // 【FEAT-215】ShellRoute 配下なので dialogContext を受け取って pop する。
    final selected = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppTheme.card,
        title: Text(
          l10n.settingsLanguageDialogTitle,
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (code, label) in [
              ('ja', l10n.settingsLanguageOptionJa),
              ('en', l10n.settingsLanguageOptionEn),
            ])
              RadioListTile<String>(
                value: code,
                groupValue: current,
                activeColor: AppTheme.primary,
                title: Text(label,
                    style: const TextStyle(color: Colors.white, fontSize: 14)),
                onChanged: (v) => Navigator.pop(dialogContext, v),
              ),
          ],
        ),
        actions: [
          // 【BUG-138】Cancel 左 / Action 右。本ダイアログは選択即確定なので
          // 右側の action ボタンは持たない。
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.settingsLanguageDialogCancelButton,
                style: const TextStyle(color: Colors.white54)),
          ),
        ],
      ),
    );

    if (selected == null || selected == current) return;
    if (!context.mounted) return;

    HapticFeedback.selectionClick();

    // 【2026-08-02】`setLanguage` を await しない。
    //
    // state は同期的に更新されるので画面は即座に切り替わるが、await の中身は
    // `clearResponseCache()` → `dio.patch('/player/')` で、dio の timeout は
    // 60 秒ある。await すると **圏外で「切り替えました」が最大 60 秒遅れ**、
    // その間に画面を離れていれば `context.mounted` が false になって
    // SnackBar が出ないまま消える。成功時ほどフィードバックが遅いのは逆向き。
    //
    // `setLanguage` は内部で二重に try/catch しており呼び出し元に例外を投げない
    // 契約 (`i18n_locale_guard_test.dart` の S4 が固定済) なので、await を
    // 外しても壊れない。「UI 切替を I/O に依存させない」という Phase 2G-a の
    // 設計思想を、確認表示にも適用するだけ。
    // ignore: discarded_futures
    ref.read(appLocaleProvider.notifier).setLanguage(selected);

    // 切替後の文言は **context 経由ではなく直接 lookup する**。
    // `AppLocalizations.of(context)` は Localizations widget の再構築を待つ
    // 必要があり、await を外した直後のこの時点ではまだ旧言語を返す
    // (旧実装が await していたのは、実質これを待つためでもあった)。
    // lookup なら同期で新 locale の文言が取れる。
    final nextL10n = lookupAppLocalizations(localeForLanguageCode(selected));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(nextL10n.settingsLanguageChangedSabi_message)),
    );
  }

  /// 【BUG-121 (2026-06-14)】バージョン行タップで Web のリリースノートを開く。
  /// `sabiowl-home-pages/release_notes.html` を OS 標準ブラウザで起動。
  /// FEAT-271 (privacy) / FEAT-272 (terms) と同パターン、失敗時はサビ口調 SnackBar。
  Future<void> _openReleaseNotes() async {
    final l10n = AppLocalizations.of(context)!;
    final uri = Uri.parse(kSabiowlReleaseNotesUrl);
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) ToastCenter.showWarning(l10n.settingsPageOpenUrlErrorSabi_message);
    } catch (e) {
      debugPrint('[BUG-121] launchUrl failed: $e');
      ToastCenter.showWarning(l10n.settingsPageOpenUrlErrorSabi_message);
    }
  }

  /// 【2026-07-05】プライバシーポリシー (Web 版) を OS 標準ブラウザで開く。
  /// アプリ内ネイティブ描画版を廃止し `sabiowl-home-pages/privacy_policy.html` に
  /// 一元化することで、法務文書更新時の drift リスクを構造解消 (Single Source of
  /// Truth 化)。`_openReleaseNotes` / `_openSpecifiedCommercialTransactions` と同
  /// パターン、失敗時はサビ口調 SnackBar。
  Future<void> _openPrivacyPolicy() async {
    final l10n = AppLocalizations.of(context)!;
    final uri = Uri.parse(kSabiowlPrivacyPolicyUrl);
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) ToastCenter.showWarning(l10n.settingsPageOpenUrlErrorSabi_message);
    } catch (e) {
      debugPrint('[2026-07-05 privacy launch] launchUrl failed: $e');
      ToastCenter.showWarning(l10n.settingsPageOpenUrlErrorSabi_message);
    }
  }

  /// 【2026-07-05】利用規約 (Web 版) を OS 標準ブラウザで開く。
  /// `_openPrivacyPolicy` と同思想 (drift 構造解消)。
  Future<void> _openTermsOfService() async {
    final l10n = AppLocalizations.of(context)!;
    final uri = Uri.parse(kSabiowlTermsOfServiceUrl);
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) ToastCenter.showWarning(l10n.settingsPageOpenUrlErrorSabi_message);
    } catch (e) {
      debugPrint('[2026-07-05 terms launch] launchUrl failed: $e');
      ToastCenter.showWarning(l10n.settingsPageOpenUrlErrorSabi_message);
    }
  }

  /// 【FEAT-436 Phase 3 (2026-06-17)】特定商取引法に基づく表示を Web で開く。
  /// `sabiowl-home-pages/specified_commercial_transactions.html` を OS 標準ブラウザで起動。
  /// `_openReleaseNotes` と同パターン、失敗時はサビ口調 SnackBar。
  Future<void> _openSpecifiedCommercialTransactions() async {
    final l10n = AppLocalizations.of(context)!;
    final uri = Uri.parse(kSabiowlSpecifiedCommercialTransactionsUrl);
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) ToastCenter.showWarning(l10n.settingsPageOpenUrlErrorSabi_message);
    } catch (e) {
      debugPrint('[FEAT-436] launchUrl failed: $e');
      ToastCenter.showWarning(l10n.settingsPageOpenUrlErrorSabi_message);
    }
  }

  /// 【FEAT-440 (2026-06-17)】ヘルプ・よくあるご質問を Web で開く。
  /// `sabiowl-home-pages/faq.html` を OS 標準ブラウザで起動。
  /// `_openReleaseNotes` / `_openSpecifiedCommercialTransactions` と同パターン。
  /// 失敗時はサビ口調 SnackBar。
  Future<void> _openFaq() async {
    final l10n = AppLocalizations.of(context)!;
    final uri = Uri.parse(kSabiowlFaqUrl);
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) ToastCenter.showWarning(l10n.settingsPageOpenUrlErrorSabi_message);
    } catch (e) {
      debugPrint('[FEAT-440] launchUrl failed: $e');
      ToastCenter.showWarning(l10n.settingsPageOpenUrlErrorSabi_message);
    }
  }

  /// 【2026-06-27】公式 X (旧 Twitter) アカウントを外部ブラウザで開く。
  /// X アプリが端末にインストールされていればアプリ側で開かれる
  /// (LaunchMode.externalApplication が deep link / app-link 解決を委ねる)。
  /// 既存 _openFaq / _openReleaseNotes と同パターン、失敗時はサビ口調 SnackBar。
  Future<void> _openOfficialX() async {
    final l10n = AppLocalizations.of(context)!;
    final uri = Uri.parse(kSabiowlOfficialXUrl);
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) ToastCenter.showWarning(l10n.settingsPageOpenXErrorSabi_message);
    } catch (e) {
      debugPrint('[2026-06-27 X launch] launchUrl failed: $e');
      ToastCenter.showWarning(l10n.settingsPageOpenXErrorSabi_message);
    }
  }

  // 【FEAT-436 (2026-06-17)】旧 _showDiamondPurchaseComingSoonDialog (FEAT-331 で
  // 追加された v1.1 予定の Coming Soon プレースホルダー) は本 FEAT で削除。
  // 「ダイヤを購入する」タイルは AppRoutes.diamondPack への遷移に置換済。

  void _showAccountLinkSheet(BuildContext context) {
    HapticFeedback.lightImpact();
    // FEAT-183: 小型機種でも全タイルが表示できるよう、SafeArea + maxHeight 制限 +
    // 内部 SingleChildScrollView の 3 点で「シートが画面外にはみ出して
    // Google タイルがタップできない」状態を防ぐ。
    showModalBottomSheet<void>(
      context:            context,
      isScrollControlled: true,
      backgroundColor:    Colors.transparent,
      useSafeArea:        true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      builder: (_) => const _AccountLinkSheet(),
    );
  }

  // ── ログアウト（FEAT-178 Phase 4 / FEAT-184）────────────────────────────
  //
  // 連携済みなら通常確認ダイアログ。未連携（ゲスト）なら警告ダイアログで
  // ブロックし、連携シートへ誘導する。
  //
  // FEAT-184: linkedAccountsProvider は FutureProvider.autoDispose で
  // 設定画面に入るたびに /auth/social/accounts/ を再フェッチする。
  // `ref.read(provider).valueOrNull` で同期取得すると loading 中は null になり、
  // 連携済みでも「未連携」と誤判定して警告ダイアログが誤発火する。
  // `.future` を await して値が確定してから判定する。
  Future<void> _confirmLogout(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    HapticFeedback.lightImpact();

    // 🔴 【BUG-154 (2026-09-11)】サーバに聞けなくてもここで止まらない。
    //
    // 旧実装は `/auth/social/accounts/` の取得に失敗すると SnackBar を出して
    // return していた —— **確認ダイアログすら開かず、通信できないと
    // ログアウトできない**状態だった。ログアウト処理そのものは通信を捨てる
    // 前提で書かれている (`auth_service` が `/auth/logout/` の失敗を握って
    // ローカル削除を続行する) のに、**入口の事前チェックだけが閉じていた**。
    //
    // ⚠️ ガードは消していない。判定材料をローカル (`guest_mode`) に
    //    切り替えただけである。詳細は `logout_guard.dart`。
    final blocked = await shouldBlockLogoutAsUnlinked(
      fetchLinkedAccounts: () => ref.read(linkedAccountsProvider.future),
      isGuestMode: () => ref.read(apiClientProvider).isGuestMode(),
    );

    if (!context.mounted) return;

    if (blocked) {
      await _showUnlinkedLogoutWarning(context);
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        title: Text(l10n.settingsLogoutDialogTitle, style: const TextStyle(color: Colors.white)),
        content: Text(
          l10n.settingsLogoutDialogContent,
          style: const TextStyle(color: Colors.white70, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.commonCancel,
                style: const TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.orange),
            child: Text(l10n.settingsLogoutDialogConfirm),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      HapticFeedback.mediumImpact();
      await ref.read(authProvider.notifier).logout();
      if (context.mounted) context.go(AppRoutes.auth);
    }
  }

  Future<void> _showUnlinkedLogoutWarning(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        title: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 24),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                l10n.settingsLogoutBlockedDialogTitle,
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.settingsLogoutBlockedDialogContent,
              style: const TextStyle(
                  color: Colors.white70, fontSize: 13, height: 1.6),
            ),
            const SizedBox(height: 12),
            Text(
              l10n.settingsLogoutBlockedDialogHintSabi_message,
              style: const TextStyle(
                  color: Colors.white, fontSize: 13, height: 1.6),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.commonClose,
                style: const TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              // 既存の連携シートを開く
              _showAccountLinkSheet(context);
            },
            style: TextButton.styleFrom(foregroundColor: AppTheme.primary),
            child: Text(l10n.settingsLinkConfirmButton),
          ),
        ],
      ),
    );
  }
}

// ── 汎用パーツ ────────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
      child: Text(label,
          style: const TextStyle(
              color: Colors.white38,
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 1)),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? iconColor;
  final Color? labelColor;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _SettingsTile({
    required this.icon,
    required this.label,
    this.iconColor,
    this.labelColor,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: iconColor ?? Colors.white54, size: 22),
      title: Text(label,
          style: TextStyle(
              color: labelColor ?? Colors.white, fontSize: 14)),
      trailing: trailing ??
          (onTap != null
              ? const Icon(Icons.chevron_right,
                  color: Colors.white24, size: 20)
              : null),
      onTap: onTap,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
    );
  }
}

// 【FEAT-249】_HealthToggleTile（ヘルスケア連携トグル）は FEAT-71 で隠蔽 → FEAT-249 で物理削除。

// ── アカウント連携シート（FEAT-178: Google / Apple のみ）─────────────────────

class _AccountLinkSheet extends StatelessWidget {
  const _AccountLinkSheet();

  @override
  Widget build(BuildContext context) {
    // FEAT-183: SafeArea(top: false) で下部のホームインジケータを避け、
    // SingleChildScrollView で小型機種でもはみ出さないようにする。
    // 上部は showModalBottomSheet が角丸を生かしてくれるので top: false。
    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          color:        AppTheme.sheetBackground,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        // 下部に十分な余白（ホームインジケータ + ゆとり）
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize:       MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── ドラッグハンドル ──────────────────────
              const SizedBox(height: 12),
              Center(
                child: Container(
                  width:  36, height: 4,
                  decoration: BoxDecoration(
                    color:        Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // ── タイトル ─────────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  AppLocalizations.of(context)!.settingsAccountLinkSheetTitle,
                  style: const TextStyle(
                    color:      Colors.white,
                    fontSize:   18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  AppLocalizations.of(context)!.settingsAccountLinkSheetDescSabi_message,
                  style: const TextStyle(
                    color:    Colors.white70,
                    fontSize: 12,
                    height:   1.5,
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // ── タイル ───────────────────────────────
              const _AccountLinkTile(provider: AccountProvider.google),
              // Apple（iOS のみ）
              if (defaultTargetPlatform == TargetPlatform.iOS)
                const _AccountLinkTile(provider: AccountProvider.apple),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// アカウント連携タイル
// ─────────────────────────────────────────────────────────────────────────────

enum AccountProvider { google, apple }

/// 【BUG-129 (2026-06-14)】連携済みタイル情報ダイアログの結果。
/// BUG-65 標準パターン (dialog は結果を返すだけ、操作は caller) で、`_handleTap`
/// 側で `unlink` 選択時に確認 + 解除フローを起動する。
enum _LinkedAccountAction { unlink }

class _AccountLinkTile extends ConsumerStatefulWidget {
  final AccountProvider provider;
  const _AccountLinkTile({required this.provider});

  @override
  ConsumerState<_AccountLinkTile> createState() => _AccountLinkTileState();
}

class _AccountLinkTileState extends ConsumerState<_AccountLinkTile> {
  bool _isLinking = false;

  // ── 表示情報 ──────────────────────────────────────────────────────────────

  String _providerLabel(AppLocalizations l10n) {
    switch (widget.provider) {
      case AccountProvider.google: return l10n.settingsAccountLinkGoogleLabel;
      case AccountProvider.apple:  return l10n.settingsAccountLinkAppleLabel;
    }
  }

  Widget get _leadingIcon {
    switch (widget.provider) {
      case AccountProvider.google:
        return const SizedBox(width: 22, height: 22, child: GoogleLogoIcon());
      case AccountProvider.apple:
        return const SizedBox(width: 22, height: 22, child: AppleLogoIcon());
    }
  }

  LinkedAccountInfo _info(LinkedAccounts accounts) {
    switch (widget.provider) {
      case AccountProvider.google: return accounts.google;
      case AccountProvider.apple:  return accounts.apple;
    }
  }

  /// 【FEAT-290】**別の** provider が連携済みかどうか。
  /// true の場合、本タイルは「他のアカウントで連携済み」表示で disabled になる。
  /// Backend の FEAT-178「1 ユーザー 1 プロバイダ制約」(409 で拒否) を UI 側で
  /// 事前ガードして、ユーザーが「タップ → Google サインインダイアログ →
  /// 409 → エラーダイアログ」の無駄なフローを踏まないようにする。
  bool _isOtherProviderLinked(LinkedAccounts accounts) {
    switch (widget.provider) {
      case AccountProvider.google: return accounts.apple.isLinked;
      case AccountProvider.apple:  return accounts.google.isLinked;
    }
  }

  /// 別 provider 名（disabled 時の subtitle 表示用）
  String _otherProviderLabel() {
    switch (widget.provider) {
      case AccountProvider.google: return 'Apple';
      case AccountProvider.apple:  return 'Google';
    }
  }

  // ── アクション ────────────────────────────────────────────────────────────

  Future<void> _handleTap(LinkedAccounts accounts) async {
    if (_isLinking) return;
    final info = _info(accounts);
    if (info.isLinked) {
      // 【BUG-129 (2026-06-14)】連携済みタイル → 情報ダイアログから「連携を解除する」
      // を選択できる経路に変更 (旧 FEAT-178「読み取り専用」設計を撤回)。
      // 設計: BUG-65 標準パターン (dialog は結果を返すだけ、navigation/操作は caller)。
      final action = await _showLinkedAccountDialog(info);
      if (!mounted) return;
      if (action == _LinkedAccountAction.unlink) {
        await _confirmAndUnlink();
      }
    } else {
      final confirmed = await _showLinkConfirmDialog();
      if (!confirmed || !mounted) return;
      await _performLink();
    }
  }

  Future<bool> _showLinkConfirmDialog() async {
    final l10n = AppLocalizations.of(context)!;
    final desc = widget.provider == AccountProvider.google
        ? l10n.settingsLinkConfirmDescGoogle
        : l10n.settingsLinkConfirmDescApple;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            _leadingIcon,
            const SizedBox(width: 10),
            Text(
              _providerLabel(l10n),
              style: const TextStyle(
                color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        content: Text(
          desc,
          style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.commonCancel, style: const TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.primary),
            child: Text(l10n.settingsLinkConfirmButton, style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  /// 【BUG-129 (2026-06-14)】連携済みタイルをタップしたときの情報ダイアログ。
  /// 旧 FEAT-178「読み取り専用」設計を撤回し、誤連携救済のため「連携を解除する」
  /// ボタンを追加。BUG-65 標準パターン (dialog は結果を返すだけ、操作は caller) で
  /// 実装し、`_LinkedAccountAction` を返却して caller の `_handleTap` で分岐する。
  Future<_LinkedAccountAction?> _showLinkedAccountDialog(
      LinkedAccountInfo info) async {
    final l10n = AppLocalizations.of(context)!;
    HapticFeedback.lightImpact();
    return showDialog<_LinkedAccountAction>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            _leadingIcon,
            const SizedBox(width: 10),
            Text(
              _providerLabel(l10n),
              style: const TextStyle(
                color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.check_circle, color: AppTheme.primary, size: 18),
                const SizedBox(width: 8),
                Text(l10n.settingsAccountLinkStatusLinked,
                    style: const TextStyle(color: Colors.white, fontSize: 14)),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              // 【FEAT-289】プライバシー配慮で先頭 1 文字 + 4 アスタリスク +
              // ドメイン形式にマスク表示。
              l10n.settingsAccountLinkDialogEmail(maskEmail(info.email) ?? '-'),
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 16),
            Text(
              l10n.settingsAccountLinkDialogHintSabi_message,
              style: const TextStyle(color: Colors.white60, fontSize: 12, height: 1.5),
            ),
          ],
        ),
        actions: [
          // 【BUG-138 (2026-06-17)】BUG-132 を撤回、全アプリ共通の新ルール
          // 「Cancel 系を左、Action 系を右」に揃える。前のリビジョン (BUG-132) は
          // 「主動作を左」だったが、Material / Google / iOS の慣行と乖離していたため
          // 一貫性を優先して撤回。
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.commonClose, style: const TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(ctx, _LinkedAccountAction.unlink),
            style: TextButton.styleFrom(foregroundColor: Colors.orange),
            child: Text(l10n.settingsAccountUnlinkButton),
          ),
        ],
      ),
    );
  }

  /// 【BUG-129 (2026-06-14)】社会的アカウント連携解除の確認 + 実行。
  /// 解除すると PlayerProfile はゲストモードに戻り (データ保持)、ユーザーは正しい
  /// Google/Apple アカウントで再連携できる。
  ///
  /// Caller である `_handleTap` から呼ばれ、シート内 context の上位 (SettingsPage
  /// 配下の Scaffold) の ScaffoldMessenger を非同期前にキャプチャすることで、
  /// シート pop 後でも SnackBar を確実に表示する。
  Future<void> _confirmAndUnlink() async {
    final l10n = AppLocalizations.of(context)!;
    HapticFeedback.lightImpact();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppTheme.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(l10n.settingsUnlinkConfirmDialogTitle,
            style: const TextStyle(color: Colors.white, fontSize: 17)),
        content: Text(
          l10n.settingsUnlinkConfirmDialogContentSabi_message,
          style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
        ),
        actions: [
          // 【BUG-138 (2026-06-17)】BUG-132 撤回。Cancel 左 / Action 右の新ルール。
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.commonCancel,
                style: const TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(foregroundColor: Colors.orange),
            child: Text(l10n.settingsUnlinkConfirmButton),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    HapticFeedback.mediumImpact();

    // Sheet pop 後でも SnackBar を出せるよう、非同期処理前に SettingsPage の
    // ScaffoldMessenger をキャプチャする (BUG-65 同パターン)。
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final successMsg = l10n.settingsUnlinkSuccessSnackbarSabi_message;
    final errorMsg = l10n.settingsGenericErrorSnackbarSabi_message;

    setState(() => _isLinking = true);
    try {
      await ref.read(authProvider.notifier).unlinkSocialAccount();
      if (!mounted) return;
      // 連携解除成功 → シートを閉じてから SnackBar 表示
      Navigator.of(context).maybePop();
      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text(successMsg),
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e, st) {
      debugPrint('[unlinkSocial] failed: $e\n$st');
      if (!mounted) return;
      scaffoldMessenger.showSnackBar(
        SnackBar(content: Text(errorMsg)),
      );
    } finally {
      if (mounted) setState(() => _isLinking = false);
    }
  }

  /// FEAT-178 + FEAT-181: 連携成功後のサビ紳士的トーン安心ダイアログ。
  /// `playerName` が非空かつ既定値（'勇者' / '' / 'ゲスト'）以外なら、
  /// 「<名前> 様、これで安心ですね。」と紳士的に呼びかける。
  Future<void> _showSabiLinkedDialog({required String playerName}) async {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    const defaultLikeNames = {'', '勇者', 'ゲスト'};
    final hasGreeting =
        playerName.isNotEmpty && !defaultLikeNames.contains(playerName);
    final greeting = hasGreeting
        ? l10n.settingsLinkSuccessGreetingNamed(playerName)
        : l10n.settingsLinkSuccessGreetingDefault;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.shield_outlined,
                color: AppTheme.primary, size: 48),
            const SizedBox(height: 16),
            Text(
              greeting,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              l10n.settingsLinkSuccessMessageSabi_message(_providerLabel(l10n)),
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
                height: 1.6,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            style: TextButton.styleFrom(foregroundColor: AppTheme.primary),
            child: Text(l10n.commonYes),
          ),
        ],
      ),
    );
  }

  Future<void> _performLink() async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _isLinking = true);
    try {
      final service = ref.read(settingsServiceProvider);
      if (widget.provider == AccountProvider.google) {
        await service.linkWithGoogle();
      } else {
        await service.linkWithApple();
      }
      // FEAT-183: ゲスト → 正式昇格の場合、ゲスト経路で参照していた合成データ
      // （isGuestModeProvider / homeBootstrapRawProvider / habitsNotifierProvider）
      // と認証済み Player 状態を再フェッチして UI を更新する。
      // 既ログインユーザーの追加連携でも invalidate は無害（再フェッチコストのみ）。
      ref.invalidate(isGuestModeProvider);
      ref.invalidate(linkedAccountsProvider);
      ref.invalidate(homeBootstrapRawProvider);
      ref.invalidate(habitsNotifierProvider);
      // FEAT-181: 連携時に PlayerProfile.name が更新されている可能性があるため、
      // 最新の Player を取得してからサビダイアログに名前を渡す。
      ref.invalidate(playerNotifierProvider);
      final updatedPlayer = await ref.read(playerNotifierProvider.future);
      if (!mounted) return;
      // シートを閉じてからサビダイアログを表示する（裏にシートが残らないように）
      Navigator.of(context).maybePop();
      if (!mounted) return;
      // FEAT-178 + FEAT-181: 連携成功時はサビからの安心メッセージダイアログ
      await _showSabiLinkedDialog(playerName: updatedPlayer.name);
    } on SocialLinkCancelledException {
      // ユーザーがキャンセル → 何もしない
    } on AlreadyLinkedOtherProviderException catch (e) {
      // FEAT-178: 1 ユーザー 1 プロバイダ制約違反
      if (!mounted) return;
      await _showOtherProviderConflictDialog(e);
    } on GuestPromoteConflictException catch (e) {
      // FEAT-189: ゲスト + 既存ユーザー衝突 → 確認ダイアログ → 確定で促成切替
      if (!mounted) return;
      await _handleGuestPromoteConflict(e);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_parseErrorMessage(l10n, e.toString())),
          backgroundColor: AppTheme.danger,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    } finally {
      if (mounted) setState(() => _isLinking = false);
    }
  }

  Future<void> _showOtherProviderConflictDialog(
      AlreadyLinkedOtherProviderException e) async {
    final l10n = AppLocalizations.of(context)!;
    final currentLabel = e.currentProvider == 'google' ? 'Google' : 'Apple';
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          l10n.settingsAlreadyLinkedDialogTitle,
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
        content: Text(
          l10n.settingsAlreadyLinkedDialogContent(currentLabel),
          style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.commonClose, style: const TextStyle(color: Colors.white54)),
          ),
        ],
      ),
    );
  }

  /// FEAT-189: ゲスト → 既存ユーザー衝突を解消する確認ダイアログ + 確定処理。
  /// 【2026-07-02】旧実装 (~75 LOC の inline AlertDialog) を
  /// GuestPromoteConflictDialog widget に抽出。auth_page.dart との二重実装で
  /// 赤字強調の同期漏れが発生した反省から共通化、文言変更は widget 側 1 箇所で完結。
  Future<void> _handleGuestPromoteConflict(
      GuestPromoteConflictException e) async {
    final ok = await GuestPromoteConflictDialog.show(
      context: context,
      existingProvider: e.existingProvider,
      existingUserName: e.existingUserName,
    );

    if (!mounted) return;
    if (!ok) return;

    final l10n = AppLocalizations.of(context)!;
    try {
      await ref.read(settingsServiceProvider).confirmPromote(e.mergeToken);
      // ゲスト→正式昇格完了 → 関連プロバイダーを invalidate
      ref.invalidate(isGuestModeProvider);
      ref.invalidate(linkedAccountsProvider);
      ref.invalidate(homeBootstrapRawProvider);
      ref.invalidate(habitsNotifierProvider);
      ref.invalidate(playerNotifierProvider);
      final updatedPlayer = await ref.read(playerNotifierProvider.future);
      if (!mounted) return;
      Navigator.of(context).maybePop();
      if (!mounted) return;
      await _showSabiLinkedDialog(playerName: updatedPlayer.name);
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_parseErrorMessage(l10n, err.toString())),
          backgroundColor: AppTheme.danger,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    }
  }

  String _parseErrorMessage(AppLocalizations l10n, String raw) {
    if (raw.contains('別の Sabiowl') ||
        raw.contains('別のSabiowl') ||
        raw.contains('409')) {
      return l10n.settingsLinkErrorDuplicateAccount;
    }
    final cleaned = raw.replaceFirst('Exception: ', '').trim();
    if (cleaned.isNotEmpty && cleaned != '不明なエラー' && cleaned != 'null') {
      return cleaned;
    }
    return l10n.settingsLinkErrorGeneric;
  }

  // ── ビルド ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final accountsAsync = ref.watch(linkedAccountsProvider);

    return accountsAsync.when(
      loading: () => ListTile(
        leading: _leadingIcon,
        title: Text(_providerLabel(l10n),
            style: const TextStyle(color: Colors.white, fontSize: 14)),
        subtitle: Text(l10n.settingsAccountLinkLoadingSubtitle,
            style: const TextStyle(color: Colors.white38, fontSize: 12)),
        trailing: const SizedBox(
          width: 18, height: 18,
          child: CircularProgressIndicator(
              strokeWidth: 2, color: AppTheme.primary),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      ),
      error: (_, __) => ListTile(
        leading: _leadingIcon,
        title: Text(_providerLabel(l10n),
            style: const TextStyle(color: Colors.white, fontSize: 14)),
        subtitle: Text(l10n.settingsAccountLinkErrorSubtitle,
            style: const TextStyle(color: Colors.red, fontSize: 12)),
        trailing: IconButton(
          icon: const Icon(Icons.refresh, color: Colors.white38, size: 20),
          onPressed: () => ref.invalidate(linkedAccountsProvider),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      ),
      data: (accounts) {
        final info = _info(accounts);
        final String subtitle;
        if (info.isLinked) {
          subtitle = maskEmail(info.email) ?? l10n.settingsAccountLinkLinkedFallback;
        } else if (_isOtherProviderLinked(accounts)) {
          subtitle = l10n.settingsAccountLinkDisabledSubtitle(_otherProviderLabel());
        } else {
          subtitle = l10n.settingsAccountLinkUnlinkedSubtitle;
        }
        // 【FEAT-290】別 provider が連携済みなら本タイルを disabled 化。
        // Backend FEAT-178「1 ユーザー 1 provider 制約」を UI 側で事前ガード。
        final isDisabled = !info.isLinked && _isOtherProviderLinked(accounts);

        // disabled 時は leading icon / title / chevron もすべて減光して
        // 「タップできない」ことを明確に視覚化する。
        final titleColor    = isDisabled ? Colors.white24 : Colors.white;
        final subtitleColor = isDisabled
            ? Colors.white24
            : (info.isLinked ? AppTheme.primary : Colors.white38);

        return Opacity(
          opacity: isDisabled ? 0.55 : 1.0,
          child: ListTile(
            enabled: !isDisabled,        // タップ反応を OS レベルで殺す
            leading: _leadingIcon,
            title: Text(_providerLabel(l10n),
                style: TextStyle(color: titleColor, fontSize: 14)),
            subtitle: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: Align(
                key: ValueKey(subtitle),
                alignment: Alignment.centerLeft,
                child: Text(
                  subtitle,
                  style: TextStyle(color: subtitleColor, fontSize: 12),
                ),
              ),
            ),
            trailing: _isLinking
                ? const SizedBox(
                    width: 18, height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppTheme.primary),
                  )
                : AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    child: info.isLinked
                        ? const Icon(Icons.check_circle_outline,
                            key: ValueKey('linked'),
                            color: AppTheme.primary, size: 20)
                        : Icon(
                            // 【FEAT-290】disabled 時はロック型アイコンへ差し替えて
                            // 「物理的に閉じている」感を視覚化
                            isDisabled
                                ? Icons.lock_outline
                                : Icons.chevron_right,
                            key: ValueKey(isDisabled ? 'disabled' : 'unlinked'),
                            color: Colors.white24,
                            size: 20,
                          ),
                  ),
            // 【FEAT-290】disabled 時は onTap を null にしてリップル無効化
            onTap: isDisabled ? null : () => _handleTap(accounts),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
          ),
        );
      },
    );
  }
}
