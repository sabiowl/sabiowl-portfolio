import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import '../../l10n/app_localizations.dart';

// 予定・ToDo・習慣の追加フォームをギルド編成ダイアログと同じスタイルの
// 中央モーダルで表示する共通ラッパー。
// 各ページファイルの show*Modal 関数がこれを呼ぶ。
Future<void> showAddTaskModal(
  BuildContext context, {
  required String title,
  required Widget child,
}) {
  final l10n = AppLocalizations.of(context)!;
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: l10n.commonClose,
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (dialogContext, __, ___) => _AddTaskModalShell(
      title: title,
      onClose: () => Navigator.of(dialogContext).pop(),
      child: child,
    ),
    transitionBuilder: (_, animation, __, child) => ScaleTransition(
      scale: CurvedAnimation(parent: animation, curve: Curves.easeOut),
      child: FadeTransition(opacity: animation, child: child),
    ),
  );
}

class _AddTaskModalShell extends StatelessWidget {
  const _AddTaskModalShell({
    required this.title,
    required this.onClose,
    required this.child,
  });

  final String title;
  final VoidCallback onClose;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final media = MediaQuery.of(context);
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: media.size.width - 48,
          height: media.size.height * 0.75,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: AppTheme.sheetBackground,
            border: Border.all(
              color: AppTheme.primary.withValues(alpha: 0.4),
              width: 1.5,
            ),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 24,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 8, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 20, color: Colors.white70),
                      tooltip: l10n.commonClose,
                      onPressed: onClose,
                    ),
                  ],
                ),
              ),
              const Divider(color: Colors.white12, height: 8, thickness: 0.5),
              Expanded(child: child),
            ],
          ),
        ),
      ),
    );
  }
}
