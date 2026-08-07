import 'package:flutter/material.dart';

/// 【FEAT-388 Phase 2 (2026-05-30)】WorldFrame L2 軽量動きレイヤーの共通基底クラス。
///
/// 設計原則 (Sabiowl 「静かな聖域」哲学):
///   - framerate 30fps 相当 (refreshDuration: 33ms) でバッテリー消費を抑制 (Pre-mortem #5)
///   - RepaintBoundary は呼び出し側 (world_frame_section.dart) で wrap
///   - App lifecycle 対応: 各サブクラスで _ctrl.stop() / resume() を実装推奨
abstract class WorldAnimatedLayerBase extends StatefulWidget {
  const WorldAnimatedLayerBase({super.key});
}

abstract class WorldAnimatedLayerBaseState<T extends WorldAnimatedLayerBase>
    extends State<T> with TickerProviderStateMixin, WidgetsBindingObserver {
  /// 30fps 相当のフレーム更新間隔 (Pre-mortem #5: CPU/バッテリー消費対策)。
  static const Duration refreshDuration = Duration(milliseconds: 33);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// App が background に入ったとき AnimationController を停止。
  /// サブクラスで override して具体的な controller を stop する。
  void pauseAnimations();

  /// App が foreground に戻ったとき AnimationController を再開。
  void resumeAnimations();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      pauseAnimations();
    } else if (state == AppLifecycleState.resumed) {
      resumeAnimations();
    }
  }
}
