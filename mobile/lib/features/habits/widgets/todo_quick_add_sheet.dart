import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/category_request_dialog.dart';
import '../providers/habits_provider.dart';
import '../../../shared/widgets/sabi_category_chips.dart' show habitCategoryLabel;

/// ToDo クイック追加シート。
/// タイトル入力のみで即時発行できる。プリセット選択も可能。
class TodoQuickAddSheet extends ConsumerStatefulWidget {
  const TodoQuickAddSheet({super.key});

  @override
  ConsumerState<TodoQuickAddSheet> createState() => _TodoQuickAddSheetState();
}

class _TodoQuickAddSheetState extends ConsumerState<TodoQuickAddSheet> {
  final _titleCtrl  = TextEditingController();
  bool   _saving    = false;
  String _priority  = 'medium';
  String _difficulty = 'normal';
  String _category  = '学習';   // 【FEAT-201】「その他」廃止、デフォルトを 4 値内の「学習」に

  @override
  void dispose() {
    _titleCtrl.dispose();
    super.dispose();
  }

  Future<void> _save(String title) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return;
    setState(() => _saving = true);
    HapticFeedback.mediumImpact();

    await ref.read(habitsNotifierProvider.notifier).createTodo(
          trimmed,
          priority:   _priority,
          difficulty: _difficulty,
          category:   _category,   // FEAT-147
        );

    if (mounted) Navigator.of(context).pop();
  }

  // FEAT-147: カテゴリチップ（優先度・難易度と同スタイル）
  Widget _buildCategoryChips(AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: _todoCategories.map((cat) {
            final selected = _category == cat.$1;
            return GestureDetector(
              onTap: () {
                HapticFeedback.selectionClick();
                setState(() => _category = cat.$1);
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: selected
                      ? cat.$2.withValues(alpha: 0.18)
                      : Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: selected
                        ? cat.$2.withValues(alpha: 0.7)
                        : Colors.white.withValues(alpha: 0.1),
                  ),
                ),
                child: Text(
                  habitCategoryLabel(l10n, cat.$1),
                  style: TextStyle(
                    color:      selected ? cat.$2 : Colors.white54,
                    fontSize:   13,
                    fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ),
            );
          }).toList(),
        ),
        // FEAT-148: カテゴリ追加リクエストリンク
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              CategoryRequestDialog.show(context);
            },
            child: Text(
              AppLocalizations.of(context)!.habitQuickAddCategoryRequestLink,
              style: TextStyle(
                color:           AppTheme.primary.withValues(alpha: 0.65),
                fontSize:        12,
                decoration:      TextDecoration.underline,
                decorationColor: AppTheme.primary.withValues(alpha: 0.4),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final viewInsets = MediaQuery.viewInsetsOf(context);
    // BUG-59(再修正): シートがステータスバーを除く画面全体を占めるよう最低高さを設定。
    final screenH = MediaQuery.of(context).size.height;
    final statusH = MediaQuery.of(context).padding.top;

    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: screenH - statusH - 8),
      child: Container(
      decoration: const BoxDecoration(
        color:        AppTheme.sheetBackground,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize:       MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── ドラッグハンドル ──────────────────────────────────
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Container(
                  width: 40, height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),

            // ── ヘッダー ─────────────────────────────────────────
            Text(
              l10n.habitQuickAddTitle,
              style: const TextStyle(
                color:      Colors.white,
                fontSize:   17,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.habitQuickAddSubtitle,
              style: TextStyle(
                color:    Colors.white.withValues(alpha: 0.45),
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 16),

            // ── タイトル入力 ─────────────────────────────────────
            TextField(
              controller: _titleCtrl,
              autofocus:  true,
              style: const TextStyle(color: Colors.white, fontSize: 15),
              textInputAction: TextInputAction.done,
              onSubmitted: _save,
              decoration: InputDecoration(
                hintText:  l10n.habitQuickAddHint,
                hintStyle: const TextStyle(color: Colors.white38),
                filled:    true,
                fillColor: Colors.white.withValues(alpha: 0.06),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide:   BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 12),
              ),
            ),

            const SizedBox(height: 16),

            // ── 優先度 ───────────────────────────────────────────
            Text(
              l10n.habitQuickAddPriorityLabel,
              style: TextStyle(
                color:    Colors.white.withValues(alpha: 0.4),
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _PriorityPill(
                  label: l10n.habitTodoPriorityHigh,
                  value: 'high',
                  selected: _priority == 'high',
                  color: Colors.redAccent,
                  onTap: () => setState(() => _priority = 'high'),
                ),
                const SizedBox(width: 8),
                _PriorityPill(
                  label: l10n.habitTodoPriorityMid,
                  value: 'medium',
                  selected: _priority == 'medium',
                  color: Colors.amber,
                  onTap: () => setState(() => _priority = 'medium'),
                ),
                const SizedBox(width: 8),
                _PriorityPill(
                  label: l10n.habitTodoPriorityLow,
                  value: 'low',
                  selected: _priority == 'low',
                  color: Colors.blueGrey,
                  onTap: () => setState(() => _priority = 'low'),
                ),
              ],
            ),

            const SizedBox(height: 14),

            // ── 難易度 ───────────────────────────────────────────
            Text(
              l10n.habitQuickAddDifficultyLabel,
              style: TextStyle(
                color:    Colors.white.withValues(alpha: 0.4),
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _DifficultyPill(
                  label: 'Easy',
                  value: 'easy',
                  exp: 20,
                  selected: _difficulty == 'easy',
                  onTap: () => setState(() => _difficulty = 'easy'),
                ),
                const SizedBox(width: 8),
                _DifficultyPill(
                  label: 'Normal',
                  value: 'normal',
                  exp: 30,
                  selected: _difficulty == 'normal',
                  onTap: () => setState(() => _difficulty = 'normal'),
                ),
                const SizedBox(width: 8),
                _DifficultyPill(
                  label: 'Hard',
                  value: 'hard',
                  exp: 40,
                  selected: _difficulty == 'hard',
                  onTap: () => setState(() => _difficulty = 'hard'),
                ),
                const SizedBox(width: 8),
                _DifficultyPill(
                  label: 'Legend',
                  value: 'legendary',
                  exp: 60,
                  selected: _difficulty == 'legendary',
                  onTap: () => setState(() => _difficulty = 'legendary'),
                ),
              ],
            ),

            const SizedBox(height: 14),

            // ── カテゴリ（FEAT-147）─────────────────────────────────────
            Text(
              l10n.habitQuickAddCategoryLabel,
              style: TextStyle(
                color:    Colors.white.withValues(alpha: 0.4),
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 8),
            _buildCategoryChips(l10n),

            const SizedBox(height: 20),

            // ── 登録ボタン ──────────────────────────────────────
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _titleCtrl,
              builder: (_, value, __) {
                final canAdd = value.text.trim().isNotEmpty && !_saving;
                return SizedBox(
                  width: double.infinity,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 150),
                    opacity:  canAdd ? 1.0 : 0.35,
                    child: ElevatedButton(
                      onPressed: canAdd ? () => _save(_titleCtrl.text) : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: _saving
                          ? const SizedBox(
                              height: 18, width: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white,
                              ),
                            )
                          : Text(
                              l10n.habitQuickAddSubmitButton,
                              style: const TextStyle(
                                fontSize:   15,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    ),    // end Container
    );    // end ConstrainedBox
  }
}

// ── カテゴリチップ（FEAT-147）─────────────────────────────────────────────────

// 【FEAT-288】CATEGORY_CHOICES の代表 4 値（精神は 11 値中の 1 つ）。
// Backend は 11 値（運動/学習/仕事/体力/美容/健康/精神/創造/社交/休息/その他）を
// 受け付けるが、Quick Add 経路は代表 4 値に絞って導線をシンプルに保つ。
// 11 値全展開は Phase 2（add_habit_page 等の主要編集 UI）で実施予定。
const _todoCategories = [
  ('運動', Color(0xFFF87171)),
  ('学習', Color(0xFF60A5FA)),
  ('健康', Color(0xFF34D399)),
  ('精神', Color(0xFFA78BFA)),
];

// ── 優先度ピル ────────────────────────────────────────────────────────────────

class _PriorityPill extends StatelessWidget {
  final String   label;
  final String   value;
  final bool     selected;
  final Color    color;
  final VoidCallback onTap;

  const _PriorityPill({
    required this.label,
    required this.value,
    required this.selected,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? color.withValues(alpha: 0.18)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? color.withValues(alpha: 0.7)
                : Colors.white.withValues(alpha: 0.1),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color:      selected ? color : Colors.white54,
            fontSize:   13,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

// ── 難易度ピル ────────────────────────────────────────────────────────────────

class _DifficultyPill extends StatelessWidget {
  final String   label;
  final String   value;
  final int      exp;
  final bool     selected;
  final VoidCallback onTap;

  const _DifficultyPill({
    required this.label,
    required this.value,
    required this.exp,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 7),
          decoration: BoxDecoration(
            color: selected
                ? AppTheme.primary.withValues(alpha: 0.18)
                : Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected
                  ? AppTheme.primary.withValues(alpha: 0.7)
                  : Colors.white.withValues(alpha: 0.1),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  color:      selected ? AppTheme.primary : Colors.white54,
                  fontSize:   12,
                  fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
              Text(
                '+$exp',
                style: TextStyle(
                  color:    selected
                      ? AppTheme.primary.withValues(alpha: 0.7)
                      : Colors.white24,
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
