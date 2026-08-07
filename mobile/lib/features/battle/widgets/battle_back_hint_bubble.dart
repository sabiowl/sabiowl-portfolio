import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';

/// 【FEAT-462 (2026-06-22)】バトル戻るボタンの初回ヒント吹き出し。
///
/// 「戻るボタンを押してもバトルは継続する」(FEAT-295/297 のホーム額縁内
/// ミニフレーム前景進行) という設計を、初見ユーザーに発見させるための
/// 一度限りの案内。表示から 4 秒後に自動でフェードアウトし、
/// [onComplete] で親へ非表示化を通知する。
///
/// `IgnorePointer` でラップしているため、表示中もバトル操作 (倍速チップ等)
/// を妨げない。
///
/// **Pre-mortem #1 (dispose race, BUG-66 v3)**: `dispose()` 内では
/// `Timer.cancel()` と `AnimationController.dispose()` のみを行い、
/// `setState()` は呼ばない。Timer の callback 側も `if (!mounted) return;`
/// で確実にガードする。
class BattleBackHintBubble extends StatefulWidget {
  const BattleBackHintBubble({super.key, this.onComplete});

  /// フェードアウト完了後に呼ばれる (親が `_showBackHint = false` にする想定)。
  final VoidCallback? onComplete;

  @override
  State<BattleBackHintBubble> createState() => _BattleBackHintBubbleState();
}

class _BattleBackHintBubbleState extends State<BattleBackHintBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fadeCtrl;
  Timer? _dismissTimer;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    )..forward();
    // 4 秒後にフェードアウト → onComplete で親に通知。
    _dismissTimer = Timer(const Duration(milliseconds: 4000), () async {
      if (!mounted) return;
      await _fadeCtrl.reverse();
      if (!mounted) return;
      widget.onComplete?.call();
    });
  }

  @override
  void dispose() {
    // 【BUG-66 v3】setState は呼ばない。Timer cancel + Controller dispose のみ。
    _dismissTimer?.cancel();
    _dismissTimer = null;
    _fadeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return IgnorePointer(
      child: FadeTransition(
        opacity: _fadeCtrl,
        child: Container(
          margin: const EdgeInsets.only(left: 16, top: kToolbarHeight + 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          constraints: const BoxConstraints(maxWidth: 280),
          decoration: BoxDecoration(
            color: AppTheme.primary.withValues(alpha: 0.95),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Text(
            l10n.battleBackHintSabi_message,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ),
      ),
    );
  }
}
