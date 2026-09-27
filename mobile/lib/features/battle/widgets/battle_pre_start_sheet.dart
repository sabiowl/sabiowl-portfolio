import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../gamification/providers/gamification_provider.dart';
import '../models/enemy.dart';
import '../models/recovery_potion.dart';

/// 【FEAT-298】戦闘開始前の BottomSheet。
///
/// 用途: ギルド画面でボス選択 → 出陣前に **回復薬の使用数（0〜3）** を設定。
/// 所持数を超えるボタンは disabled、所持 0 個のときは「0」のみ選択可能。
///
/// 戻り値（`Navigator.pop` で渡す値）:
///   - `null`: ユーザーがキャンセル（戻るボタン / 背景タップ） → caller は startBattle しない
///   - `int (0-3)`: 使用予定数 → caller は `setPendingPotionsToUse(n)` + ホーム遷移
///
/// **重要（FEAT-298 Pre-mortem #4）**: 本シートは結果を返すのみ。Navigator.pop の
/// 後で caller 側が分岐する設計（CLAUDE.md「dialog から navigation する時は caller
/// が showDialog の結果で分岐する」BUG-65 標準パターン適用）。
///
/// 用法:
/// ```dart
/// final result = await showModalBottomSheet<int?>(
///   context: context,
///   isScrollControlled: true,
///   backgroundColor: Colors.transparent,
///   builder: (_) => BattlePreStartSheet(enemyName: enemy.name),
/// );
/// if (!context.mounted) return;
/// if (result == null) return; // キャンセル
/// // 300ms 待ってから navigation（BUG-65 標準パターン）
/// await Future.delayed(const Duration(milliseconds: 300));
/// if (!context.mounted) return;
/// ref.read(battleSessionProvider.notifier).setPendingPotionsToUse(result);
/// // ホーム遷移など
/// ```
class BattlePreStartSheet extends ConsumerStatefulWidget {
  const BattlePreStartSheet({super.key, required this.enemyName, this.enemy});

  final String enemyName;

  /// 【FEAT-302】optional: 弱点 / 耐性警告のためのフルメタデータ。
  /// 渡された場合、`hasPhysicalResistance` / `hasMagicalResistance` / `hasWeakness` を
  /// 見てサビ口調の警告セクションを上部に表示する。null なら警告なし（旧挙動互換）。
  final EnemyMaster? enemy;

  @override
  ConsumerState<BattlePreStartSheet> createState() =>
      _BattlePreStartSheetState();
}

class _BattlePreStartSheetState extends ConsumerState<BattlePreStartSheet> {
  int _selectedPotions     = 0;
  // 【FEAT-376】上位回復薬・攻撃の薬の選択数
  int _selectedPotionsPlus = 0;
  int _selectedAttackPotions = 0;
  // 【FEAT-432】防御の薬の選択数、攻撃の薬と完全対称
  int _selectedDefensePotions = 0;

  /// shop items から指定 itemId の owned_quantity を抽出する。
  int _resolveOwnedQtyById(AsyncValue<ShopState> shopAsync, String itemId) {
    return shopAsync.maybeWhen(
      data: (shop) {
        for (final item in shop.items) {
          if (item.id == itemId) return item.ownedQuantity;
        }
        return 0;
      },
      orElse: () => 0,
    );
  }

  /// shop items から recovery_potion の owned_quantity を抽出する。
  int _resolveOwnedQty(AsyncValue<ShopState> shopAsync) {
    return _resolveOwnedQtyById(shopAsync, RecoveryPotion.itemId);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final shopAsync = ref.watch(shopNotifierProvider);
    final ownedQty      = _resolveOwnedQty(shopAsync);
    // 【FEAT-376】新ポーション所持数
    final ownedQtyPlus   = _resolveOwnedQtyById(shopAsync, RecoveryPotionPlus.itemId);
    final ownedQtyAttack = _resolveOwnedQtyById(shopAsync, AttackPotion.itemId);
    // 【FEAT-432】防御の薬所持数、攻撃の薬と完全対称
    final ownedQtyDefense = _resolveOwnedQtyById(shopAsync, DefensePotion.itemId);
    final maxSelectable      = ownedQty.clamp(0, RecoveryPotion.maxPerBattle);
    final maxSelectablePlus  = ownedQtyPlus.clamp(0, RecoveryPotionPlus.maxPerBattle);
    final maxSelectableAttack= ownedQtyAttack.clamp(0, AttackPotion.maxPerBattle);
    final maxSelectableDefense = ownedQtyDefense.clamp(0, DefensePotion.maxPerBattle);
    if (_selectedPotions > maxSelectable) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _selectedPotions = maxSelectable);
      });
    }
    if (_selectedPotionsPlus > maxSelectablePlus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _selectedPotionsPlus = maxSelectablePlus);
      });
    }
    if (_selectedAttackPotions > maxSelectableAttack) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _selectedAttackPotions = maxSelectableAttack);
      });
    }
    if (_selectedDefensePotions > maxSelectableDefense) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _selectedDefensePotions = maxSelectableDefense);
      });
    }

    // 【BUG-149 (2026-08-26)】本文セクションはスクロール領域に入れる。
    //
    // 所持状況で advisory + 最大 4 種のポーションまで伸びるので、端末の高さや
    // 文字サイズ設定によっては画面を超える。実測 (4 種所持 + advisory、
    // 下部セーフエリア 34px): 375x667 で標準 80px / 文字 1.3 倍で 178px はみ出す。
    // 下の `Flexible` + `SingleChildScrollView` がこれを受ける。
    final sections = <Widget>[
      // 【FEAT-302 → FEAT-439 (2026-06-17)】弱点 / 耐性のサビ口調警告。
      // 「強さ未知数」体験維持のため、未勝利時は非表示、勝利後に解放。
      // ギルド画面の chip 表示と一貫したルール (PM 判断)。
      if (widget.enemy != null &&
          widget.enemy!.defeated &&
          _hasAnyResistanceOrWeakness(widget.enemy!))
        _ResistanceAdvisory(enemy: widget.enemy!),
      const SizedBox(height: 4),

      // 回復薬選択ラベル
      Row(
        children: [
          const Text(
            RecoveryPotion.emoji,
            style: TextStyle(fontSize: 20),
          ),
          const SizedBox(width: 6),
          // 【BUG-149】ラベルは Flexible + ellipsis。裸の Text + Spacer だと
          // 「防御の薬 (1 ターン被ダメージ ÷1.5)」のような長いラベルが横に溢れる
          // (実測: 幅 390 で 46px、文字 1.3 倍で 163px)。
          Flexible(
            child: Text(
              l10n.battlePreStartPotionPrompt,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          const Spacer(),
          Text(
            l10n.battlePreStartOwnedCount(ownedQty),
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
      ),
      const SizedBox(height: 12),

      // 0〜3 の選択ボタン群
      Row(
        children: List.generate(RecoveryPotion.maxPerBattle + 1, (n) {
          final enabled = n <= maxSelectable;
          final selected = _selectedPotions == n && enabled;
          return Expanded(
            child: Padding(
              padding: EdgeInsets.only(
                right: n < RecoveryPotion.maxPerBattle ? 8 : 0,
              ),
              child: _PotionCountButton(
                count: n,
                selected: selected,
                enabled: enabled,
                onTap: enabled
                    ? () {
                        HapticFeedback.selectionClick();
                        setState(() => _selectedPotions = n);
                      }
                    : null,
              ),
            ),
          );
        }),
      ),
      const SizedBox(height: 8),

      // ヘルパーテキスト（HP 30% 以下で自動使用）
      Text(
        l10n.battlePreStartAutoPotionHint,
        style: const TextStyle(color: Colors.white38, fontSize: 11),
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 16),

      // 【FEAT-376】上位回復薬 (HP 全回復) セクション
      if (maxSelectablePlus > 0 || ownedQtyPlus > 0) ...[
        Row(
          children: [
            const Text(RecoveryPotionPlus.emoji,
                style: TextStyle(fontSize: 20)),
            const SizedBox(width: 6),
            // 【BUG-149】ラベルは Flexible + ellipsis (上と同じ理由)。
            Flexible(
              child: Text(
                l10n.battlePreStartPotionPlusLabel,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            const Spacer(),
            Text(l10n.battlePreStartOwnedCount(ownedQtyPlus),
                style: const TextStyle(
                    color: Colors.white54, fontSize: 12)),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: List.generate(
            RecoveryPotionPlus.maxPerBattle + 1,
            (n) {
              final enabled = n <= maxSelectablePlus;
              return Expanded(
                child: Padding(
                  padding: EdgeInsets.only(
                    right: n < RecoveryPotionPlus.maxPerBattle ? 8 : 0,
                  ),
                  child: _PotionCountButton(
                    count: n,
                    selected: _selectedPotionsPlus == n && enabled,
                    enabled: enabled,
                    onTap: enabled
                        ? () {
                            HapticFeedback.selectionClick();
                            setState(
                                () => _selectedPotionsPlus = n);
                          }
                        : null,
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 12),
      ],

      // 【FEAT-376】攻撃の薬セクション
      if (maxSelectableAttack > 0 || ownedQtyAttack > 0) ...[
        Row(
          children: [
            const Text(AttackPotion.emoji,
                style: TextStyle(fontSize: 20)),
            const SizedBox(width: 6),
            // 【BUG-149】ラベルは Flexible + ellipsis (上と同じ理由)。
            Flexible(
              child: Text(
                l10n.battlePreStartAttackPotionLabel,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            const Spacer(),
            Text(l10n.battlePreStartOwnedCount(ownedQtyAttack),
                style: const TextStyle(
                    color: Colors.white54, fontSize: 12)),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: List.generate(
            AttackPotion.maxPerBattle + 1,
            (n) {
              final enabled = n <= maxSelectableAttack;
              return Expanded(
                child: Padding(
                  padding: EdgeInsets.only(
                    right: n < AttackPotion.maxPerBattle ? 8 : 0,
                  ),
                  child: _PotionCountButton(
                    count: n,
                    selected: _selectedAttackPotions == n && enabled,
                    enabled: enabled,
                    onTap: enabled
                        ? () {
                            HapticFeedback.selectionClick();
                            setState(
                                () => _selectedAttackPotions = n);
                          }
                        : null,
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
      ],

      // 【FEAT-432】防御の薬セクション、攻撃の薬と完全対称
      if (maxSelectableDefense > 0 || ownedQtyDefense > 0) ...[
        Row(
          children: [
            const Text(DefensePotion.emoji,
                style: TextStyle(fontSize: 20)),
            const SizedBox(width: 6),
            // 【BUG-149】ラベルは Flexible + ellipsis (上と同じ理由)。
            Flexible(
              child: Text(
                l10n.battlePreStartDefensePotionLabel,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            const Spacer(),
            Text(l10n.battlePreStartOwnedCount(ownedQtyDefense),
                style: const TextStyle(
                    color: Colors.white54, fontSize: 12)),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: List.generate(
            DefensePotion.maxPerBattle + 1,
            (n) {
              final enabled = n <= maxSelectableDefense;
              return Expanded(
                child: Padding(
                  padding: EdgeInsets.only(
                    right: n < DefensePotion.maxPerBattle ? 8 : 0,
                  ),
                  child: _PotionCountButton(
                    count: n,
                    selected: _selectedDefensePotions == n && enabled,
                    enabled: enabled,
                    onTap: enabled
                        ? () {
                            HapticFeedback.selectionClick();
                            setState(
                                () => _selectedDefensePotions = n);
                          }
                        : null,
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
      ],
    ];

    return SafeArea(
      top: false,
      // 【BUG-149 (2026-08-26)】画面の 90% を上限にする。
      //
      // `isScrollControlled: true` で開いているので、この上限が無いと
      // **内容の高さがそのままシートの高さになる**。上限を切って中身を
      // スクロールさせることで、端末 / 文字サイズによらず
      // 「出陣」ボタンが必ず画面内に残る。
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.9,
        ),
        child: Container(
        decoration: const BoxDecoration(
          color:        AppTheme.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        // 🔴 【BUG-149】ここに `MediaQuery.padding.bottom` を足さないこと。
        //
        // 直上の `SafeArea(top: false)` が既に下部インセットを入れている。
        // この `padding:` を評価している `context` は **SafeArea より上**なので
        // `padding.bottom` は生の値 (ホームインジケータ端末で 34px) が取れてしまい、
        // **同じ余白を 2 回数えていた**。実測でシートが 678.6 → 746.6 (= +34 × 2) に
        // 膨らみ、これが実機報告「BOTTOM OVERFLOWED BY 32 PIXELS」の主因だった。
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ドラッグハンドル
            Center(
              child: Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color:        Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),

            // タイトル
            Text(
              l10n.battlePreStartTitle(widget.enemyName),
              style: const TextStyle(
                color:      Colors.white,
                fontSize:   16,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),

            // 【BUG-149】本文だけがスクロールし、下の 2 ボタンは常に見えている。
            // `Flexible` にすることで「入るなら伸びない / 入らないならスクロール」
            // になる (`Expanded` だと内容が短くても常に最大まで伸びてしまう)。
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: sections,
                ),
              ),
            ),

            const SizedBox(height: 12),

            // 出陣ボタン (Row 内ではなく Column 内なので minimumSize: (∞, 48) で問題なし)
            ElevatedButton.icon(
              onPressed: () {
                HapticFeedback.mediumImpact();
                // 【FEAT-376 + FEAT-432】4 種類のポーション数を List で返す
                Navigator.of(context, rootNavigator: true).pop(
                  <int>[_selectedPotions, _selectedPotionsPlus, _selectedAttackPotions, _selectedDefensePotions],
                );
              },
              icon:  const Icon(Icons.flash_on, size: 18),
              label: Text(l10n.battlePreStartJoinButton),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
            const SizedBox(height: 8),

            // キャンセル
            TextButton(
              onPressed: () {
                // キャンセル: null を返す → caller 側は何もしない
                Navigator.of(context, rootNavigator: true).pop();
              },
              child: Text(
                l10n.battlePreStartCancelButton,
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }
}

/// 【FEAT-302】enemy が弱点 or 耐性を持つか。Advisory 表示判定に使う。
bool _hasAnyResistanceOrWeakness(EnemyMaster e) =>
    e.hasPhysicalResistance || e.hasMagicalResistance || e.hasWeakness;

/// 【FEAT-302】弱点 / 耐性のサビ口調 advisory。
///
/// 耐性 / 弱点を持つ enemy（armored_knight / ice_witch 等）に対して、
/// 「戦い方のヒント」を紳士的トーンで提示する。warrior で armored_knight 等の
/// 相性悪い組み合わせを未然に気づかせる UX（ユーザー側で別ジョブを選び直すか
/// 判断する余地を与える、戦略性の入口）。
class _ResistanceAdvisory extends StatelessWidget {
  const _ResistanceAdvisory({required this.enemy});

  final EnemyMaster enemy;

  String _composeMessage(AppLocalizations l10n) {
    final lines = <String>[];
    if (enemy.hasPhysicalResistance) {
      lines.add(l10n.battlePreStartPhysicalResistanceSabi_message);
    }
    if (enemy.hasMagicalResistance) {
      lines.add(l10n.battlePreStartMagicResistanceSabi_message);
    }
    if (enemy.hasWeakness) {
      lines.add(l10n.battlePreStartWeaknessSabi_message(enemy.weakUltCost ?? 0));
    }
    return lines.join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.10),
        border: Border.all(
          color: Colors.amber.withValues(alpha: 0.45),
          width: 0.8,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded,
              color: Colors.amber, size: 16),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${_composeMessage(l10n)} 🪶',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 0〜3 の各ボタン（rounded square）。selected/enabled で色変化。
class _PotionCountButton extends StatelessWidget {
  const _PotionCountButton({
    required this.count,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final int count;
  final bool selected;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final bg = !enabled
        ? AppTheme.card.withValues(alpha: 0.4)
        : selected
            ? AppTheme.primary
            : AppTheme.card;
    final fg = !enabled
        ? Colors.white24
        : selected
            ? Colors.white
            : Colors.white70;
    final border = !enabled
        ? Colors.white12
        : selected
            ? AppTheme.primary
            : Colors.white.withValues(alpha: 0.20);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: 48,
          decoration: BoxDecoration(
            color: bg,
            border: Border.all(color: border, width: 1.5),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Center(
            child: Text(
              '$count',
              style: TextStyle(
                color: fg,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
