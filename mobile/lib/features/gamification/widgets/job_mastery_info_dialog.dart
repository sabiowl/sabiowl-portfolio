import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';

/// 【2026-08-09】ジョブ熟練度の仕組みを説明する情報ダイアログ。
///
/// ## なぜ要るか
///
/// ユーザー報告 2026-08-09:「熟練度レベルは何をすると上がるのか分からない」。
/// バーは進捗を見せるが**上げ方を一切説明していなかった**ため、
/// 「何をすれば伸びるのか」がアプリ内のどこにも書かれていない状態だった。
///
/// ## 記載内容の真実値 (すべて実装から引いた値)
///
/// | 項目 | 出典 |
/// |---|---|
/// | 加算タイミング | `views/battle/finish.py:330` —— `if result == 'win'` の**外側**なので勝敗どちらでも入る |
/// | 対象ジョブ | `services/battle_finish_service.py:135` —— `player.active_character.job` のみ |
/// | 勝利 5 / 敗北 1 | `constants.py:287-288` |
/// | tier 倍率 | `constants.py:291-296` (zako 1.0 / mid_boss 1.5 / boss 2.5 / hidden_boss 4.0) |
/// | Lv 上限 10 | `constants.py:286` |
///
/// ⚠️ **数値を変えるときは `constants.py` と本ダイアログの ARB を両方直すこと。**
/// 片方だけ直すと「説明が嘘をつく」状態になる —— 本ダイアログが生まれた原因
/// (`party_edit_dialog` の stale な予告バナー) と同じ型の劣化。
///
/// 単一「閉じる」ボタンのみ (BUG-138 例外: navigation を一切持たない情報ダイアログ)。
/// `ChallengeDetailDialog` と同じ構成。
class JobMasteryInfoDialog extends StatelessWidget {
  const JobMasteryInfoDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      backgroundColor: AppTheme.card,
      title: Text(
        l10n.gamifJobMasteryInfoTitle,
        style: const TextStyle(color: Colors.white),
      ),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.gamifJobMasteryInfoLead, style: _bodyStyle),
            const SizedBox(height: 14),

            _sectionTitle(l10n.gamifJobMasteryInfoHowToTitle),
            _bullet(l10n.gamifJobMasteryInfoHowToBattle),
            _bullet(l10n.gamifJobMasteryInfoHowToEquipped),
            _bullet(l10n.gamifJobMasteryInfoHowToAuto),
            const SizedBox(height: 14),

            _sectionTitle(l10n.gamifJobMasteryInfoAmountTitle),
            _bullet(l10n.gamifJobMasteryInfoAmountWinLose),
            _bullet(l10n.gamifJobMasteryInfoAmountTier),
            const SizedBox(height: 14),

            _sectionTitle(l10n.gamifJobMasteryInfoMaxTitle),
            Text(l10n.gamifJobMasteryInfoMaxBody, style: _bodyStyle),
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonClose,
              style: const TextStyle(color: Colors.white70)),
        ),
      ],
    );
  }

  static const TextStyle _bodyStyle =
      TextStyle(color: Colors.white70, fontSize: 13, height: 1.5);

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          text,
          style: const TextStyle(
              color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
        ),
      );

  Widget _bullet(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('・', style: _bodyStyle),
            Expanded(child: Text(text, style: _bodyStyle)),
          ],
        ),
      );
}

/// 熟練度ダイアログを開く ⓘ ボタン。
///
/// **[JobMasteryBar] の中には置かない。** バーは未バトルのジョブで何も描画
/// しないため、中に入れると「熟練度が 0 の人にだけ説明が出ない」という、
/// 最も説明を必要とする人に届かない配置になる (本件の報告者がまさにその状態)。
/// 呼び出し側が**データの有無と無関係に**画面あたり 1 つ置くこと。
class JobMasteryInfoButton extends StatelessWidget {
  const JobMasteryInfoButton({super.key, this.size = 16});

  final double size;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return IconButton(
      icon: Icon(Icons.info_outline, color: Colors.white54, size: size),
      tooltip: l10n.gamifJobMasteryInfoTooltip,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: BoxConstraints(minWidth: size + 12, minHeight: size + 12),
      onPressed: () => showDialog<void>(
        context: context,
        builder: (_) => const JobMasteryInfoDialog(),
      ),
    );
  }
}
