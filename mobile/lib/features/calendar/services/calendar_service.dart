import '../../../core/api/api_client.dart';
import '../models/calendar_models.dart';

/// Backend `/calendar/*` への薄い HTTP クライアント。
///
/// 【FEAT-268】Google Calendar 連携系のメソッド（sync / push / update / delete /
/// reconcile / retry / unsync）は `GoogleCalendarSyncService` へ移動した。
/// 本サービスは Sabiowl Backend 側の calendar 集計データ（streak / stats / heatmap /
/// daily / bootstrap）取得のみを担当する。
class CalendarService {
  final ApiClient _apiClient;
  CalendarService(this._apiClient);

  Future<CalendarData> fetchCalendar(int year, int month) async {
    final res = await _apiClient.dio
        .get('/calendar/', queryParameters: {'year': year, 'month': month});
    return CalendarData.fromJson(res.data as Map<String, dynamic>);
  }

  Future<StreakData> fetchStreak() async {
    final res = await _apiClient.dio.get('/calendar/streak/');
    return StreakData.fromJson(res.data as Map<String, dynamic>);
  }

  Future<StatsData> fetchStats(int year, int month) async {
    final res = await _apiClient.dio
        .get('/calendar/stats/', queryParameters: {'year': year, 'month': month});
    return StatsData.fromJson(res.data as Map<String, dynamic>);
  }

  Future<HeatmapData> fetchHeatmap() async {
    final response = await _apiClient.dio.get('/calendar/heatmap/');
    return HeatmapData.fromJson(response.data as Map<String, dynamic>);
  }

  /// 指定日の習慣・ToDo 達成状況を取得（CAL-01）
  Future<DailyData> fetchDailyData(String date) async {
    final res = await _apiClient.dio
        .get('/calendar/daily/', queryParameters: {'date': date});
    return DailyData.fromJson(res.data as Map<String, dynamic>);
  }

  /// P1-3: カレンダー画面の bootstrap（calendar + streak + daily を 1 リクエスト）
  Future<CalendarBootstrapData> fetchCalendarBootstrap({
    required int year,
    required int month,
    required String date,
  }) async {
    final raw = await fetchCalendarBootstrapRaw(
      year: year, month: month, date: date,
    );
    return CalendarBootstrapData.fromJson(raw);
  }

  /// 【FEAT-280】SWR provider が raw JSON をキャッシュに保存するため、
  /// パース前の Map を返す内部用メソッド。
  Future<Map<String, dynamic>> fetchCalendarBootstrapRaw({
    required int year,
    required int month,
    required String date,
  }) async {
    final res = await _apiClient.dio.get(
      '/calendar/bootstrap/',
      queryParameters: {'year': year, 'month': month, 'date': date},
    );
    return Map<String, dynamic>.from(res.data as Map);
  }
}
