import '../../../core/api/api_client.dart';
import '../models/achievement_models.dart';

class AchievementService {
  final ApiClient _client;
  AchievementService(this._client);

  Future<AchievementsData> fetchAchievements() async {
    final response = await _client.dio.get('/achievements/');
    return AchievementsData.fromJson(response.data as Map<String, dynamic>);
  }

  Future<Map<String, dynamic>> claimAchievement(String key) async {
    final response = await _client.dio.post('/achievements/$key/claim/');
    return response.data as Map<String, dynamic>;
  }
}
