import 'package:flutter/material.dart';

import '../../../core/router/app_router.dart' show rootNavigatorKey;  // 【2026-07-08 hotfix】
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';

/// 【FEAT-479 Phase 4 (2026-07-06)】完成演出モーダル (指示書 §4.3.3、§4.4)。
///
/// **演出構成** (総所要 約 3.5 秒):
/// 1. 呼出前 quest overlay 完了 (1200ms、caller responsibility)
/// 2. 呼出前 1500ms 静止 (caller responsibility)
/// 3. 白フェード発光 (600ms、モーダル build 冒頭で発火)
///    - `AnimatedOpacity` 0 → 0.5 → 0
/// 4. 中央モーダル表示
///    - タイトル: 「世界に、色が戻りましたね 🪶」
///    - 本文: 「あなたの一歩一歩が、この景色を少しずつ動かしてきました。」
///    - 報酬表示: 「+{diamonds}💎 / +{exp} EXP を贈りますね」
///    - 「見守る」単一ボタン (BUG-138 例外条項: 情報ダイアログ)
///
/// **エンドコンテンツ分岐** (`hasNextScene=false` = 全シーン完成):
/// - 本文差替: 「あなたはすべての景色を蘇らせました。 いつでもここに戻ってきてください」
/// - Sabi 誘導 (「次に手を伸ばす〜」) は表示しない
///
/// **BUG-65 遵守**: caller が `await showDialog<void>` → `Future.delayed(300ms)` →
/// (hasNextScene なら SceneSelectionPage push) の順で処理する想定。
class PuzzleCompletionModal extends StatefulWidget {
  const PuzzleCompletionModal({
    super.key,
    required this.sceneName,
    required this.rewardExp,
    required this.rewardDiamonds,
    required this.hasNextScene,
    this.nextSceneName,
  });

  final String sceneName;
  final int rewardExp;
  final int rewardDiamonds;
  final bool hasNextScene;
  final String? nextSceneName;

  @override
  State<PuzzleCompletionModal> createState() => _PuzzleCompletionModalState();
}

class _PuzzleCompletionModalState extends State<PuzzleCompletionModal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _flashCtrl;
  late final Animation<double> _flashOpacity;
  late final Animation<double> _contentOpacity;

  @override
  void initState() {
    super.initState();
    // 総 duration 800ms (白フェード 600ms + content fadeIn 200ms overlap)
    _flashCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    // 0-75%: 白フェード 0 → 0.5 → 0 (三角波)
    _flashOpacity = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: 0.5), weight: 30),
      TweenSequenceItem(tween: Tween(begin: 0.5, end: 0.0), weight: 45),
      TweenSequenceItem(tween: ConstantTween(0.0), weight: 25),
    ]).animate(_flashCtrl);
    // 50-100%: content 0 → 1 (fadeIn)
    _contentOpacity = CurvedAnimation(
      parent: _flashCtrl,
      curve: const Interval(0.5, 1.0, curve: Curves.easeOut),
    );
    _flashCtrl.forward();
  }

  @override
  void dispose() {
    _flashCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false, // 完成演出中は戻る禁止 (「見守る」ボタン tap のみで閉じる)
      child: Stack(
        children: [
          // 白フェード発光 (画面全体をカバー)
          AnimatedBuilder(
            animation: _flashOpacity,
            builder: (context, _) => Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: Colors.white.withValues(alpha: _flashOpacity.value),
                ),
              ),
            ),
          ),
          // 中央モーダル (fadeIn)
          Center(
            child: AnimatedBuilder(
              animation: _contentOpacity,
              builder: (context, child) => Opacity(
                opacity: _contentOpacity.value,
                child: child,
              ),
              child: _buildContent(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
      constraints: const BoxConstraints(maxWidth: 400),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: Colors.amber.withValues(alpha: 0.5),
          width: 2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.amber.withValues(alpha: 0.15),
            blurRadius: 32,
            spreadRadius: 4,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // シーン名 + タイトル
          Text(
            widget.sceneName,
            style: TextStyle(
              color: Colors.amber.withValues(alpha: 0.85),
              fontSize: 12,
              fontWeight: FontWeight.w500,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.puzzleWorldCompletionTitleSabi_message,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w600,
              height: 1.4,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),

          // 本文
          Text(
            widget.hasNextScene
                ? l10n.puzzleWorldCompletionBodyHasNextSabi_message
                : l10n.puzzleWorldCompletionBodyAllDoneSabi_message,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.85),
              fontSize: 13,
              height: 1.7,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),

          // 報酬表示 (amber ボックス)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            decoration: BoxDecoration(
              color: Colors.amber.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _RewardPill(
                  label: '💎',
                  value: '+${widget.rewardDiamonds}',
                ),
                _RewardPill(
                  label: 'EXP',
                  value: '+${widget.rewardExp}',
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            l10n.puzzleWorldCompletionRewardSuffixSabi_message,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.65),
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 20),

          // 次シーン誘導 (hasNextScene のみ)
          if (widget.hasNextScene && widget.nextSceneName != null) ...[
            Text(
              l10n.puzzleWorldCompletionNextSceneHintSabi_message,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.65),
                fontSize: 12,
                height: 1.6,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
          ],

          // 「見守る」単一ボタン (BUG-138 例外条項: 情報ダイアログ)
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 44),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: Text(
                l10n.puzzleWorldCompletionCloseButton,
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w500),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RewardPill extends StatelessWidget {
  const _RewardPill({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: const TextStyle(
            color: Colors.amber,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(
            color: Colors.amber.withValues(alpha: 0.75),
            fontSize: 10,
          ),
        ),
      ],
    );
  }
}


// ─────────────────────────────────────────────────────────────────────────────
// showPuzzleCompletionOverlay: entry point
// ─────────────────────────────────────────────────────────────────────────────

/// 完成演出を発火。await でユーザーが「見守る」タップまで待てる。
/// caller は BUG-65 遵守で await 後に Future.delayed(300ms) を挟んでから
/// SceneSelectionPage 遷移等の副作用を発火する想定。
Future<void> showPuzzleCompletionOverlay(
  BuildContext context, {
  required String sceneName,
  required int rewardExp,
  required int rewardDiamonds,
  required bool hasNextScene,
  String? nextSceneName,
}) async {
  // 【2026-07-08 hotfix】piece overlay (task/quest) と同構造の null crash 経路。
  // caller (PuzzlePieceListener._handleSceneCompletion) の State.context は
  // MaterialApp.router.builder 内 = go_router の Router/Navigator の祖先で、
  // `Navigator.of(context, rootNavigator: true)` が null crash する。
  // rootNavigatorKey.currentContext (Navigator 内側) を直接使う。
  // 詳細は puzzle_piece_overlay_modal.dart の同経路コメント参照。
  final navContext = rootNavigatorKey.currentContext ?? context;
  await showGeneralDialog<void>(
    context: navContext,
    // navContext は既に Navigator 内側 = rootNavigator 走査は不要。
    useRootNavigator: false,
    barrierDismissible: false,
    barrierColor: Colors.black.withValues(alpha: 0.60),
    transitionDuration: const Duration(milliseconds: 150),
    pageBuilder: (_, __, ___) => PuzzleCompletionModal(
      sceneName: sceneName,
      rewardExp: rewardExp,
      rewardDiamonds: rewardDiamonds,
      hasNextScene: hasNextScene,
      nextSceneName: nextSceneName,
    ),
  );
}
