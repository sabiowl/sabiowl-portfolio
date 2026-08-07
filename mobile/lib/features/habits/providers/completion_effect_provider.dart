import 'dart:ui';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// ── パーティクル発生源（習慣カードの画面座標）────────────────────────────────
//
// HabitCard のインクリメントボタン押下時に保存し、
// rewardToastProvider のリスナーが消費する（1 回読み取ったら null に戻す）。
final completionTapPositionProvider = StateProvider<Offset?>((ref) => null);

// ── 額縁グロウ状態 ───────────────────────────────────────────────────────────
//
// true: 額縁グロウアニメーションを再生する
// false: アニメーションを収束させる
// home_page が onFrameReached コールバック内で true に、
// エフェクト完了後に false にセットする。
final worldFrameGlowProvider = StateProvider<bool>((ref) => false);
