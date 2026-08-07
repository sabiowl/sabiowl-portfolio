// 【FEAT-388 (2026-05-30) → FEAT-479 v1 pivot (2026-07-07)】
// WorldBackgroundService unit test。
//
// v1 pivot で時間帯連動 (resolvePath) 廃止に伴い、朝/昼/夕/夜/rest_day/levelUp/
// 冬季判定の 15+ シナリオを削除。現在は puzzle_world seed 3 シーンの
// pathForBackgroundKey / monoPathForBackgroundKey の契約のみ検証する。

import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/features/habits/services/world_background_service.dart';

void main() {
  group('WorldBackgroundService.pathForBackgroundKey', () {
    test('sunrise → world_sunrise.webp (目覚めの山頂)', () {
      final path = WorldBackgroundService.pathForBackgroundKey('sunrise');
      expect(path, isNotNull);
      expect(path, contains('world_sunrise.webp'));
    });

    test('morning_grassland (旧 key、後方互換) → sunrise と同じ path', () {
      final legacy = WorldBackgroundService.pathForBackgroundKey('morning_grassland');
      final current = WorldBackgroundService.pathForBackgroundKey('sunrise');
      expect(legacy, isNotNull);
      expect(legacy, equals(current));
    });

    test('noon_castle_town → world_noon_castle_town.webp', () {
      final path = WorldBackgroundService.pathForBackgroundKey('noon_castle_town');
      expect(path, contains('world_noon_castle_town.webp'));
    });

    test('night_forest_camp → world_night_forest_camp.webp', () {
      final path = WorldBackgroundService.pathForBackgroundKey('night_forest_camp');
      expect(path, contains('world_night_forest_camp.webp'));
    });

    test('unknown key → null (呼出側で fallback 適用)', () {
      expect(
        WorldBackgroundService.pathForBackgroundKey('nonexistent_scene'),
        isNull,
      );
      expect(
        WorldBackgroundService.pathForBackgroundKey(''),
        isNull,
      );
    });
  });

  group('WorldBackgroundService.monoPathForBackgroundKey', () {
    // 【2026-07-25 修正】旧テストは Ver1 流用時代の `world_morning_grassland_mono.webp`
    // を期待していたが、2026-07-07 の hybrid hotfix で専用 mono asset
    // `world_sunrise_mono.webp` へ差替え済 (ピース差別化の視覚品質向上、
    // world_background_service.dart:78-81 参照)。旧 asset は既に削除されており、
    // テストだけが存在しないファイル名を期待して赤のまま放置されていた。
    test('sunrise → world_sunrise_mono.webp (7/7 hotfix で専用 mono asset に差替え)', () {
      final path = WorldBackgroundService.monoPathForBackgroundKey('sunrise');
      expect(path, contains('world_sunrise_mono.webp'));
    });

    test('morning_grassland (旧 key) → sunrise と同 path', () {
      final legacy = WorldBackgroundService.monoPathForBackgroundKey('morning_grassland');
      final current = WorldBackgroundService.monoPathForBackgroundKey('sunrise');
      expect(legacy, equals(current));
    });

    test('noon_castle_town → world_noon_castle_town_mono.webp', () {
      final path = WorldBackgroundService.monoPathForBackgroundKey('noon_castle_town');
      expect(path, contains('world_noon_castle_town_mono.webp'));
    });

    test('night_forest_camp → world_night_forest_camp_mono.webp', () {
      final path = WorldBackgroundService.monoPathForBackgroundKey('night_forest_camp');
      expect(path, contains('world_night_forest_camp_mono.webp'));
    });

    test('unknown key → null', () {
      expect(
        WorldBackgroundService.monoPathForBackgroundKey('nonexistent_scene'),
        isNull,
      );
    });
  });

  group('WorldBackgroundService.kFallbackPath', () {
    test('v1 pivot 後は morning_grassland (目覚めの山頂) を fallback', () {
      // 旧 (時間帯連動時代) は evening_grassland_clouds を採用していたが、
      // puzzle_world starter scene の morning_grassland に統一。
      expect(WorldBackgroundService.kFallbackPath, contains('world_sunrise.webp'));
    });

    test('fallback path は sunrise/morning_grassland の path と一致', () {
      expect(
        WorldBackgroundService.kFallbackPath,
        equals(WorldBackgroundService.pathForBackgroundKey('sunrise')),
      );
    });

    test('assets/images/backgrounds/world/ 配下を指す', () {
      expect(
        WorldBackgroundService.kFallbackPath,
        startsWith('assets/images/backgrounds/world/'),
      );
    });
  });
}
