import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/time_segment.dart';

/// 現在の TimeSegment を保持する StateNotifierProvider。
/// 境界を跨いだとき自動的に更新される。
final timeSegmentProvider = StateNotifierProvider<TimeSegmentNotifier, TimeSegment>(
  (ref) => TimeSegmentNotifier(),
);

class TimeSegmentNotifier extends StateNotifier<TimeSegment> {
  TimeSegmentNotifier() : super(TimeSegmentX.current()) {
    _scheduleNextBoundary();
  }

  Timer? _timer;

  /// 次の時間境界まで待ち、セグメントを更新してから再スケジュール
  void _scheduleNextBoundary() {
    _timer?.cancel();
    final delay = state.nextBoundary.difference(DateTime.now());
    // 最低 1 秒待つ（境界ぴったりの場合の安全マージン）
    final safeDelay = delay.isNegative
        ? const Duration(seconds: 1)
        : delay + const Duration(seconds: 1);

    _timer = Timer(safeDelay, () {
      state = TimeSegmentX.current();
      _scheduleNextBoundary(); // 次の境界を再スケジュール
    });
  }

  /// アプリ復帰時に外部から呼ぶ
  void refresh() {
    final current = TimeSegmentX.current();
    if (current != state) {
      state = current;
    }
    _scheduleNextBoundary();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
