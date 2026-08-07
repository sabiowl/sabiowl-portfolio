import 'package:dio_cache_interceptor/dio_cache_interceptor.dart';  // 【FEAT-476】

import '../../../core/api/api_client.dart';
import '../models/gamification_models.dart';

class GamificationService {
  final ApiClient _apiClient;
  GamificationService(this._apiClient);

  // ── ステータス ──────────────────────────────────────────────
  Future<List<CharacterStat>> fetchStats() async {
    final res = await _apiClient.dio.get('/player/stats/');
    final list = res.data as List<dynamic>;
    return list.map((e) => CharacterStat.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Map<String, dynamic>> allocateStat(int statId) async {
    final res = await _apiClient.dio.post('/stats/$statId/allocate/');
    return res.data as Map<String, dynamic>;
  }

  // ── キャラクター ────────────────────────────────────────────

  /// 【FEAT-476 (2026-07-03) → 2026-07-09 hotfix】cache policy を `forceCache` から
  /// `refreshForceCache` に変更 (詳細は BattleService.fetchEnemyList と同経緯)。
  /// admin から Character master (公開/非公開、tagline、release_date、job 等) を
  /// 編集した際に即応で反映されるようになる。offline / Backend 障害時は 24h
  /// キャッシュから graceful degrade。
  Future<List<Character>> fetchCharacters() async {
    final res = await _apiClient.dio.get(
      '/characters/',
      options: CacheOptions(
        store: null,  // インターセプターのグローバルストア (HiveCacheStore) を使用
        policy: CachePolicy.refreshForceCache,
        maxStale: const Duration(hours: 24),
      ).toOptions(),
    );
    final list = res.data as List<dynamic>;
    return list.map((e) => Character.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> selectCharacter(int characterId) async {
    await _apiClient.dio.post('/characters/$characterId/select/');
  }

  /// 【FEAT-389 (2026-05-30)】未所持キャラをダイヤで購入する。
  ///
  /// 成功: { 'detail': '...', 'diamonds': N, 'character': {...} }
  /// 400: ダイヤ不足 / すでに所持
  /// 403: Lv 不足
  /// DioException を rethrow するので caller で catch すること。
  Future<Map<String, dynamic>> purchaseCharacter(int characterId) async {
    final res = await _apiClient.dio.post('/characters/$characterId/purchase/');
    return Map<String, dynamic>.from(res.data as Map);
  }

  /// 【FEAT-427 (2026-06-11)】キャラ交換券を 1 枚消費して未所持 SSR キャラを獲得する。
  ///
  /// 成功: { 'detail': '...', 'character_exchange_tickets': N, 'character': {...} }
  /// 400: 交換券不足 (no_ticket) / SSR以外 (not_ssr) / 既所持 (already_owned)
  /// 404: character_not_found
  /// DioException を rethrow するので caller で catch すること。
  Future<Map<String, dynamic>> exchangeCharacter(int characterId) async {
    final res = await _apiClient.dio.post('/characters/$characterId/exchange/');
    return Map<String, dynamic>.from(res.data as Map);
  }

  // ── ショップ ────────────────────────────────────────────────
  Future<Map<String, dynamic>> fetchShop() async {
    final res = await _apiClient.dio.get('/shop/');
    return res.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> purchaseItem(String itemId) async {
    final res = await _apiClient.dio.post('/shop/purchase/', data: {'item_id': itemId});
    return res.data as Map<String, dynamic>;
  }

  /// 【FEAT-443 (2026-06-20)】持ち物リストからアイテムを売却する。
  ///
  /// 成功時: { coins_gained, new_coins, item_id }
  /// 失敗時 DioException rethrow (400: equipped_weapon / not_owned / not_sellable / 404)。
  /// caller (ShopNotifier.sellItem) で catch してサビ口調 SnackBar を表示する。
  Future<Map<String, dynamic>> sellItem(String itemId) async {
    final res = await _apiClient.dio.post(
      '/shop/sell/',
      data: {'item_id': itemId},
    );
    return res.data as Map<String, dynamic>;
  }

  /// 【FEAT-318 (2026-06-13 再活性化)】XP ブースト (xp_boost_1.5x) を使用する。
  ///
  /// 成功時: { active_until, remaining_quantity, boosted_duration_minutes }
  /// 【BUG-116 (2026-06-14)】boosted_duration_hours → boosted_duration_minutes
  /// (効果時間 24h → 15min/stock 変更に伴う API field rename)
  /// 失敗時 DioException を rethrow (400: insufficient_stock / 409: already_active)。
  /// caller (ShopNotifier.useXpBoost) で catch してサビ口調 SnackBar を表示する。
  Future<Map<String, dynamic>> useXpBoost({int consumeValue = 1}) async {
    final res = await _apiClient.dio.post(
      '/items/use-xp-boost/',
      data: {'consume_value': consumeValue},
    );
    return res.data as Map<String, dynamic>;
  }

  // ── ガチャ ──────────────────────────────────────────────────
  Future<GachaStatus> fetchGachaStatus() async {
    final res = await _apiClient.dio.get('/gacha/status/');
    return GachaStatus.fromJson(res.data as Map<String, dynamic>);
  }

  /// 【FEAT-518】ガチャ排出確率を取得する (App Store Guideline 3.1.1 対応)。
  ///
  /// プレイヤー固有情報を含まない master data のため、チケット未所持でも取得できる
  /// (「購入前に開示」を満たすための要件)。
  Future<GachaOdds> fetchGachaOdds() async {
    final res = await _apiClient.dio.get('/gacha/odds/');
    return GachaOdds.fromJson(res.data as Map<String, dynamic>);
  }

  Future<Map<String, dynamic>> pullGacha(String ticketType) async {
    final res = await _apiClient.dio.post('/gacha/pull/', data: {'ticket_type': ticketType});
    return res.data as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> fetchPendingRewards() async {
    final res = await _apiClient.dio.get('/gacha/pending/');
    return (res.data as List<dynamic>)
        .map((e) => e as Map<String, dynamic>)
        .toList();
  }

  Future<Map<String, dynamic>> exchangeDuplicate(
      int pendingId, String exchangeType) async {
    final res = await _apiClient.dio.post(
      '/gacha/exchange/$pendingId/',
      data: {'exchange_type': exchangeType},
    );
    return res.data as Map<String, dynamic>;
  }

  /// 【FEAT-374】ガチャ「もう 1 度引く」(💎 50 消費)。
  ///
  /// 直近 1 回の pull に対してのみ有効。24h ウィンドウ内・redo 未使用の場合のみ成功。
  /// 失敗時は Dio が 400/503 を throw するため、caller で try/catch が必要。
  Future<Map<String, dynamic>> redoLastPull() async {
    final res = await _apiClient.dio.post('/gacha/redo/');
    return res.data as Map<String, dynamic>;
  }

  // 【廃止 (2026-06-26)】 称号 6 段階システムは実績 30 件統合で撤去。
  // fetchTitles() / TitlesData / Title モデルは全廃。
}
