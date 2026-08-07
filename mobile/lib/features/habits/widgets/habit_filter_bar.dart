import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../pages/add_habit_page.dart' show showAddHabitModal;
import '../providers/habits_provider.dart';
import '../../../shared/widgets/sabi_category_chips.dart' show habitCategoryLabel;

/// 習慣リストのセクションヘッダー（フィルターアイコン + 追加ボタン）
class HabitFilterBar extends ConsumerWidget {
  const HabitFilterBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final currentFilter   = ref.watch(habitFilterProvider);
    final currentCategory = ref.watch(habitCategoryFilterProvider);
    final currentType     = ref.watch(habitTypeFilterProvider);
    final isFiltered      = currentFilter != null ||
        currentCategory != null ||
        currentType != null;

    final freqLabel = switch (currentFilter) {
      'daily'   => l10n.habitHomeFilterFreqToday,
      'weekly'  => l10n.habitHomeFilterFreqWeek,
      'monthly' => l10n.habitHomeFilterFreqMonth,
      _         => null,
    };
    // 【BUG-134 (2026-06-17)】タイプ表示ラベル (count / checklist のみ、todo は除外済)。
    final typeLabel = switch (currentType) {
      'count'     => l10n.habitHomeFilterTypeCount,
      'checklist' => l10n.habitHomeFilterTypeChecklist,
      _           => null,
    };
    final parts = [
      if (freqLabel != null) freqLabel,
      if (currentCategory != null) currentCategory,
      if (typeLabel != null) typeLabel,
    ];
    final displayTitle = parts.isEmpty
        ? l10n.habitFilterBarAllHabits
        : l10n.habitFilterBarFilteredHabits(parts.join(' × '));

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
      child: Row(
        children: [
          // ── フィルターボタン（旧：テキスト + 検索アイコン を統合） ───────
          GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              _showFilterModal(
                context,
                ref,
                currentFilter,
                currentCategory,
                currentType,
              );
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: isFiltered
                    ? AppTheme.primary.withValues(alpha: 0.12)
                    : Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: isFiltered
                      ? AppTheme.primary.withValues(alpha: 0.55)
                      : Colors.white.withValues(alpha: 0.18),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    displayTitle,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: isFiltered ? AppTheme.primary : Colors.white,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.keyboard_arrow_down,
                    size: 18,
                    color: isFiltered
                        ? AppTheme.primary
                        : Colors.white.withValues(alpha: 0.45),
                  ),
                ],
              ),
            ),
          ),
          const Spacer(),
          // 追加ボタン（ピル型 — タイムラインと統一）
          GestureDetector(
            onTap: () {
              HapticFeedback.lightImpact();
              showAddHabitModal(context);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                color:        AppTheme.primary.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: AppTheme.primary.withValues(alpha: 0.35),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.add, size: 13, color: AppTheme.primary),
                  const SizedBox(width: 4),
                  Text(
                    l10n.habitFilterBarAddButton,
                    style: const TextStyle(
                      color:      AppTheme.primary,
                      fontSize:   12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showFilterModal(
    BuildContext context,
    WidgetRef ref,
    String? currentFilter,
    String? currentCategory,
    String? currentType,
  ) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.cardBackground,
      isScrollControlled: true, // overflow 対策
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _FilterModal(
        currentFilter: currentFilter,
        currentCategory: currentCategory,
        currentType: currentType,
      ),
    );
  }
}

// ─────────────────────────────────────────────────
// フィルターモーダル
// ─────────────────────────────────────────────────
class _FilterModal extends ConsumerStatefulWidget {
  const _FilterModal({
    required this.currentFilter,
    required this.currentCategory,
    required this.currentType,
  });
  final String? currentFilter;
  final String? currentCategory;
  final String? currentType;

  @override
  ConsumerState<_FilterModal> createState() => _FilterModalState();
}

class _FilterModalState extends ConsumerState<_FilterModal> {
  late String? _selectedFreq;
  late String? _selectedCategory;
  late String? _selectedType;

  // 【FEAT-307】5/23 P0 積み残し解消、'メンタル' → '精神' (migration 0066 真実値)。
  // API 障害時の安全フォールバック用 subset、FEAT-213 11 値 CATEGORY_CHOICES に従う。
  static const _fallbackCategories = ['運動', '学習', '健康', '精神'];

  @override
  void initState() {
    super.initState();
    _selectedFreq     = widget.currentFilter;
    _selectedCategory = widget.currentCategory;
    _selectedType     = widget.currentType;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final categoriesAsync = ref.watch(categoriesProvider);
    final screenHeight    = MediaQuery.of(context).size.height;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: screenHeight * 0.75),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── ドラッグハンドル + 「×」閉じるボタン (2026-06-13 UX 改善) ──
            // 旧: ハンドル単独 (36×4 = 144px²、Material 推奨 48×48 = 2304px² 未満
            //     で「下ろしづらい」ユーザー報告)。
            // 新: ハンドル外周を GestureDetector で囲み、下方向 drag で pop。
            //     ヘッダー右端に明示的な「×」ボタンを追加し、3 経路で閉じられるよう
            //     にする (ハンドル drag / 「×」タップ / 既存背景タップ)。
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              // 下方向 drag を検出して閉じる (フリックで快適に閉じられる)
              onVerticalDragEnd: (details) {
                if (details.primaryVelocity != null &&
                    details.primaryVelocity! > 0) {
                  Navigator.of(context).pop();
                }
              },
              child: SizedBox(
                height: 44,  // タッチターゲット拡大 (Material 推奨 48px 近似)
                child: Stack(
                  children: [
                    // ハンドル本体 (visual)
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    // 「×」閉じるボタン (右上)
                    Positioned(
                      right: 4,
                      top: 4,
                      child: IconButton(
                        icon: Icon(
                          Icons.close,
                          color: Colors.white.withValues(alpha: 0.6),
                          size: 20,
                        ),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 36,
                          minHeight: 36,
                        ),
                        onPressed: () => Navigator.of(context).pop(),
                        tooltip: l10n.habitFilterBarCloseTooltip,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // ── スクロール可能なコンテンツ ────────────────────────
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── グループ1: 頻度フィルター ──────────────────
                    _SectionLabel(l10n.habitFilterBarSectionFreq),
                    _filterTile(null,      l10n.habitFilterBarAllHabits,  Icons.list_alt),
                    _filterTile('daily',   l10n.habitFilterBarFreqDaily,  Icons.today),
                    _filterTile('weekly',  l10n.habitFilterBarFreqWeekly, Icons.date_range),
                    _filterTile('monthly', l10n.habitFilterBarFreqMonthly, Icons.calendar_month),

                    const Divider(
                      color: Colors.white12,
                      height: 24,
                      indent: 16,
                      endIndent: 16,
                    ),

                    // ── グループ2: カテゴリフィルター ──────────────
                    _SectionLabel(l10n.habitFilterBarSectionCategory),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                      child: categoriesAsync.when(
                        data:    (cats) => _buildCategoryChips(cats),
                        loading: ()     => _buildCategoryChips(_fallbackCategories),
                        error:   (_, __) => _buildCategoryChips(_fallbackCategories),
                      ),
                    ),

                    const Divider(
                      color: Colors.white12,
                      height: 24,
                      indent: 16,
                      endIndent: 16,
                    ),

                    // ── グループ3: タイプフィルター (BUG-134) ────────
                    _SectionLabel(l10n.habitFilterBarSectionType),
                    _typeTile(null,        l10n.habitFilterBarAll,             Icons.all_inclusive),
                    _typeTile('count',     l10n.habitHomeFilterTypeCount,      Icons.add_circle_outline),
                    _typeTile('checklist', l10n.habitHomeFilterTypeChecklist,  Icons.checklist),

                    const Divider(
                      color: Colors.white12,
                      height: 24,
                      indent: 16,
                      endIndent: 16,
                    ),

                    // ── グループ4: 他のリスト ──────────────────────
                    _SectionLabel(l10n.habitFilterBarSectionOtherLists),
                    _navTile(
                      context,
                      Icons.archive_outlined,
                      l10n.habitFilterBarNavArchive,
                      () {
                        Navigator.pop(context);
                        context.push(AppRoutes.archivedHabits);
                      },
                    ),
                    _navTile(
                      context,
                      Icons.delete_outline,
                      l10n.habitFilterBarNavTrash,
                      () {
                        Navigator.pop(context);
                        context.push(
                          AppRoutes.archivedHabits,
                          extra: {'tab': 'trash'},
                        );
                      },
                    ),

                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── カテゴリチップ一覧 ──────────────────────────────────────
  Widget _buildCategoryChips(List<String> cats) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        // 「すべて」チップ
        FilterChip(
          label: Text(AppLocalizations.of(context)!.habitFilterBarAll),
          selected: _selectedCategory == null,
          onSelected: (_) {
            setState(() => _selectedCategory = null);
            ref.read(habitCategoryFilterProvider.notifier).state = null;
          },
          selectedColor: AppTheme.primary.withValues(alpha: 0.25),
          checkmarkColor: AppTheme.primary,
          labelStyle: TextStyle(
            color: _selectedCategory == null ? AppTheme.primary : Colors.white70,
            fontSize: 13,
          ),
          backgroundColor: Colors.white.withValues(alpha: 0.06),
          side: BorderSide(
            color: _selectedCategory == null
                ? AppTheme.primary.withValues(alpha: 0.6)
                : Colors.white24,
          ),
        ),
        // APIから取得したカテゴリ
        for (final cat in cats)
          FilterChip(
            label: Text(habitCategoryLabel(AppLocalizations.of(context)!, cat)),
            selected: _selectedCategory == cat,
            onSelected: (_) {
              setState(() => _selectedCategory = cat);
              ref.read(habitCategoryFilterProvider.notifier).state = cat;
            },
            selectedColor: AppTheme.primary.withValues(alpha: 0.25),
            checkmarkColor: AppTheme.primary,
            labelStyle: TextStyle(
              color: _selectedCategory == cat ? AppTheme.primary : Colors.white70,
              fontSize: 13,
            ),
            backgroundColor: Colors.white.withValues(alpha: 0.06),
            side: BorderSide(
              color: _selectedCategory == cat
                  ? AppTheme.primary.withValues(alpha: 0.6)
                  : Colors.white24,
            ),
          ),
      ],
    );
  }

  Widget _filterTile(String? value, String label, IconData icon) {
    final isSelected = _selectedFreq == value;
    return RadioListTile<String?>(
      value: value,
      groupValue: _selectedFreq,
      onChanged: (v) {
        setState(() => _selectedFreq = v);
        ref.read(habitFilterProvider.notifier).state = v;
      },
      title: Text(
        label,
        style: TextStyle(
          color: isSelected ? AppTheme.primary : Colors.white70,
          fontSize: 14,
        ),
      ),
      secondary: Icon(
        icon,
        size: 20,
        color: isSelected ? AppTheme.primary : Colors.white38,
      ),
      activeColor: AppTheme.primary,
      dense: true,
    );
  }

  /// 【BUG-134 (2026-06-17)】タイプフィルタ用 RadioListTile。
  /// value=null → すべて、'count' → カウント型、'checklist' → チェックリスト型。
  /// _filterTile (頻度) と同パターン、Provider のみ habitTypeFilterProvider に差し替え。
  Widget _typeTile(String? value, String label, IconData icon) {
    final isSelected = _selectedType == value;
    return RadioListTile<String?>(
      value: value,
      groupValue: _selectedType,
      onChanged: (v) {
        setState(() => _selectedType = v);
        ref.read(habitTypeFilterProvider.notifier).state = v;
      },
      title: Text(
        label,
        style: TextStyle(
          color: isSelected ? AppTheme.primary : Colors.white70,
          fontSize: 14,
        ),
      ),
      secondary: Icon(
        icon,
        size: 20,
        color: isSelected ? AppTheme.primary : Colors.white38,
      ),
      activeColor: AppTheme.primary,
      dense: true,
    );
  }

  Widget _navTile(
    BuildContext context,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) {
    return ListTile(
      leading: Icon(icon, size: 20, color: Colors.white38),
      title: Text(
        label,
        style: const TextStyle(color: Colors.white70, fontSize: 14),
      ),
      trailing: const Icon(Icons.chevron_right, color: Colors.white24, size: 18),
      dense: true,
      onTap: onTap,
    );
  }
}

// ─────────────────────────────────────────────────
// グループラベル
// ─────────────────────────────────────────────────
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white38,
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
