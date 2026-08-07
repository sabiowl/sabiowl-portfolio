import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../constants/battle_constants.dart';
import '../providers/battle_provider.dart';

/// 【FEAT-295 Phase 1c】ホーム画面常駐の折りたたみ式バトルウィジェット。
///
/// 設計ノート §3.3:
///   - 折りたたみ時 56px、展開時 200px、`AnimatedSize` で柔らかい遷移
///   - 状態 3 種: waiting / ready / running / finished
///   - SharedPreferences に `battle_widget_collapsed: bool` 保存（再起動後復元）
///
/// **Pre-mortem #3** 対応: 折りたたみで縦長が +200px 以内に抑制。
class BattleWidget extends ConsumerStatefulWidget {
  const BattleWidget({super.key});

  @override
  ConsumerState<BattleWidget> createState() => _BattleWidgetState();
}

class _BattleWidgetState extends ConsumerState<BattleWidget> {
  bool _collapsed = false;
  bool _loadedPref = false;

  @override
  void initState() {
    super.initState();
    _loadCollapsedPref();
  }

  Future<void> _loadCollapsedPref() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getBool(BattleConstants.prefsKeyCollapsed) ?? false;
      if (!mounted) return;
      setState(() {
        _collapsed = saved;
        _loadedPref = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadedPref = true);
    }
  }

  Future<void> _toggleCollapsed() async {
    HapticFeedback.selectionClick();
    final newValue = !_collapsed;
    setState(() => _collapsed = newValue);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(BattleConstants.prefsKeyCollapsed, newValue);
    } catch (_) {/* 保存失敗は silent */}
  }

  @override
  Widget build(BuildContext context) {
    if (!_loadedPref) {
      return const SizedBox(height: BattleConstants.widgetCollapsedHeight);
    }
    final battleState = ref.watch(battleAvailabilityProvider);

    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      curve:    Curves.easeOutCubic,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color:        AppTheme.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: AppTheme.primary.withValues(alpha: 0.25),
          ),
        ),
        child: _collapsed ? _buildCollapsed(battleState) : _buildExpanded(context, battleState),
      ),
    );
  }

  Widget _buildCollapsed(BattleAvailability state) {
    return SizedBox(
      height: BattleConstants.widgetCollapsedHeight,
      child: InkWell(
        onTap: _toggleCollapsed,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Icon(
                Icons.shield_outlined,
                color: state.canBattle
                    ? AppTheme.primary
                    : Colors.white.withValues(alpha: 0.4),
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  state.label,
                  style: const TextStyle(
                    color:      Colors.white,
                    fontSize:   13,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(
                Icons.expand_more,
                color: Colors.white.withValues(alpha: 0.5),
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildExpanded(BuildContext context, BattleAvailability state) {
    return ConstrainedBox(
      constraints: const BoxConstraints(
        minHeight: BattleConstants.widgetExpandedHeight,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── ヘッダー ──────────────────────────────
            Row(
              children: [
                Icon(
                  Icons.shield_outlined,
                  color: AppTheme.primary,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  AppLocalizations.of(context)!.battleWidgetTitle,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon:        const Icon(Icons.expand_less, color: Colors.white54, size: 20),
                  padding:     EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed:   _toggleCollapsed,
                ),
              ],
            ),
            const SizedBox(height: 8),
            // ── チケットゲージ ──────────────────────────
            Row(
              children: List.generate(
                BattleConstants.chargesPerBattle,
                (i) {
                  final filled = i < state.charges;
                  return Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(
                      filled
                          ? Icons.local_fire_department
                          : Icons.local_fire_department_outlined,
                      color: filled
                          ? Colors.orangeAccent
                          : Colors.white24,
                      size: 18,
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            Text(
              state.description,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.7),
                fontSize: 12,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 12),
            // ── アクションボタン ──────────────────────
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: state.canBattle
                        ? () {
                            HapticFeedback.mediumImpact();
                            context.push(AppRoutes.battle);
                          }
                        : null,
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size(0, 44),
                      backgroundColor: AppTheme.primary,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor:
                          AppTheme.primary.withValues(alpha: 0.18),
                      disabledForegroundColor:
                          Colors.white.withValues(alpha: 0.4),
                    ),
                    icon: const Icon(Icons.flag_outlined, size: 18),
                    label: Text(
                      state.canBattle
                          ? AppLocalizations.of(context)!.battleWidgetReadyButton
                          : AppLocalizations.of(context)!.battleWidgetPrepButton,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
