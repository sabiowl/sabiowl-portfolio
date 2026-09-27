import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../services/job_mastery_service.dart';

/// ジョブ熟練度バー (read-only)。
///
/// 【FEAT-511 Phase A (2026-07-30)】として `character_page.dart` に private
/// `_JobMasteryBar` で実装されたものを、**2026-08-09 に共有 widget へ切り出した**。
///
/// ## なぜ切り出したか
///
/// ユーザー報告 2026-08-09:「ジョブ熟練度のゲージが見当たらない」。
/// Phase A の表示先はキャラクター画面だけで、**ジョブを見に行く自然な導線である
/// 編成 → ジョブ一覧 (`JobSelectionOverlay`) には無かった**。実装済みなのに
/// 「未実装では」と疑われる状態だったため、同じバーを両方に置く。
///
/// 複製せず共有にしたのは、`character_page` 側だけ直して overlay 側が取り残される
/// 型の劣化を防ぐため (このリポジトリで繰り返し起きている「片方だけ更新」)。
///
/// ## 呼び出し側から見た契約
///
/// - `Job` (battle/models) と `JobChoice` (battle/widgets/job_choices) の**両方**から
///   使えるよう、型ではなく **`jobId` / `jobName` の 2 値**を受ける
/// - **未バトルのジョブでは何も描画しない** (`SizedBox.shrink()`)。
///   熟練度は「装着して戦った実績」なので、0 のゲージを並べて急かさない
///   —— サビ哲学「押し付けない」(Phase A の元実装から引き継いだ判断)
/// - `jobMasteriesProvider` は **1 request で全ジョブ分を一括取得**する
///   (Phase A の S8 対策)。同一画面に本 widget を N 個並べても通信は 1 本
class JobMasteryBar extends ConsumerWidget {
  const JobMasteryBar({
    super.key,
    required this.jobId,
    required this.jobName,
    this.showUnlockHint = true,
  });

  /// `Job.jobId` / `JobChoice.id` に対応する識別子。
  final String jobId;

  /// 表示名。ラベル (`{jobName} Lv {level} / 10`) に埋め込む。
  final String jobName;

  /// Max 到達時に「他のキャラにも装着可能になります」ヒントを出すか。
  ///
  /// `JobSelectionOverlay` の**未装着**ジョブでは `false` にする ——
  /// そちらは行内に既に「熟練度 Max で解禁」の locked hint があり、
  /// 同じ意味の文が 2 行並ぶため。
  final bool showUnlockHint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final masteryAsync = ref.watch(jobMasteriesProvider);
    final l10n = AppLocalizations.of(context)!;

    return masteryAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (masteries) {
        final matching = masteries.where((x) => x.jobId == jobId);
        if (matching.isEmpty) return const SizedBox.shrink();
        final m = matching.first;

        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 【2026-08-09 ユーザー要望】「あと N EXP で Lv M ですよ」を
              // **`20 / 34 EXP` の分数表記**に変更。
              //
              // 表記は `shared/widgets/exp_bar.dart:142` の
              // `'${exp} / ${expToNext} EXP'` に揃えた —— プレイヤー EXP バーと
              // 同じ読み方にするため、ここで独自の書式を発明しない。
              //
              // レイアウトも同 widget と同じ「Lv が左 / EXP が右」の 1 行。
              // 別行に積むと「Lv 3 / 10」と「20 / 34」の**分数が 2 つ縦に並んで
              // どちらが何か読み取りにくい**ため、左右に離して単位 `EXP` で
              // 区別する。行数が減るのでジョブ一覧 (14 件) の圧迫も避けられる。
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (m.isMaxed)
                          const Text('👑 ', style: TextStyle(fontSize: 13)),
                        Flexible(
                          child: Text(
                            m.isMaxed
                                ? l10n.gamifCharacterJobMasteryMax(jobName)
                                : l10n.gamifCharacterJobMasteryProgress(
                                    jobName, m.level),
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: m.isMaxed ? AppTheme.primary : Colors.white70,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Max では EXP が 0 にキャップされる (Backend が繰り越さない)
                  // ため分数を出さない。0 / 0 は意味を持たない。
                  if (!m.isMaxed)
                    Text(
                      '${m.exp} / ${m.expToNext} EXP',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                        fontSize: 11,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              LinearProgressIndicator(
                value: m.expProgress,
                minHeight: 4,
                backgroundColor: Colors.white.withValues(alpha: 0.1),
                valueColor: AlwaysStoppedAnimation(
                  m.isMaxed ? AppTheme.primary : Colors.white70,
                ),
              ),
              // 【2026-08-09】非 Max の 3 行目 (「あと N EXP で Lv M ですよ 🪶」) は
              // 撤去。上の分数表記が同じ情報を持つうえ、その文言は
              // **`expToNext` を残量と誤解した嘘の数字**を出していた
              // (exp=5 / expToNext=10 で「あと 10 EXP」= 実際は 5)。
              // Max のときだけ解禁ヒントを出す。
              if (m.isMaxed && showUnlockHint) ...[
                const SizedBox(height: 2),
                Text(
                  l10n.gamifCharacterJobMasteryUnlockHint,
                  style: const TextStyle(fontSize: 10, color: Colors.white54),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
