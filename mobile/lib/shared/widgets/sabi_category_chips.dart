import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../l10n/app_localizations.dart';

/// 【FEAT-210】カテゴリチップの横スクロール共通コンポーネント。
///
/// 「予定を追加」画面（`add_template_page.dart`）の UI を真実値として、
/// 「ToDoを追加」「習慣を追加」「カレンダー追加画面の ToDo タブ」で共通利用する。
///
/// デザイン仕様（真実値: `add_template_page.dart` 由来）:
/// - height: 40
/// - 選択時背景 alpha: 0.22 / 未選択時: 0.05（白）
/// - 選択時ボーダー alpha: 0.7 / 未選択時: 0.1（白）
/// - ボーダー幅: 選択 1.5 / 未選択 1.0
/// - padding: horizontal 14, vertical 8
/// - 選択時テキスト色: `Colors.white`（白固定。カテゴリ色は背景・ボーダーのみで表現）
/// - 未選択時テキスト色: `Colors.white70`
///
/// 使い方:
/// ```dart
/// SabiCategoryChips(
///   categories:       kSabiHabitCategories,
///   selectedCategory: _category,
///   onChanged:        (cat) => setState(() => _category = cat),
/// )
/// ```
class SabiCategoryChips extends StatelessWidget {
  const SabiCategoryChips({
    super.key,
    required this.categories,
    required this.selectedCategory,
    required this.onChanged,
  });

  /// カテゴリリスト: `(ラベル, 色)` のタプル
  final List<(String, Color)> categories;

  /// 現在選択中のカテゴリラベル
  final String selectedCategory;

  /// カテゴリ選択時のコールバック
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SizedBox(
      height: 40, // 【FEAT-210】真実値: add_template_page.dart のサイズ
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: categories.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final cat = categories[i];
          final isSelected = selectedCategory == cat.$1;
          return GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              onChanged(cat.$1);
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: isSelected
                    ? cat.$2.withValues(alpha: 0.22)
                    : Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: isSelected
                      ? cat.$2.withValues(alpha: 0.7)
                      : Colors.white.withValues(alpha: 0.1),
                  width: isSelected ? 1.5 : 1.0,
                ),
              ),
              child: Text(
                habitCategoryLabel(l10n, cat.$1),
                style: TextStyle(
                  color: isSelected ? Colors.white : Colors.white70,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Localizes a habit category API value (e.g. '運動') to a display label.
String habitCategoryLabel(AppLocalizations l10n, String apiValue) {
  return switch (apiValue) {
    'その他' => l10n.habitCategoryOther,
    '運動'   => l10n.habitCategoryExercise,
    '学習'   => l10n.habitCategoryStudy,
    '仕事'   => l10n.habitCategoryWork,
    '体力'   => l10n.habitCategoryPhysical,
    '美容'   => l10n.habitCategoryBeauty,
    '健康'   => l10n.habitCategoryHealth,
    '精神'   => l10n.habitCategoryMental,
    '創造'   => l10n.habitCategoryCreativity,
    '社交'   => l10n.habitCategorySocial,
    '休息'   => l10n.habitCategoryRest,
    _        => apiValue,
  };
}

/// 【FEAT-213】カテゴリ 11 値定数（Habit / ToDo / Timeline 完全共通）。
///
/// バックエンド `backend/api/constants.py` の `CATEGORY_STAT_MAP` で
/// 6 ステータス（運動力 / 学習力 / 健康力 / 精神力 / 創造力 / 貢献力）へ
/// 分散マッピングされる。全カテゴリが必ず 1 つ以上の stat に紐づくため、
/// 「努力 → 成長」のコアプロミスがサイレントに半分破られるバグは再発しない。
/// FEAT-208 で導入した 4 値分離（kSabiTimelineCategories）は本 FEAT で撤廃し、
/// `SabiCategoryChips` を完全に一本化した。
///
/// 各 add / edit 画面で `_categories` をハードコードせず、本定数を流用すること。
///
/// 【20260729 user feedback 対応】表示順で「その他」を先頭に配置。
/// 背景: 予定/ToDo/習慣・チャレンジ機能で学習/運動偏りの user 報告。旧 default
/// '学習' (FEAT-201 で「その他」廃止時代の名残) がカテゴリ選択の摩擦から
/// そのまま選ばれる → 学習/運動偏重の構造。「その他」は CATEGORY_STAT_MAP で
/// 6 stat 均等分配 (各 1/6) 実装済のため、default '学習' → 'その他' に変更
/// することで「選ばなくても均等に届く」= Sabi 哲学「押し付けない」に整合。
/// FEAT-465 Challenge master data に「その他」チャレンジも存在するため
/// Challenge 参加率低下の副作用なし (user 確認済 2026-07-29)。
const kSabiHabitCategories = <(String, Color)>[
  ('その他', Color(0xFF78909C)),  // ブルーグレー — 先頭配置 + default (20260729)
  ('運動',   Color(0xFFF87171)),  // 赤
  ('学習',   Color(0xFF60A5FA)),  // 青
  ('仕事',   Color(0xFF5B9BD5)),  // 青（濃）
  ('体力',   Color(0xFFFB923C)),  // オレンジ
  ('美容',   Color(0xFFF472B6)),  // ピンク
  ('健康',   Color(0xFF34D399)),  // 緑
  ('精神',   Color(0xFFA78BFA)),  // 紫
  ('創造',   Color(0xFFFFD60A)),  // 黄
  ('社交',   Color(0xFFEC6EA0)),  // ピンク系（濃）
  ('休息',   Color(0xFF64748B)),  // グレー
];
