import 'package:flutter/material.dart';

class AppTheme {
  AppTheme._();

  // ── プライマリ系 ──────────────────────────────────────────────────
  static const Color primary      = Color(0xFF534AB7);
  static const Color primaryLight = Color(0xFF7F77DD); // プライマリ薄め（グラデ用）
  static const Color secondary    = Color(0xFFFF6584);

  // ── 背景・サーフェス ──────────────────────────────────────────────
  static const Color background       = Color(0xFF1A1A2E);
  static const Color surface          = Color(0xFF16213E);
  static const Color sheetBackground  = Color(0xFF1E1E2E); // BottomSheet / Dialog 背景
  /// カード背景
  static const Color card             = Color(0xFF2A2A3E);
  /// cardBackground は card の旧名。後方互換性のために残す。
  static const Color cardBackground   = Color(0xFF0F3460);

  // ── セマンティクス ────────────────────────────────────────────────
  static const Color success = Color(0xFF34D399); // 成功（緑）
  static const Color warning = Color(0xFFFBBF24); // 警告（黄）
  static const Color danger  = Color(0xFFEF4444); // 危険（赤）
  static const Color muted   = Color(0xFF6B7280); // ミュートテキスト

  // ── ゲーム固有 ────────────────────────────────────────────────────
  static const Color gold         = Color(0xFFFFD700);
  static const Color diamond      = Color(0xFF00BFFF);
  static const Color expColor     = Color(0xFF4CAF50);
  static const Color rarityPurple = Color(0xFF9C27B0); // ガチャ SR レアリティ

  // 【FEAT-307】カテゴリ色定数 + colorForCategory 関数は完全削除。
  // 0 callers の dead code (5/23 P0 確認、本 FEAT 着手時の Grep 再確認済)。
  // 旧 catMental / catWork / catSocial は migration 0066 で死語化済の
  // 'メンタル' / '作業' / '交流' に紐付いていたため、削除一択 (FEAT-307 §2.3 採択案 Y)。
  // 各 widget はローカル _categoryColor() で 11 値カバー (habit_card / daily_task_section)。
  static const Color catExercise = Color(0xFFF87171); // 運動（一部画面で個別参照、削除しない）
  static const Color catStudy    = Color(0xFF60A5FA); // 学習（同上）
  static const Color catHealth   = Color(0xFF34D399); // 健康（同上）
  static const Color catOther    = Color(0xFF78909C); // その他（ブルーグレー、同上）

  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.dark(
        primary: primary,
        secondary: secondary,
        surface: surface,
        onPrimary: Colors.white,
        onSecondary: Colors.white,
        onSurface: Colors.white,
      ),
      scaffoldBackgroundColor: background,
      cardTheme: CardTheme(
        color: cardBackground,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        indicatorColor: primary.withValues(alpha: 0.2),
        labelTextStyle: WidgetStateProperty.all(
          const TextStyle(fontSize: 12, color: Colors.white),
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: surface,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          // 【FEAT-293】明示 Size(double.infinity, 48) で「**意図的な full-width
          // デフォルト**」を自己説明化する。旧 `Size.fromHeight(48)` は Flutter SDK
          // 仕様で同じ Size(∞, 48) を返すが、読み手が「高さ 48 だけ指定」と誤読
          // しやすく、Row 内で `Expanded` 包まずに置くと「BoxConstraints forces an
          // infinite width」で UI 崩壊する地雷だった (FEAT-292 / friend_add_page)。
          //
          // 動作上の互換性は維持（Size(∞, 48) は Size.fromHeight(48) と同値）。
          //
          // 【Row 内で使うときの規約】
          //   ❌ Row(children: [Expanded(child: TextField(...)), ElevatedButton(...)])
          //   → 「裸の ElevatedButton」は最小幅 ∞ を要求し、Expanded と取り合って崩壊。
          //
          //   ✅ パターン 1: ElevatedButton も Expanded で包む
          //     Row(children: [Expanded(child: TextField), Expanded(child: Button)])
          //
          //   ✅ パターン 2: ElevatedButton 側で minimumSize: Size(0, 48) を局所上書き
          //     ElevatedButton(style: styleFrom(minimumSize: Size(0, 48)), ...)
          //
          //   ✅ パターン 3: SizedBox(width: <固定>) で明示的にラップ
          //     SizedBox(width: 100, child: ElevatedButton(...))
          //
          // 詳細: CLAUDE.md「Flutter 既知の落とし穴 / Size.fromHeight 地雷」
          minimumSize: const Size(double.infinity, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: primary, width: 2),
        ),
      ),
      // fontFamily: 'NotoSansJP', // フォントファイル追加後に有効化
    );
  }
}
