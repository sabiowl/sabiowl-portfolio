import 'package:flutter/material.dart';
import 'package:flutter/services.dart';  // 【gameplay_review 20260803 要素 A-2】HapticFeedback
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../battle/constants/battle_constants.dart';
import '../../../battle/providers/battle_provider.dart';
import '../../../battle/services/ambient_auto_battle_orchestrator.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 【gameplay_review 20260803 §2-1】Ambient Auto Battle の WorldFrame 内 UI 一式
// ─────────────────────────────────────────────────────────────────────────────
//
// WorldFrameSection の build から切り出した理由は 2 つある:
//
//  1. **契約テストを書けるようにするため**。旧構造では countdown overlay が
//     WorldFrameSection.build の内側にあり、テストするには puzzle / player /
//     背景アセットまで含めて画面ごと build する必要があった。結果として
//     ambient 系のテスト 7 本はすべて orchestrator 単体で、**UI の gate を
//     1 本も通っていなかった**。「countdown は回るのに中止ボタンが出ない」
//     (§2-1) はまさにその隙間で起きた。
//  2. ここは「オートバトルの状態を人に見せる」という単一の関心であり、
//     世界額縁の描画とは独立して読める。
//
// 依存は `ambientAutoBattleProvider` / `battleAvailabilityProvider` /
// `ambientAutoBattleEnabledProvider` の 3 つだけで、すべて override 可能。

/// countdown 進行中に額縁を覆う overlay。
///
/// **表示条件は `AmbientBattleState.countdownSecondsLeft != null` のみ**。
///
/// 【gameplay_review 20260803 §2-1】旧実装はここで `ambientAutoBattleEnabledProvider`
/// も見ていた。しかし同 provider に SharedPreferences の値を流し込むのは
/// `GuildPage.initState` の 1 箇所だけで、ShellRoute 配下の GuildPage は
/// **ギルドタブを開くまで build されない**。その結果:
///
///   起動 → ホーム着地 → (この session ではまだギルド未訪問)
///     → オーケストレータ (prefs 直読み) は countdown を回す
///     → overlay は provider=false で消えている
///     → **中止する手段が画面に存在しないまま自動出陣が始まる**
///
/// countdown が回っている時点でオーケストレータが `isEnabled(prefs)` を確認済なので、
/// ここでの二重チェックは冗長でしかない。真実値を 1 つに絞る。
class AmbientBattleCountdownOverlay extends ConsumerWidget {
  const AmbientBattleCountdownOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final countdown = ref.watch(ambientAutoBattleProvider).countdownSecondsLeft;
    if (countdown == null) {
      return const IgnorePointer(child: SizedBox.shrink());
    }
    return _AmbientBattleCountdown(
      secondsLeft: countdown,
      onSkip: () =>
          ref.read(ambientAutoBattleProvider.notifier).skipCountdown(),
      onCancel: () =>
          ref.read(ambientAutoBattleProvider.notifier).cancelCountdown(),
    );
  }
}

/// 額縁下部に出る 1 行のステータス表示。状況に応じて 4 状態を出し分ける。
///
///   queue 実行中           → 「⚔️ 出陣中 — 残り N 戦」 (§2-2 d)
///   countdown 中           → 非表示 (overlay 側が主役)
///   日次上限到達           → 「本日の出陣は充分」 (FEAT-513 hotfix #7)
///   charges 不足           → 「あと N 回」 (auto ON/OFF で文面のみ分岐、§2-3)
///   出陣可能               → 非表示
class AmbientBattleStatusIndicator extends ConsumerWidget {
  const AmbientBattleStatusIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ambientState = ref.watch(ambientAutoBattleProvider);

    // 【§2-2 d】queue 実行中は「残り N 戦」の subtle 表示。FEAT-513 S7 が指定して
    // いた subtle indicator の実体で、per-battle モーダルを抑止した分の情報を
    // ここで静かに補う。
    if (ambientState.isRunning) {
      final left = ambientState.remainingBattles;
      if (left <= 0) return const SizedBox.shrink();
      return _AmbientQueueProgressIndicator(remaining: left);
    }
    if (ambientState.countdownSecondsLeft != null) {
      return const SizedBox.shrink();
    }

    final avail = ref.watch(battleAvailabilityProvider);
    // daily limit 到達 = 出陣不可 → Sabi 口調で「休息」を伝達。
    // (charges の状態と独立、charges 満タン + daily limit 到達 でも同じ表示)
    if (avail.dailyBattleLimitReached) {
      return const _AmbientDailyLimitIndicator();
    }
    if (avail.canBattle) return const SizedBox.shrink();

    // 【§2-3】旧実装はここも `autoEnabled` で gate していたため、**既定
    // (オートバトル OFF) のユーザーにはホームのどこにも charges 進捗が出ない**
    // 状態だった (7/29 に入れた timeline の `⚔️ N/3` は重複解消で撤去済、
    // BottomNav バッジは charges >= 3 でしか出ない)。gate を外し、文面だけを
    // オート ON/OFF で分岐する。表示は 1 箇所のまま (single source of truth を
    // 維持) で、OFF のユーザーにも「あと 1 つ」が届く。
    final remaining = (BattleConstants.chargesPerBattle - avail.charges)
        .clamp(0, BattleConstants.chargesPerBattle);
    return _AmbientBattleIndicator(
      remaining: remaining,
      autoEnabled: ref.watch(ambientAutoBattleEnabledProvider),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 【FEAT-513】_AmbientBattleIndicator — オートバトル待機インジケーター
// ─────────────────────────────────────────────────────────────────────────────

/// WorldFrameSection の下部に表示するサビ口調の控えめなインジケーター。
///
/// チャージ不足 (charges < 3) かつバトル未実行時に表示する。
///
/// 【gameplay_review 20260803 §2-3】オートバトル ON/OFF によらず表示し、文面のみ
/// 分岐する。OFF のユーザーにとっては「あと 1 つ達成する理由」を作る唯一の導線である。
///
/// 【gameplay_review 20260807 §2-4 で訂正】ここには当初もう 1 つ
/// 「**オートバトルという機能の存在を知る手がかり**にもなる」と書いていたが、
/// **OFF 時の文面 `habitWorldAmbientIndicatorChargingManual`
/// (「あと {n} 回の達成で、出陣できますよ 🪶」) はオートバトルに一言も触れていない**。
/// docstring だけが果たしていない役割を主張している状態だったので、その一文を落とした。
///
/// **文面側を変えて辻褄を合わせる道は採らない。** 機能の宣伝をインジケーターに載せるのは、
/// サビの聖域性 (CLAUDE.md「静かな聖域」) に対して割に合わない。
/// 導線を増やしたいなら、トグルの置き場所 (現在はギルド画面の 12px バー 1 箇所) を
/// 見直すのが筋で、それは別 FEAT の判断。
class _AmbientBattleIndicator extends StatelessWidget {
  const _AmbientBattleIndicator({
    required this.remaining,
    required this.autoEnabled,
  });
  final int remaining;
  final bool autoEnabled;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 2),
      child: Text(
        autoEnabled
            ? l10n.habitWorldAmbientIndicatorCharging(remaining)
            : l10n.habitWorldAmbientIndicatorChargingManual(remaining),
        textAlign: TextAlign.center,
        style: TextStyle(
          color: AppTheme.primary.withValues(alpha: 0.75),
          fontSize: 11,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 【gameplay_review 20260803 §2-2 d】_AmbientQueueProgressIndicator
// ─────────────────────────────────────────────────────────────────────────────

/// ambient queue 実行中に frame 下部へ出す「残り N 戦」の subtle 表示。
///
/// FEAT-513 Pre-mortem S7 が指定していた subtle indicator の実体。1 戦ごとの
/// ブロッキングモーダルを抑止した分、「まだ続く」ことだけを静かに伝える。
class _AmbientQueueProgressIndicator extends StatelessWidget {
  const _AmbientQueueProgressIndicator({required this.remaining});
  final int remaining;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 2),
      child: Text(
        AppLocalizations.of(context)!.habitWorldAmbientQueueProgress(remaining),
        textAlign: TextAlign.center,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.55),
          fontSize: 11,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 【FEAT-513 v1.1 hotfix 2026-07-31 #7】_AmbientDailyLimitIndicator
// ─────────────────────────────────────────────────────────────────────────────

/// daily battle limit (10 + bonus) 到達時に「あと N 回で始まりますよ」の代わりに
/// 表示する Sabi 口調 message。
///
/// 目的:
///   - user が「タスク積んでも auto battle が始まらない」不安を「今日は上限」と理解
///   - Sabi 哲学 「羽を休めることも、長く飛び続けるためには必要な工程です」
///     (BattleAvailability.description) と一貫した休息肯定トーン
///   - 日跨ぎで daily count reset → dailyBattleLimitReached=false → 通常 indicator に
///     自動復帰 (「元に戻す」原則、明示的な dismiss 不要)
class _AmbientDailyLimitIndicator extends StatelessWidget {
  const _AmbientDailyLimitIndicator();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 2),
      child: Text(
        AppLocalizations.of(context)!.habitWorldAmbientDailyLimitSabi_message,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.55),
          fontSize: 11,
          fontWeight: FontWeight.w500,
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 【FEAT-513 v1.1 hotfix 2026-07-31】_AmbientBattleCountdown — 10 秒 countdown UI
// ─────────────────────────────────────────────────────────────────────────────

/// バトル開始条件が満たされた時に WorldFrame **内** に overlay 表示される countdown。
///
/// 【FEAT-513 v1.1 hotfix 2026-07-31】旧: WorldFrame の下 (Column child bottom) に
/// 表示 → user 期待「countdown はワールドフレーム内で表示」と乖離。新: Positioned.fill
/// で frame を dark backdrop で覆い、中央に大きい数字 + Sabi 口調 hint を表示。
///
/// - Dark backdrop (alpha 0.65) で下の景色演出を軽く暗くし countdown を強調
/// - 中央: 大きい数字 (56pt tabularFigures) + Sabi 口調 hint
/// - 下部: 中止 / 今すぐ開始 (BUG-138 準拠: 左 = Cancel / 右 = Action primary)
/// - 残り 3 / 2 / 1 秒で `selectionClick` (要素 A-2)
class _AmbientBattleCountdown extends StatefulWidget {
  const _AmbientBattleCountdown({
    required this.secondsLeft,
    required this.onSkip,
    required this.onCancel,
  });

  final int secondsLeft;
  final VoidCallback onSkip;
  final VoidCallback onCancel;

  @override
  State<_AmbientBattleCountdown> createState() =>
      _AmbientBattleCountdownState();
}

class _AmbientBattleCountdownState extends State<_AmbientBattleCountdown> {
  /// 【gameplay_review 20260803 要素 A-2】残り 3 / 2 / 1 秒で軽い触覚を 1 回ずつ。
  ///
  /// countdown の数字は 56pt で出るが、画面を見ていないユーザーには何も伝わらない。
  /// 触覚を足すと「何か始まる」に気づけるので、**中止する機会が実質的に増える**
  /// (§2-1 の緩和にもなる)。強い振動は不要なので `selectionClick` 1 回のみ。
  static const _hapticThreshold = 3;

  @override
  void didUpdateWidget(covariant _AmbientBattleCountdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    final s = widget.secondsLeft;
    if (s != oldWidget.secondsLeft && s > 0 && s <= _hapticThreshold) {
      HapticFeedback.selectionClick();
    }
  }

  @override
  Widget build(BuildContext context) {
    final secondsLeft = widget.secondsLeft;
    final onSkip = widget.onSkip;
    final onCancel = widget.onCancel;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.65),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$secondsLeft',
                style: TextStyle(
                  color: AppTheme.primary,
                  fontSize: 56,
                  fontWeight: FontWeight.w800,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  height: 1.0,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                AppLocalizations.of(context)!.habitWorldAmbientCountdownHintSabi_message,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 【BUG-138】左 = Cancel 系 (auto battle 中止、charges 保持)
                  TextButton(
                    onPressed: onCancel,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(80, 36),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      backgroundColor: Colors.black.withValues(alpha: 0.4),
                    ),
                    child: Text(
                      AppLocalizations.of(context)!.habitWorldAmbientCountdownCancelButton,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.85),
                        fontSize: 13,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 【BUG-138】右 = Action 系 (即開始、primary color)
                  ElevatedButton(
                    onPressed: onSkip,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primary,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(120, 36),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                    ),
                    child: Text(
                      AppLocalizations.of(context)!.habitWorldAmbientCountdownStartButton,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// 【FEAT-487 (2026-07-08)】旧 `_WorldFramePlaceholder` は
// `world_frame_container.dart` に `WorldFramePlaceholder` (public) として移設済。
// 本ファイルでは `import 'world_frame_container.dart'` 経由で参照する。
