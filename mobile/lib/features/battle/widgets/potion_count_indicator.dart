import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../models/recovery_potion.dart';
import '../providers/battle_provider.dart';

/// 【FEAT-298】戦闘中の回復薬残数インジケータ。
///
/// `BattleSession.potionsPlanned > 0` のときのみ表示、
/// 使用済みなら半透明・残数あれば明色で「💊 残 X / Y」形式。
/// MiniBattleArena / BattlePage の両方に配置可能。
///
/// 使用例:
/// ```dart
/// const Positioned(top: 8, right: 8, child: PotionCountIndicator())
/// ```
class PotionCountIndicator extends ConsumerWidget {
  const PotionCountIndicator({super.key, this.compact = false});

  /// true → 縮小表示（MiniBattleArena 内）/ false → 通常 (BattlePage)。
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final session = ref.watch(battleSessionProvider);
    final planned = session.potionsPlanned;
    if (planned <= 0) return const SizedBox.shrink();

    final remaining = session.potionsRemaining;
    final exhausted = remaining <= 0;
    final alpha = exhausted ? 0.4 : 1.0;

    final fontSize = compact ? 11.0 : 13.0;
    final padding = compact
        ? const EdgeInsets.symmetric(horizontal: 6, vertical: 2)
        : const EdgeInsets.symmetric(horizontal: 8, vertical: 4);

    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.18),
          width: 1,
        ),
      ),
      child: Text(
        '${RecoveryPotion.emoji} ${l10n.battlePotionCountRemaining(remaining, planned)}',
        style: TextStyle(
          color: Colors.white.withValues(alpha: alpha),
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
