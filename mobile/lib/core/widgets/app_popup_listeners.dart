import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/providers/auth_provider.dart';
import '../../features/habits/providers/habits_provider.dart';
import '../../features/habits/widgets/login_bonus_calendar_dialog.dart';
import '../../shared/widgets/backup_prompt_sheet.dart';
import '../../shared/widgets/level_up_dialog.dart';
import '../constants/preferences_keys.dart';
import '../router/app_router.dart';
import '../services/popup_serializer.dart';

/// 【BUG-150 (2026-08-29)】画面をまたいで出るべき popup の listener。
///
/// ## なぜ `main.dart` 直下なのか
///
/// 旧配置は `home_listeners.dart` = **`HomePage` の中だけ**だった。
/// `app_router.dart` の `ShellRoute` は素の `ShellRoute`（`StatefulShellRoute`
/// ではない）なので、**タブを切り替えると `child` が丸ごと差し替わり
/// `HomePage` は unmount される**。しかも `ref.listen` は **edge-triggered** で、
/// ホームに戻って mount された時点で provider が既に non-null でも
/// 「変化」が起きないため**発火しない = 黙って消える**。
///
/// 結果として、**カレンダータブから達成してレベルアップしても祝われなかった**
/// （実機 2026-08-29 で再現）。
///
/// 🔵 これは FEAT-479 の global hotfix (2026-07-07) が `PuzzlePieceListener` を
/// `home_body.dart` から `main.dart` に移したのとまったく同じ構造である。
/// **かけらは直っていたが、レベルアップとログインボーナスは直っていなかった。**
///
/// ## 移設であって複製ではない
///
/// 🔴 `home_listeners.dart` 側からは**削除してある**。両方に置くと二重発火する。
/// `world_frame_listeners.dart` の冒頭コメントが同じ注意を書いている。
///
/// ## context の扱い
///
/// `main.dart` の `builder` の context は go_router の Router / Navigator の
/// **祖先**なので、`Navigator.of(context, rootNavigator: true)` は null crash する。
/// `MonthlyTicketAwardedDialog` と同じく `rootNavigatorKey.currentContext`
/// （Navigator の内側）を使い、`useRootNavigator: false` を渡す。
/// 起動直後の未 attach 状態は自分の context で救済する。
///
/// ## ここに置かないもの
///
/// RewardToast / 光ビーム / コンバック SnackBar / リリアパネルは
/// **ホーム画面の演出**なので `home_listeners.dart` に残す。
/// あちらは `Overlay` や `ScaffoldMessenger` を握っており、ホームが
/// unmount されているときに出しても意味がない。
class AppPopupListeners extends ConsumerStatefulWidget {
  const AppPopupListeners({required this.child, super.key});
  final Widget child;

  @override
  ConsumerState<AppPopupListeners> createState() => _AppPopupListenersState();
}

class _AppPopupListenersState extends ConsumerState<AppPopupListeners> {
  /// `showDialog` に渡す context。Navigator の**内側**を優先する。
  BuildContext get _dialogContext =>
      rootNavigatorKey.currentContext ?? context;

  @override
  Widget build(BuildContext context) {
    // ── 【BUG-122】ログインボーナス → 7 日カレンダーダイアログ ─────────────
    ref.listen<Map<String, dynamic>?>(pendingLoginBonusProvider, (_, bonus) {
      if (bonus == null) return;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        await PopupSerializer.enqueueShowDialog<void>(
          context: _dialogContext,
          useRootNavigator: false,   // 既に Navigator の内側
          barrierDismissible: true,
          // 【FEAT-534】2: その日の節目。順序の真実値は PopupPriority。
          priority: PopupPriority.loginBonus,
          builder: (_) => LoginBonusCalendarDialog(bonus: bonus),
        );
        if (!mounted) return;
        ref.read(pendingLoginBonusProvider.notifier).state = null;
        ref.read(playerNotifierProvider.notifier).refresh();
      });
    });

    // ── レベルアップ検知 → ダイアログ表示 ──────────────────────────────
    ref.listen<int?>(levelUpNotifierProvider, (_, newLevel) {
      if (newLevel == null) return;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        final autoAllocs      = ref.read(levelUpAutoAllocationsProvider);
        final crystalsAwarded = ref.read(levelUpCrystalsProvider);
        final wantStats = await LevelUpDialog.show(
          _dialogContext,
          newLevel,
          autoAllocations: autoAllocs,
          crystalsAwarded: crystalsAwarded,
          useRootNavigator: false,   // 既に Navigator の内側
        );
        if (!mounted) return;
        ref.read(levelUpNotifierProvider.notifier).state = null;
        ref.read(levelUpAutoAllocationsProvider.notifier).state = const {};
        ref.read(levelUpCrystalsProvider.notifier).state = const {};

        // 【BUG-65】dialog dispose 完了 (150ms transitionDuration + マージン) を
        // 待ってから navigation することで defunct freeze を構造的に解消。
        if (wantStats == true) {
          await Future.delayed(const Duration(milliseconds: 300));
          final navContext = rootNavigatorKey.currentContext;
          if (navContext == null || !navContext.mounted) return;
          navContext.push(AppRoutes.stats);
          return;
        }

        if (kBackupSheetMilestoneLevels.contains(newLevel)) {
          final isGuest = ref.read(isGuestModeProvider).valueOrNull ?? false;
          if (isGuest && await shouldShowBackupPromptSheet(newLevel)) {
            await markBackupPromptSheetShown(newLevel);
            await Future.delayed(const Duration(milliseconds: 300));
            final sheetContext = rootNavigatorKey.currentContext;
            if (sheetContext == null || !sheetContext.mounted) return;
            await showModalBottomSheet<void>(
              context:            sheetContext,
              useRootNavigator:   false,   // 既に Navigator の内側
              backgroundColor:    Colors.transparent,
              isScrollControlled: true,
              builder: (_) => const BackupPromptSheet(),
            );
          }
        }
      });
    });

    return widget.child;
  }
}
