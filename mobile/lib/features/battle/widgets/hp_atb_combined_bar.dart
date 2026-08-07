import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../models/combatant.dart';

/// 【FEAT-384 (2026-05-29)】HP|ATB 一体型バー (案 Z 採択、1v1 で先行実装)。
///
/// 1 本のバーを左右半分に分割:
///   - 左 50%: HP (緑 → 黄 → 赤、健康度で色変化)
///   - 右 50%: ATB (水色 → 紫、充填度連動)
///
/// gameplay_review 20260528 P2-5 系の「個別 ATB」要望 + ユーザー要望
/// 「ATB 進捗速さをキャラごとに分けたい + 味方は縦 1 列」(FEAT-310 案 Z) の
/// 革新部分 (HP|ATB 一体型) を 1v1 状態で先行実装。
///
/// v1.1 FEAT-310 (パーティ 3+1 化) で本 widget を `ListView.builder` に
/// 渡すだけで縦 1 列 4 体並びに拡張可能 (widget 再利用率 100%)。
///
/// 設計詳細: `doc/design/mockups/feat_310_minibattle_arena_3_1_mock.html`
class HpAtbCombinedBar extends StatefulWidget {
  const HpAtbCombinedBar({
    super.key,
    required this.combatant,
    this.height = 8.0,
    this.compact = false,
    this.showSeparator = true,
    this.showAtb = true,
  });

  /// HP / ATB の参照元。
  final Combatant combatant;

  /// バー高さ (compact = MiniBattleArena 用 / フル = BattlePage 用)。
  final double height;

  /// MiniBattleArena 等の小型コンテキストで使う場合 true。
  final bool compact;

  /// 中央の HP|ATB 区切り線を表示するか (false でフラットな見た目)。
  final bool showSeparator;

  /// 【FEAT-403 (2026-06-01)】ATB ゲージを表示するか。
  /// `false` のとき HP が全幅 (full-width) を占め、ATB / separator は非表示。
  /// 敵側 (ボス) は ATB 進捗を見せる演出価値が薄いため `false` 推奨、
  /// HP ゲージを拡張して「ボスを削っていく実感」を強化する。
  final bool showAtb;

  @override
  State<HpAtbCombinedBar> createState() => _HpAtbCombinedBarState();
}

/// 【FEAT-404 (2026-06-01)】ATB 充填過程を滑らかに補間するための State。
///
/// 旧 StatelessWidget では `combatant.atbGauge` の即値を描画するため、
/// 1.0 達成 → resetGauge(0.0) の同期遷移時に「1.0 状態が一度も描画されない」
/// 「最後まで進まないように見える」現象が発生していた。
///
/// 本 State で AnimationController + Tween を使って前回値からの遷移を 100ms かけて
/// 補間する。1.0 → 0.0 の急激な遷移時も `_anim.value` は「前値 → 1.0 → 0.0」を
/// 連続的に追従し、視覚的には「満タンに達してから減る」と認識される。
/// (MiniAtbGauge 旧実装と同じパターン)
class _HpAtbCombinedBarState extends State<HpAtbCombinedBar>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _atbAnim;
  double _lastAtbValue = 0.0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100), // Backend tick と同じ
    );
    _lastAtbValue = widget.combatant.atbGauge.clamp(0.0, 1.0);
    _atbAnim = Tween<double>(begin: _lastAtbValue, end: _lastAtbValue)
        .animate(_controller);
    _controller.value = 1.0;
  }

  @override
  void didUpdateWidget(HpAtbCombinedBar old) {
    super.didUpdateWidget(old);
    final newAtb = widget.combatant.atbGauge.clamp(0.0, 1.0);
    if ((newAtb - _lastAtbValue).abs() > 0.001) {
      // 現在表示中の補間値を起点に次の目標値へ。アニメ中断時もスムーズ。
      final from = _atbAnim.value;
      _atbAnim = Tween<double>(begin: from, end: newAtb).animate(_controller);
      _controller.forward(from: 0.0);
      _lastAtbValue = newAtb;
    }
  }

  @override
  void dispose() {
    // 【BUG-66 v3 / Pre-mortem #1】dispose 内で setState は呼ばない、Controller dispose のみ
    _controller.dispose();
    super.dispose();
  }

  /// HP 残量に応じた色 (緑 100-50% / 黄 49-25% / 赤 24-0%)。
  Color _hpColor(double hpRatio) {
    if (hpRatio >= 0.5) return const Color(0xFF4CAF50);  // 緑
    if (hpRatio >= 0.25) return const Color(0xFFFFB74D); // 黄
    return const Color(0xFFF44336);                       // 赤
  }

  @override
  Widget build(BuildContext context) {
    final combatant = widget.combatant;
    final height = widget.height;
    final showAtb = widget.showAtb;
    final showSeparator = widget.showSeparator;

    final hpRatio = combatant.maxHp <= 0
        ? 0.0
        : (combatant.currentHp / combatant.maxHp).clamp(0.0, 1.0);
    final hpColor = _hpColor(hpRatio);
    final barRadius = BorderRadius.circular(height / 2);

    return SizedBox(
      height: height,
      child: ClipRRect(
        borderRadius: barRadius,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.15),
              width: 0.5,
            ),
            borderRadius: barRadius,
          ),
          child: Row(
            children: [
              // ── 左: HP (緑 → 黄 → 赤)、showAtb=false なら全幅 ──────
              Expanded(
                child: Stack(
                  children: [
                    // HP 背景 (空状態)
                    Container(color: Colors.white.withValues(alpha: 0.04)),
                    // HP 残量 (左から伸びる)
                    FractionallySizedBox(
                      widthFactor: hpRatio,
                      alignment: Alignment.centerLeft,
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              hpColor.withValues(alpha: 0.9),
                              hpColor,
                            ],
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // ── 中央の区切り線 (showAtb && showSeparator のときのみ) ──
              if (showAtb && showSeparator)
                Container(
                  width: 1,
                  color: Colors.white.withValues(alpha: 0.35),
                ),
              // ── 右半分: ATB (showAtb=true のときのみ、敵側は非表示) ──
              // 【FEAT-404】AnimatedBuilder + Tween で前回値からの補間描画。
              if (showAtb)
                Expanded(
                  child: AnimatedBuilder(
                    animation: _atbAnim,
                    builder: (_, __) {
                      final animAtb = _atbAnim.value.clamp(0.0, 1.0);
                      return Stack(
                        children: [
                          // ATB 背景 (空状態)
                          Container(
                              color: Colors.white.withValues(alpha: 0.04)),
                          // ATB 充填 (左から伸びる、満タンで紫)
                          FractionallySizedBox(
                            widthFactor: animAtb,
                            alignment: Alignment.centerLeft,
                            child: Container(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    const Color(0xFF4FC3F7), // 水色
                                    AppTheme.primary,        // 紫
                                  ],
                                  begin: Alignment.centerLeft,
                                  end:   Alignment.centerRight,
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 【FEAT-384】HP|ATB 一体型バーの凡例ラベル (HP | ATB)。
///
/// 初心者向けに「左 HP / 右 ATB」を明示するためのラベル。
/// MiniBattleArena では 1 度だけ表示 (味方側下部) 推奨。
/// 案 Z 設計の「視認性低下リスクへの配慮」(モック仕様準拠)。
class HpAtbLegend extends StatelessWidget {
  const HpAtbLegend({super.key, this.fontSize = 8});

  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'HP',
            style: TextStyle(
              color: const Color(0xFF4CAF50).withValues(alpha: 0.7),
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            ' | ',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.4),
              fontSize: fontSize,
            ),
          ),
          Text(
            'ATB',
            style: TextStyle(
              color: const Color(0xFF4FC3F7).withValues(alpha: 0.7),
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
