enum TimeSegment {
  earlyMorning, // 05:00–08:59
  morning,      // 09:00–11:59
  noon,         // 12:00–15:59
  evening,      // 16:00–18:59
  night,        // 19:00–23:59
  lateNight,    // 00:00–04:59
}

extension TimeSegmentX on TimeSegment {
  /// 現在のローカル時刻から TimeSegment を返す
  static TimeSegment current() => fromHour(DateTime.now().hour);

  static TimeSegment fromHour(int hour) {
    if (hour >= 5  && hour < 9)  return TimeSegment.earlyMorning;
    if (hour >= 9  && hour < 12) return TimeSegment.morning;
    if (hour >= 12 && hour < 16) return TimeSegment.noon;
    if (hour >= 16 && hour < 19) return TimeSegment.evening;
    if (hour >= 19)              return TimeSegment.night;
    return TimeSegment.lateNight; // 0–4
  }

  /// 次の時間境界（ローカル時刻）
  /// 例: 現在 10:30 → 次の境界は 12:00
  DateTime get nextBoundary {
    final now = DateTime.now();
    const boundaries = [0, 5, 9, 12, 16, 19, 24];
    final nextHour = boundaries.firstWhere(
      (b) => b > now.hour,
      orElse: () => 24,
    );
    if (nextHour == 24) {
      // 翌日 00:00
      return DateTime(now.year, now.month, now.day + 1, 0, 0, 0);
    }
    return DateTime(now.year, now.month, now.day, nextHour, 0, 0);
  }

  /// API に渡す文字列キー
  String get apiKey {
    return switch (this) {
      TimeSegment.earlyMorning => 'early_morning',
      TimeSegment.morning      => 'morning',
      TimeSegment.noon         => 'noon',
      TimeSegment.evening      => 'evening',
      TimeSegment.night        => 'night',
      TimeSegment.lateNight    => 'late_night',
    };
  }
}
