import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../gamification/widgets/job_mastery_bar.dart';  // 【2026-08-09】熟練度バー
import '../../gamification/widgets/job_mastery_info_dialog.dart';  // 【2026-08-09】ⓘ
import '../models/job.dart';
import 'job_choices.dart';

/// 【FEAT-431】ジョブ一覧 Overlay (EquipmentSelectionOverlay と同パターン)。
///
/// PartyEditDialog 内に Stack で重ね合わせ表示される最手前カード。
/// FEAT-430 で「キャラ = ジョブ固定」を採択済のため、本 Overlay は**閲覧専用**:
/// 設定中ジョブはチェックマーク + 「現在のジョブ」バナー、他ジョブは鍵アイコン +
/// 「熟練度 Max で解禁 (v1.1+)」hint。各カードに「装備する」相当ボタンは置かない。
///
/// 構造 (EquipmentSelectionOverlay §1.2 仕様準拠):
///   - ヘッダー: ＜ 戻る | ジョブ一覧 | ×
///   - 現在のジョブバナー: 「現在のジョブ: ⚔️ {job_name} ({character_name})」
///   - ジョブ一覧 (ListView スクロール): 各 ListTile に鍵アイコン + 解禁 hint
///   - 閉じる動線 3 経路: ＜ 戻る / × / カード外背景タップ
///
/// 設計判断:
///   - **Stack 重ね合わせ**: caller (PartyEditDialog) が Stack の最手前に
///     置き、`isSelectingJob` フラグで条件描画する (EquipmentSelectionOverlay と同パターン)
///   - **ボタンなし**: FEAT-430 哲学維持、v1.1+ で
///     `doc/design/job_mastery_v1_1.md` Phase B 解禁時に「熟練度 Max なら付け替え可」
///     ボタン追加 (= 本 widget の段階的拡張、ファイル名は維持)
///   - **解禁 hint 文言**: 「熟練度 Max で解禁 (v1.1+)」(v1.1+ 設計と整合、
///     ユーザー期待値ブラックス生成)
class JobSelectionOverlay extends StatelessWidget {
  const JobSelectionOverlay({
    super.key,
    required this.currentJob,
    required this.currentCharacterName,
    required this.onClose,
  });

  /// 現在のジョブ (active_character.job、null = warrior フォールバック)
  final Job? currentJob;

  /// 現在のキャラ名 (バナー表示「現在のジョブ: ⚔️ {job} ({character})」用)
  final String? currentCharacterName;

  /// ヘッダーの「＜ 戻る」/「×」/カード外タップで発火。caller が
  /// `setState(() => _isSelectingJob = false)` で本 widget を畳む。
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.card,
          border: Border.all(
            color: AppTheme.primary.withValues(alpha: 0.5),
            width: 1.5,
          ),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 20,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(context, l10n),
            const Divider(color: Colors.white12, height: 1),
            _buildCurrentJobBanner(l10n),
            const Divider(color: Colors.white12, height: 1),
            Flexible(child: _buildJobList()),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left, color: Colors.white),
            onPressed: onClose,
            tooltip: l10n.battleOverlayBackTooltip,
          ),
          Expanded(
            child: Text(
              l10n.battleJobSelectionTitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white),
            onPressed: onClose,
            tooltip: l10n.battleOverlayCloseTooltip,
          ),
        ],
      ),
    );
  }

  Widget _buildCurrentJobBanner(AppLocalizations l10n) {
    final jobId = currentJob?.jobId ?? 'warrior';
    final jobChoice = kJobs.firstWhere((j) => j.id == jobId, orElse: () => kJobs.first);
    final jobName = jobChoice.localizedName(l10n);
    final charName = currentCharacterName ?? '—';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: AppTheme.primary.withValues(alpha: 0.12),
      child: Row(
        children: [
          const Text('⚔️', style: TextStyle(fontSize: 14)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l10n.battleJobSelectionCurrentJobLabel(jobName, charName),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          // 【2026-08-09】熟練度の説明 ⓘ。
          //
          // **バナー側に置くのが要点。** 熟練度バーは未バトルのジョブで何も
          // 描画しないため、バーの中に入れると「熟練度 0 の人にだけ説明が
          // 出ない」= 最も説明を必要とする人に届かない配置になる
          // (本件の報告者がまさにその状態だった)。
          // ここなら**データの有無と無関係に**画面あたり 1 つ常に出る。
          const JobMasteryInfoButton(),
        ],
      ),
    );
  }

  Widget _buildJobList() {
    final activeJobId = currentJob?.jobId;
    return ListView.separated(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: kJobs.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, index) {
        final j = kJobs[index];
        final isCurrent = j.id == activeJobId;
        return _JobListTile(
          job: j,
          isCurrent: isCurrent,
        );
      },
    );
  }
}

/// ジョブ一覧の各カード。
/// 設定中: チェックマーク + 強調 border + 通常 opacity
/// 他: 鍵アイコン + 「熟練度 Max で解禁 (v1.1+)」hint + opacity 0.6
class _JobListTile extends StatelessWidget {
  const _JobListTile({
    required this.job,
    required this.isCurrent,
  });

  final JobChoice job;
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final color = isCurrent ? AppTheme.primary : Colors.white24;
    return Opacity(
      opacity: isCurrent ? 1.0 : 0.6,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          border: Border.all(color: color, width: 1.5),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    job.localizedName(l10n),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l10n.battleJobStatsSummary(
                      job.atbSpeedModifier.toString(),
                      job.attackPowerModifier.toString(),
                      job.ultCost,
                    ),
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.7),
                      fontSize: 11,
                    ),
                  ),
                  if (!isCurrent) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(Icons.lock_outline,
                          size: 12,
                          color: AppTheme.primary.withValues(alpha: 0.7)),
                        const SizedBox(width: 4),
                        Text(
                          l10n.battleJobSelectionLockedHint,
                          style: TextStyle(
                            color: AppTheme.primary.withValues(alpha: 0.7),
                            fontSize: 11,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ],
                    ),
                  ],
                  // ── 【2026-08-09】ジョブ熟練度バー ──────────────────
                  //
                  // ユーザー報告「熟練度のゲージが見当たらない」への対応。
                  // Phase A の表示先はキャラクター画面だけで、**ジョブを見に来る
                  // 最も自然な導線であるここに無かった**。
                  //
                  // 未バトルのジョブでは [JobMasteryBar] が何も描画しないため、
                  // 「戦ったことのあるジョブにだけ静かに実績が出る」形になる。
                  //
                  // `showUnlockHint` は装着中のみ true。未装着側は直上に
                  // 「熟練度 Max で解禁」の locked hint が既にあり、Max 到達時に
                  // 同じ意味の文が 2 行並ぶのを避ける。
                  JobMasteryBar(
                    jobId: job.id,
                    jobName: job.localizedName(l10n),
                    showUnlockHint: isCurrent,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            // 設定中: チェックマーク / 他: 鍵アイコン
            Icon(
              isCurrent ? Icons.check_circle : Icons.lock,
              color: color,
              size: 24,
            ),
          ],
        ),
      ),
    );
  }
}
