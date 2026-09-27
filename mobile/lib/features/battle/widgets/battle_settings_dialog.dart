import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../providers/battle_provider.dart';
import 'battle_toggle_switch.dart';

/// 【FEAT-528 (2026-08-22)】バトル設定モーダル（オートバトル + バトルスピード）。
///
/// ## なぜ要るのか —— Skip が一方通行になっていた
///
/// `⏭` は headless 実行ではなく **`speedMultiplier = 50.0`** で、
/// 書き込み UI は**バトル画面の AppBar だけ**だった。Skip だと戦闘が 1-2 秒で
/// 終わるので、**チップをタップする実用的な窓が無い** —— 入れるが出られない。
/// 実機報告: 「一度 Skip にすると次も Skip となり、次戦でバトルスピードを
/// 変更する前に終了し、変更できません」。本モーダルがその出口である。
///
/// ## 🔴 出口より「気付けること」のほうが本体
///
/// モーダルは出口を作るが、**そもそも Skip のままだと気付けていない**。
/// だから `AutoBattleBar` 側に現在の速度バッジを出している（FEAT-528 決定事項 2）。
/// 本モーダルはその補完で、**開かなくても状態が見える**ほうが効いている。
///
/// ## NPC の声を使わない
///
/// サビはギルド画面に出ず、リリアは受付の業務台詞を話す。
/// **設定モーダルは UI chrome** なので、`PartyEditDialog` と同じく中立の UI コピーで書く
/// （FEAT-528 決定事項 6）。
///
/// ## CLAUDE.md 遵守
///
/// - **FEAT-215**: 閉じるのは caller が渡す [onClose] だけ。内側で `Navigator.pop`
///   しない（ShellRoute 配下で外側 context を pop するとシェルごと落ちる）
/// - **BUG-65**: モーダル内で navigation を一切しない（閉じるだけ）
/// - **モーダル手動 close 原則**: X ボタンを必ず置き、auto-dismiss しない
class BattleSettingsDialog extends ConsumerWidget {
  const BattleSettingsDialog({super.key, required this.onClose});

  /// モーダルを閉じる callback。caller（guild_page）が `dialogContext` を束ねて渡す。
  final VoidCallback onClose;

  /// バトルスピードの選択肢。`battle_page` の `_SpeedChip` と同じ 5 択・同じ並び。
  static const List<({double value, String label})> speedOptions = [
    (value: 1.0, label: '1x'),
    (value: 1.5, label: '1.5x'),
    (value: 2.0, label: '2x'),
    (value: 3.0, label: '3x'),
    (value: 50.0, label: '⏭'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final media = MediaQuery.of(context);
    final isAuto = ref.watch(ambientAutoBattleEnabledProvider);
    final speed = ref.watch(battleSpeedPreferenceProvider);

    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: media.size.width - 48,
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
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── タイトル + X ─────────────────────────────────────────
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.battleSettingsTitle,
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
                    tooltip: l10n.battleSettingsCloseLabel,
                    onPressed: onClose,
                  ),
                ],
              ),
              const Divider(color: Colors.white12, height: 16),

              // ── オートバトル ─────────────────────────────────────────
              InkWell(
                onTap: () => setAmbientAutoBattleEnabled(ref, !isAuto),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              l10n.guildAutoBattleLabel,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: isAuto
                                    ? AppTheme.primary
                                    : Colors.white.withValues(alpha: 0.8),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              l10n.guildAutoBattleSubtitle,
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.white.withValues(alpha: 0.4),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      BattleToggleSwitch(value: isAuto),
                    ],
                  ),
                ),
              ),
              const Divider(color: Colors.white12, height: 16),

              // ── バトルスピード ────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  l10n.battleSettingsSpeedLabel,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.white.withValues(alpha: 0.8),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  for (final option in speedOptions)
                    Expanded(
                      child: _SpeedOption(
                        label: option.label,
                        isSelected: (speed - option.value).abs() < 0.01,
                        onTap: () => _selectSpeed(ref, option.value),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              // 🔴 Pre-mortem #5: ⏭ は他の 4 つと違い「倍速」ではなく**体験の種類が
              // 変わる**。説明が無いと「一番速いやつ」と誤解され、知らずに触った
              // ユーザーの戦闘が飛ぶ。
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  l10n.battleSettingsSkipDescription,
                  style: TextStyle(
                    fontSize: 10,
                    height: 1.4,
                    color: Colors.white.withValues(alpha: 0.4),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 速度を変更する。
  ///
  /// 🔴 **走っているバトルにも伝える。** `AtbController.speedMultiplier` は
  /// `setSpeedMultiplier` 経由でしか変わらないので、これが無いと
  /// **モーダルを他画面に置いた瞬間に「変えたのに速さが変わらない」が発現する**
  /// （FEAT-528 Pre-mortem #2）。ギルド画面からは戦闘中に開けないので今は
  /// 効かないが、1 行で将来の穴が塞がる。
  void _selectSpeed(WidgetRef ref, double value) {
    ref.read(battleSpeedPreferenceProvider.notifier).setSpeed(value);
    if (ref.read(battleSessionProvider).state != null) {
      ref.read(battleSessionProvider.notifier).setSpeedMultiplier(value);
    }
  }
}

/// モーダル内の速度チップ 1 つ。見た目は `battle_page` の `_SpeedChip` に揃える。
class _SpeedOption extends StatelessWidget {
  const _SpeedOption({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 3),
        padding: const EdgeInsets.symmetric(vertical: 9),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.primary
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: isSelected
                ? Colors.white
                : Colors.white.withValues(alpha: 0.5),
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}
