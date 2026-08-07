import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';
import '../models/achievement_models.dart';
import '../services/achievement_service.dart';

final achievementServiceProvider = Provider<AchievementService>((ref) {
  return AchievementService(ref.watch(apiClientProvider));
});

final achievementsProvider =
    FutureProvider.autoDispose<AchievementsData>((ref) {
  return ref.watch(achievementServiceProvider).fetchAchievements();
});
