// 【FEAT-499 / FEAT-500 レビュー §C1 (2026-07-26)】音声入力波形 painter。
// memo_page.dart から分離、責務単一化 (~1600 行の巨大 file を 4 分割の 1 つ)。
//
// 特徴:
//   - 28 本の縦棒、複数周波数 sin 合成で pseudo-random amplitude
//   - dB 連動 (soundLevel 0.0-1.0) で振幅 + alpha が変化
//   - shouldRepaint は progress OR soundLevel 変化時のみ (無駄な CPU 抑制)
//
// ChatGPT 4o orb を意図的に模倣しない設計 (§3.2 minimal 準拠、商標リスク回避)。
import 'dart:math' show sin, pi;

import 'package:flutter/material.dart';

class MemoWaveformPainter extends CustomPainter {
  /// 時間ベースの progress (0.0-1.0、_waveAnimCtrl.value)。
  final double progress;

  /// dB 連動振幅 (0.0-1.0)。
  /// 0.0 = 静音 (subtle 動きのみ) / 1.0 = 大声 (最大振幅)。
  /// memo_page.dart 側で onSoundLevelChange callback から EMA 平滑化済み。
  final double soundLevel;

  const MemoWaveformPainter(this.progress, this.soundLevel);

  static const _barCount = 28;
  static const _barWidth = 2.5;
  static const _gap = 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;
    const totalWidth = _barCount * (_barWidth + _gap) - _gap;

    for (int i = 0; i < _barCount; i++) {
      final phase = i * (2 * pi / _barCount);
      // 複数周波数の sin 合成でランダム感を演出
      final raw = sin(progress * 2 * pi * 2.0 + phase) * 0.55 +
                  sin(progress * 2 * pi * 3.3 + phase * 1.8) * 0.35 +
                  sin(progress * 2 * pi * 0.7 + phase * 0.5) * 0.10;
      final amplitude = (raw.clamp(-1.0, 1.0) + 1) / 2;
      // dB 連動: base (静音でも subtle に動く) + soundLevel 連動 (音量で拡大)
      //   soundLevel=0.0: 3-6px (subtle idle 動き、話す前 or 静音)
      //   soundLevel=0.5: 3-16px (通常会話)
      //   soundLevel=1.0: 3-26px (大声、bar が跳ねる感じ)
      // 端末が onSoundLevelChange を発火しない場合 soundLevel=0.0 = 現行より
      // 大人しい動作にフォールバック (破壊ゼロ、静か → Sabi 哲学整合)。
      final baseHeight = 3.0 + 3.0 * amplitude;
      final soundHeight = 20.0 * soundLevel * amplitude;
      final barHeight = baseHeight + soundHeight;

      // 色 alpha も音量連動: 静音では薄く、大声では濃く
      final alphaBase = 0.35 + 0.15 * amplitude;
      final alphaSound = 0.35 * soundLevel * amplitude;
      paint.color = Colors.white.withValues(alpha: alphaBase + alphaSound);

      final x = (size.width - totalWidth) / 2 + i * (_barWidth + _gap);
      final y = (size.height - barHeight) / 2;

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y, _barWidth, barHeight),
          const Radius.circular(1.5),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(MemoWaveformPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.soundLevel != soundLevel;
}
