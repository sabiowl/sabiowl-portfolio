import 'package:flutter/material.dart';
import '../services/time_segment.dart';
import 'app_theme.dart';

class TimeSegmentTheme {
  const TimeSegmentTheme._({
    required this.gradient,
    required this.accentColor,
    required this.appBarColor,
    required this.isDark,
    required this.sabiGlowOpacity,
  });

  final LinearGradient gradient;
  final Color accentColor;
  final Color appBarColor;
  final bool isDark;

  /// Sabi アイコン光彩の opacity（BoxShadow に適用）
  final double sabiGlowOpacity;

  static TimeSegmentTheme of(TimeSegment segment) {
    return switch (segment) {
      TimeSegment.earlyMorning => _earlyMorning,
      TimeSegment.morning      => _morning,
      TimeSegment.noon         => _noon,
      TimeSegment.evening      => _evening,
      TimeSegment.night        => _night,
      TimeSegment.lateNight    => _lateNight,
    };
  }

  // ── 早朝 (05–08): 朝焼け。ダーク紫→深青→オレンジがかった頂点 ──────────
  static const _earlyMorning = TimeSegmentTheme._(
    gradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        Color(0xFF0D0820), // 最上部: 深い紫夜明け前
        Color(0xFF1A1A3E), // 中央: アプリ背景色に近い
        Color(0xFF2A1520), // 下部: 暖かい朱色の反射
      ],
      stops: [0.0, 0.55, 1.0],
    ),
    accentColor:  Color(0xFFE07040), // 朝焼けオレンジ
    appBarColor:  Color(0xFF120820),
    isDark: true,
    sabiGlowOpacity: 0.30,
  );

  // ── 朝 (09–11): 明るい日差し。深青から明るい青へ ─────────────────────
  static const _morning = TimeSegmentTheme._(
    gradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        Color(0xFF0D1B3E), // 深い紺
        Color(0xFF1A2A5E), // ミッドナイトブルー
        Color(0xFF0D2040), // 落ち着いた青
      ],
      stops: [0.0, 0.5, 1.0],
    ),
    accentColor:  Color(0xFF4A90D9), // 空色ブルー
    appBarColor:  Color(0xFF0D1530),
    isDark: true,
    sabiGlowOpacity: 0.30,
  );

  // ── 昼 (12–15): 活発な光。青みの強い宇宙的な背景 ────────────────────
  static const _noon = TimeSegmentTheme._(
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Color(0xFF111A2E), // 標準背景
        Color(0xFF1A2840), // やや明るめの青
        Color(0xFF162038), // ターコイズよりの深青
      ],
      stops: [0.0, 0.5, 1.0],
    ),
    accentColor:  Color(0xFF00BCD4), // シアン/ターコイズ
    appBarColor:  Color(0xFF0F1A28),
    isDark: true,
    sabiGlowOpacity: 0.25,
  );

  // ── 夕方 (16–18): 茜色の空。深紫から赤みのある夜に ─────────────────
  static const _evening = TimeSegmentTheme._(
    gradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        Color(0xFF1A0820), // 深い紫紺
        Color(0xFF2A1030), // 赤紫
        Color(0xFF1A0A18), // 暗い底
      ],
      stops: [0.0, 0.5, 1.0],
    ),
    accentColor:  Color(0xFFE53935), // 茜色
    appBarColor:  Color(0xFF140818),
    isDark: true,
    sabiGlowOpacity: 0.25,
  );

  // ── 夜 (19–23): 深い夜空。アプリ基準色に最も近い ───────────────────
  static const _night = TimeSegmentTheme._(
    gradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        Color(0xFF0A0F1A), // 漆黒に近い
        AppTheme.background, // アプリ標準背景
        AppTheme.surface, // surface 色
      ],
      stops: [0.0, 0.5, 1.0],
    ),
    accentColor:  AppTheme.primary, // primary 紫
    appBarColor:  Color(0xFF0A0F1A),
    isDark: true,
    sabiGlowOpacity: 0.35,
  );

  // ── 深夜 (00–04): 静寂の星空。ほぼ黒、星のような輝き ───────────────
  static const _lateNight = TimeSegmentTheme._(
    gradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        Color(0xFF050510), // 最深部の黒
        Color(0xFF0A0A1A), // 静寂
        Color(0xFF0D0D22), // ごくわずかな青み
      ],
      stops: [0.0, 0.5, 1.0],
    ),
    accentColor:  Color(0xFF6C5CE7), // 冷たい紫
    appBarColor:  Color(0xFF050510),
    isDark: true,
    sabiGlowOpacity: 0.40,
  );
}
