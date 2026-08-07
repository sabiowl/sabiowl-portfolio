import 'package:flutter/material.dart';

import '../../../core/api/api_client.dart';

/// 【FEAT-426】Google カレンダー予定の完了状態 (Multi-device 同期用)。
///
/// 予定本文 (タイトル / 時刻 / メモ) は端末内 [LocalGoogleEventStore] のみに
/// 保存されるが、完了済フラグは Backend の `GoogleEventCompletion` に
/// `google_event_id` 単位で保持し、複数端末間で同期する。
class GoogleEventCompletion {
  const GoogleEventCompletion({
    required this.googleEventId,
    required this.eventDate,
    required this.isCompleted,
    required this.onTimeBonusAwarded,
  });

  final String   googleEventId;
  final DateTime eventDate;
  final bool     isCompleted;
  final bool     onTimeBonusAwarded;

  factory GoogleEventCompletion.fromJson(Map<String, dynamic> json) {
    return GoogleEventCompletion(
      googleEventId:      json['google_event_id'] as String,
      eventDate:          DateTime.parse(json['event_date'] as String),
      isCompleted:        json['is_completed'] as bool? ?? false,
      onTimeBonusAwarded: json['on_time_bonus_awarded'] as bool? ?? false,
    );
  }
}

/// `POST .../complete/` のレスポンス（FEAT-419 ボーナス情報を含む）。
class GoogleEventCompletionResult {
  const GoogleEventCompletionResult({
    this.onTimeBonusAwarded = false,
    this.onTimeBonusCoin    = 0,
  });

  final bool onTimeBonusAwarded;
  final int  onTimeBonusCoin;
}

class GoogleEventCompletionService {
  GoogleEventCompletionService(this._apiClient);
  final ApiClient _apiClient;

  /// [dateFrom] 〜 [dateTo] の completion 一覧を取得する（省略可）。
  Future<List<GoogleEventCompletion>> fetchAll({
    DateTime? dateFrom,
    DateTime? dateTo,
  }) async {
    final params = <String, String>{};
    if (dateFrom != null) params['date_from'] = _formatDate(dateFrom);
    if (dateTo   != null) params['date_to']   = _formatDate(dateTo);

    final res  = await _apiClient.dio.get(
      '/google-events/completions/',
      queryParameters: params,
    );
    final data = res.data as Map<String, dynamic>;
    final list = data['completions'] as List<dynamic>;
    return list
        .map((e) => GoogleEventCompletion.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 完了マーク + FEAT-419 ボーナス判定。
  Future<GoogleEventCompletionResult> complete(
    String googleEventId,
    DateTime eventDate,
    TimeOfDay? startTime,
  ) async {
    final res = await _apiClient.dio.post(
      '/google-events/$googleEventId/complete/',
      data: {
        'event_date': _formatDate(eventDate),
        if (startTime != null) 'start_time': _formatTime(startTime),
      },
    );
    final data = res.data as Map<String, dynamic>;
    return GoogleEventCompletionResult(
      onTimeBonusAwarded: data['on_time_bonus_awarded'] as bool? ?? false,
      onTimeBonusCoin:    data['on_time_bonus_coin']    as int?  ?? 0,
    );
  }

  /// 完了取消（コイン -5 対称化、冪等）。
  Future<void> uncomplete(String googleEventId) async {
    await _apiClient.dio.delete('/google-events/$googleEventId/complete/');
  }

  static String _formatDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static String _formatTime(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}
