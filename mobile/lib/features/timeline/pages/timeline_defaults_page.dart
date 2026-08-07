import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';  // 【FEAT-506】
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../providers/timeline_provider.dart';
import '../widgets/template_row.dart';

// ── デフォルト設定ページ（全画面） ───────────────────────────────────────────

/// 歯車ボタンから遷移する「デフォルト予定テンプレート」管理ページ。
/// FEAT-174: BottomSheet → 全画面ページへ変更。
/// FEAT-175: _openAdd / _openEdit を context.push() に変更。
///
/// 【FEAT-506 (2026-07-29)】画面上部に Global toggle「自動作成」を追加。
/// 旧 settings_page.dart の Global toggle は削除し、本画面に集約 (Single source
/// of truth)。理由: 画面のコンテキスト = デフォルト予定 = toggle の対象と一致、
/// 上位 Global toggle と下位 per-template toggle の階層が視覚的に明快になる
/// (FEAT-506 §S4「Global vs per-template UI 混乱」予防策の実装)。
///
/// 【FEAT-506 hotfix (2026-07-29)】user 報告 2 件対応:
///   (1) スクロール不可バグ: IgnorePointer を ListView 全体に被せたため
///       スクロールジェスチャも block していた → per-child (TemplateRow +
///       「テンプレートを登録」button) に限定して修正
///   (2) subtitle 説明文を info アイコン (ⓘ) + tap で dialog 表示に置換
///       (画面の情報密度低下、「押し付けない」Sabi 哲学に整合)
class TimelineDefaultsPage extends ConsumerStatefulWidget {
  const TimelineDefaultsPage({super.key});

  @override
  ConsumerState<TimelineDefaultsPage> createState() =>
      _TimelineDefaultsPageState();
}

class _TimelineDefaultsPageState extends ConsumerState<TimelineDefaultsPage> {
  // 【FEAT-506】Global toggle 状態。SharedPreferences と同期、default: true。
  bool _autoCreateEnabled = true;

  @override
  void initState() {
    super.initState();
    // SharedPreferences から現在の toggle 状態を読み込む (default: true)。
    SharedPreferences.getInstance().then((prefs) {
      if (mounted) {
        setState(() {
          _autoCreateEnabled =
              prefs.getBool('timeline_auto_create_enabled') ?? true;
        });
      }
    });
  }

  void _openEdit(BuildContext context, TimelineTemplate t) {
    context.push(AppRoutes.editTemplate, extra: t);
  }

  void _openAdd(BuildContext context) {
    HapticFeedback.selectionClick();
    context.push(AppRoutes.addTemplate);
  }

  /// 【FEAT-506】Global toggle の切替。SharedPreferences 保存 + provider invalidate。
  /// OFF 時はサビ口調 SnackBar で「既存の予定は残る」旨を明示 (§S1 誤解回避)。
  Future<void> _onAutoCreateToggle(bool newValue) async {
    HapticFeedback.selectionClick();
    setState(() => _autoCreateEnabled = newValue);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('timeline_auto_create_enabled', newValue);
    if (!newValue && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context)!.timelineDefaultsPageAutoCreateOffSnackbarSabi_message,
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
    ref.invalidate(timelineAutoCreateProvider);
  }

  /// 【FEAT-506 hotfix (2026-07-29)】自動作成トグルの ⓘ アイコン tap で表示する
  /// 機能説明ダイアログ。SnackBar (6 秒消失) より読ませたい説明文向け。
  /// AppTheme.card 背景 + Sabi 口調でモーダル感を抑える。
  ///
  /// 【FEAT-215】ShellRoute 配下対応: Navigator.pop は dialogContext を使う。
  void _showAutoCreateInfo(BuildContext context) {
    HapticFeedback.selectionClick();
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppTheme.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text(
          AppLocalizations.of(context)!.timelineDefaultsPageAutoCreateLabel,
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
        content: Text(
          AppLocalizations.of(context)!.timelineDefaultsPageAutoCreateDialogContentSabi_message,
          style: const TextStyle(color: Colors.white70, height: 1.6, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            style: TextButton.styleFrom(foregroundColor: AppTheme.primary),
            child: Text(AppLocalizations.of(context)!.timelineDefaultsPageAutoCreateDialogClose),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final templates = ref.watch(timelineTemplatesProvider);

    return Scaffold(
      backgroundColor: AppTheme.surface,
      appBar: AppBar(
        backgroundColor: AppTheme.surface,
        title: Text(AppLocalizations.of(context)!.timelineDefaultsPageTitle),
        // 戻るボタンは Flutter 自動付与（leading: BackButton()）
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [

          // ── 説明文 ────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              AppLocalizations.of(context)!.timelineDefaultsPageSubtitleSabi_message,
              style: TextStyle(
                color:    Colors.white.withValues(alpha: 0.38),
                fontSize: 12,
                height:   1.5,
              ),
            ),
          ),

          const SizedBox(height: 8),

          // ── 【FEAT-506】Global toggle: 自動作成 [ⓘ] [Switch] ─────
          // 【hotfix 2026-07-29】subtitle 説明文を info アイコン → dialog に置換 (情報密度削減)。
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                // 自動作成 title
                Text(
                  AppLocalizations.of(context)!.timelineDefaultsPageAutoCreateLabel,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
                const SizedBox(width: 4),
                // ⓘ info アイコン (tap で dialog)
                InkWell(
                  onTap: () => _showAutoCreateInfo(context),
                  borderRadius: BorderRadius.circular(16),
                  child: const Padding(
                    padding: EdgeInsets.all(6),
                    child: Icon(
                      Icons.info_outline,
                      size: 16,
                      color: Colors.white54,
                    ),
                  ),
                ),
                const Spacer(),
                // toggle Switch (右端)
                Switch(
                  value: _autoCreateEnabled,
                  activeColor: AppTheme.primary,
                  onChanged: _onAutoCreateToggle,
                ),
              ],
            ),
          ),

          const SizedBox(height: 8),

          // ── テンプレート一覧 ──────────────────────────────────
          // 【FEAT-506 hotfix 2026-07-29】ListView 全体を IgnorePointer で
          // 包むとスクロールも block されるため、per-child (TemplateRow +
          // 「テンプレートを登録」button) に IgnorePointer を移した。
          // 注記 text は元々インタラクションがないので unwrap 可。
          // AnimatedOpacity は ListView 外側で dim (視覚のみ)、scroll は生きる。
          Expanded(
            child: AnimatedOpacity(
              opacity: _autoCreateEnabled ? 1.0 : 0.5,
              duration: const Duration(milliseconds: 200),
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                  16, 0, 16,
                  16 + MediaQuery.of(context).padding.bottom,
                ),
                children: [
                  // Per-template row: Global OFF なら tap 無効化
                  ...templates.map((t) => IgnorePointer(
                    ignoring: !_autoCreateEnabled,
                    child: TemplateRow(
                      key:      ValueKey(t.id),
                      template: t,
                      // FEAT-143: 有効化（ON）したときのみ当日タイムラインへ即時反映
                      // 【FEAT-208】無効化 → 再有効化のケースでも当日に再反映されるよう、
                      // toggle() 内で createdIds から該当 ID を除去 → ここで invalidate +
                      // 再実行することで autoDispose プロバイダーのキャッシュも刷新する。
                      onToggle: (val) async {
                        await ref
                            .read(timelineTemplatesProvider.notifier)
                            .toggle(t.id);
                        if (val) {
                          final now   = DateTime.now();
                          final today = DateTime(now.year, now.month, now.day);
                          ref.invalidate(timelineAutoCreateProvider(today));
                          ref
                              .read(timelineAutoCreateProvider(today).future)
                              .catchError((_) {});
                        }
                      },
                      onLongPress: () => _openEdit(context, t),
                    ),
                  )),

                  const SizedBox(height: 8),

                  // ── 「＋ テンプレートを登録」ボタン ─────────────
                  // 【20260729 review §3 A-2 対応】旧実装は Global OFF で登録
                  // button も無効化していたが、Global toggle が支配するのは
                  // 「明日以降に自動で予定を並べるか」であって「テンプレートを
                  // 書き溜めてよいか」ではない。OFF のまま来月分の型を用意する
                  // 自然な使い方が塞がっていたため、IgnorePointer から外す。
                  // dim (opacity 0.5) は AnimatedOpacity 経由で維持される。
                  GestureDetector(
                    onTap: () => _openAdd(context),
                    child: Container(
                        width:   double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        decoration: BoxDecoration(
                          color:        Colors.white.withValues(alpha: 0.04),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.1),
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.add, size: 16,
                                color: Colors.white.withValues(alpha: 0.4)),
                            const SizedBox(width: 6),
                            Text(
                              AppLocalizations.of(context)!.timelineDefaultsPageRegisterButton,
                              style: TextStyle(
                                color:    Colors.white.withValues(alpha: 0.45),
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                    ),
                  ),

                  const SizedBox(height: 10),

                  // ── 注記 ────────────────────────────────────────
                  // インタラクションなし = IgnorePointer 不要、常時表示。
                  Text(
                    AppLocalizations.of(context)!.timelineDefaultsPageFootnote,
                    style: TextStyle(
                      color:    Colors.white.withValues(alpha: 0.25),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
