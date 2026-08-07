import 'package:dio/dio.dart';
import 'package:dio_cache_interceptor/dio_cache_interceptor.dart';  // 【FEAT-476】
import 'package:flutter/foundation.dart';

import '../../../core/api/api_client.dart';
import '../models/battle_log_entry.dart';
import '../models/enemy.dart';
import '../models/job.dart';
import '../../gamification/models/job_mastery.dart';  // 【FEAT-511 Phase A】
import '../../../core/api/dio_error_helper.dart';  // 【FEAT-515】
import '../../../core/l10n/service_l10n.dart';  // 【FEAT-489 Phase 2F-a】

/// 【FEAT-398 (2026-05-31)】1 日 10 回出陣上限到達時にスローされる例外。
///
/// `BattleStartView` が 403 + `code='daily_battle_limit_reached'` を返したとき、
/// `BattleService.startBattle()` が本例外をスローする。
/// 呼び出し側 (GuildPage / BattleProvider) で catch して Sabi 口調 Dialog を表示する。
class DailyBattleLimitReachedException implements Exception {
  const DailyBattleLimitReachedException({
    required this.message,
    required this.currentCount,
    required this.limit,
  });

  /// Backend から受け取ったサビ口調メッセージ (dialog の content に使う)。
  final String message;

  /// 【FEAT-429 (2026-06-12)】本日の出陣回数 (Backend `current_count`)。
  final int currentCount;

  /// 【FEAT-429 (2026-06-12)】本日の出陣上限 (Backend `limit`、10 + bonus)。
  final int limit;

  @override
  String toString() => 'DailyBattleLimitReachedException: $message';
}

/// 【FEAT-295 Phase 1d/1e】Backend `/battle/` API ラッパー。
///
/// Backend 側エンドポイント:
///   - `POST /api/battle/start/` → `{ token, enemy: {...}, weapon: {...} }`
///   - `POST /api/battle/finish/` → `{ coins_gained, exp_gained, leveled_up, ... }`
///
/// **Pre-mortem #2** 対応: Backend 側で「物理的にあり得ない結果」をチェックする
/// （Flutter 側はチート対策の主防御線ではない、ソロアプリ哲学）。Flutter 側は
/// 単に正規の戦闘進行データを送るだけ。
class BattleService {
  BattleService(this._apiClient);

  final ApiClient _apiClient;

  /// 戦闘開始: token + 敵パラメータを受け取る。
  ///
  /// `enemyKey` 指定で特定の敵と戦える（FEAT-296、ギルド画面のボス選択用）。
  /// 未指定（null）の場合は Backend が default ゴブリンで開始する（後方互換、
  /// BattleWidget の「出陣する」経路）。
  ///
  /// 失敗時: DioException を rethrow（呼び出し側で UI 表示）。
  /// 主要エラー:
  ///   - `400 not_enough_charges`（battle_charges < 3）
  ///   - `400 enemy_not_found`（指定 enemyKey が存在しない）
  /// 【FEAT-298】`potionsToUse` で回復薬使用予定数（0-3）を申告。
  /// 【FEAT-376】新規: `potionsPlusToUse` (上位回復薬) / `attackPotionsToUse` (攻撃の薬) を追加。
  Future<BattleStartResponse> startBattle({
    String? enemyKey,
    int potionsToUse        = 0,
    int potionsPlusToUse    = 0,
    int attackPotionsToUse  = 0,
    int defensePotionsToUse = 0,
  }) async {
    final body = <String, dynamic>{};
    if (enemyKey != null) body['enemy_key'] = enemyKey;
    if (potionsToUse > 0)        body['potions_to_use']                = potionsToUse;
    if (potionsPlusToUse > 0)    body['recovery_potion_plus_to_use']   = potionsPlusToUse;
    if (attackPotionsToUse > 0)  body['attack_potion_to_use']          = attackPotionsToUse;
    // 【FEAT-432】防御の薬、攻撃の薬と完全対称
    if (defensePotionsToUse > 0) body['defense_potion_to_use']         = defensePotionsToUse;
    try {
      final res = await _apiClient.dio.post('/battle/start/', data: body);
      return BattleStartResponse.fromJson(res.data as Map<String, dynamic>);
    } on DioException catch (e) {
      // 【FEAT-398】1 日 10 回出陣上限 (403 daily_battle_limit_reached) → 専用例外スロー
      if (e.response?.statusCode == 403) {
        final data = e.response?.data;
        // 【FEAT-515 (2026-08-04)】raw `data['error']` を文字列比較しない。
        //
        // Backend が旧形式 `{'error': 'code'}` から新形式
        // `{'error': {'code', 'message'}}` に移ると `data['error']` は **Map** に
        // なり、この比較は例外も出さずに **黙って false** になる。
        // 出陣上限の専用ダイアログが出なくなり、汎用エラーに落ちる。
        // `ApiError.code` は 3 形式すべてから同じ code を取り出す。
        final apiError = ApiError.fromResponse(data);
        if (apiError.code == 'daily_battle_limit_reached') {
          throw DailyBattleLimitReachedException(
            // 【FEAT-515 Phase 2】`message` は Backend 組み立ての日本語。
            // localizedMessage 経由で code から ARB を引く。
            message: apiError.localizedMessage.isNotEmpty
                ? apiError.localizedMessage
                : ServiceL10n.current.battleDailyLimitReachedFallbackSabi_message,
            // 【FEAT-429 (2026-06-12)】動的上限 (10 + bonus) を Dialog 表示に反映。
            // 数値は error 本体ではなく top-level に載るので data から読む
            currentCount: (data is Map ? data['current_count'] as int? : null) ?? 0,
            limit:        (data is Map ? data['limit']         as int? : null) ?? 10,
          );
        }
      }
      rethrow;
    }
  }

  /// 【FEAT-296】Enemy 一覧を取得する。
  ///
  /// `tier` が 'zako' or 'boss' のときは filter、それ以外（null）は全件返却。
  /// 【FEAT-476 (2026-07-03) → 2026-07-09 hotfix】cache policy を `forceCache`
  /// (キャッシュ最優先、24h 内はネットワーク叩かない) から `refreshForceCache`
  /// (常にネットワーク優先、失敗時のみキャッシュ fallback) に変更。
  ///
  /// 変更理由: admin から敵マスタ (HP / attack / reward) 編集した際、24h
  /// キャッシュに阻まれて Mobile 側の表示が更新されない問題を解消。balance
  /// 調整が pull-to-refresh / 次回ギルド画面訪問で即応で反映されるようになる。
  /// offline / Backend 障害時は 24h キャッシュから graceful degrade する
  /// (可用性は維持)。
  /// 失敗時は **空リストを返す**（ギルド画面が真っ白にならない、サイレントフォールバック）。
  Future<List<EnemyMaster>> fetchEnemyList({String? tier}) async {
    try {
      final res = await _apiClient.dio.get(
        '/battle/enemies/',
        queryParameters: tier == null ? null : {'tier': tier},
        options: CacheOptions(
          store: null,  // インターセプターのグローバルストア (HiveCacheStore) を使用
          policy: CachePolicy.refreshForceCache,
          maxStale: const Duration(hours: 24),
        ).toOptions(),
      );
      final data = res.data as Map<String, dynamic>;
      final list = data['enemies'] as List<dynamic>? ?? [];
      return list
          .map((e) => EnemyMaster.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e, st) {
      debugPrint('[BattleService.fetchEnemyList] failed: $e\n$st');
      return const <EnemyMaster>[];
    }
  }

  /// 【FEAT-305】Backend `GET /api/battle/logs/?limit=N` を叩いて直近 N 件のログを返す。
  /// リリア（ギルド受付）の状態判定で「直近 5 分以内勝敗」「連戦判定」に使用。
  /// 失敗時は空リスト返却（ギルド画面で reception view が崩れないサイレントフォールバック）。
  Future<List<BattleLogEntry>> fetchBattleLogs({int limit = 10}) async {
    try {
      final res = await _apiClient.dio.get(
        '/battle/logs/',
        queryParameters: {'limit': limit},
      );
      final data = res.data as Map<String, dynamic>;
      final list = data['logs'] as List<dynamic>? ?? [];
      return list
          .map((e) => BattleLogEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e, st) {
      debugPrint('[BattleService.fetchBattleLogs] failed: $e\n$st');
      return const <BattleLogEntry>[];
    }
  }

  /// 戦闘終了: 結果送信 → 報酬反映。
  ///
  /// `token` は `startBattle` から取得した値、`finish` 時に Backend で検証される。
  /// `damage_dealt > enemy_hp_init * 20` (2026-07-05 5→20) / 30 分超過 token は
  /// 400 で reject される (Pre-mortem #2 対応)。
  /// 【2026-07-09】duration_sec < N 検証は完全撤去 (client 偽装可 + legitimate
  /// 1 撃キル誤検知副作用のため)。 Backend 詳細は
  /// `views/battle/finish.py` 参照。
  /// 【FEAT-298】`potionsUsed` で戦闘中に実消費した回復薬数を送信。
  /// 0 の場合 body から省略（後方互換、Backend default = 0）。
  /// Backend は `battle.potions_planned` 上限内であることを再検証 +
  /// `PlayerItem.quantity` を decrement。
  Future<BattleFinishResponse> finishBattle({
    required String token,
    required String result,
    required int durationSec,
    required int damageDealt,
    required int damageTaken,
    required int rounds,
    required String summaryText,
    int potionsUsed        = 0,
    int potionsPlusUsed    = 0,  // 【FEAT-376】
    int attackPotionsUsed  = 0,  // 【FEAT-376】
    int defensePotionsUsed = 0,  // 【FEAT-432】
  }) async {
    final data = <String, dynamic>{
      'token':        token,
      'result':       result,
      'duration_sec': durationSec,
      'damage_dealt': damageDealt,
      'damage_taken': damageTaken,
      'rounds':       rounds,
      'summary_text': summaryText,
    };
    if (potionsUsed > 0)        data['potions_used']                = potionsUsed;
    if (potionsPlusUsed > 0)    data['recovery_potion_plus_used']   = potionsPlusUsed;
    if (attackPotionsUsed > 0)  data['attack_potion_used']          = attackPotionsUsed;
    // 【FEAT-432】防御の薬、攻撃の薬と完全対称
    if (defensePotionsUsed > 0) data['defense_potion_used']         = defensePotionsUsed;
    final res = await _apiClient.dio.post('/battle/finish/', data: data);
    return BattleFinishResponse.fromJson(res.data as Map<String, dynamic>);
  }
}

/// `/battle/start/` のレスポンス。
class BattleStartResponse {
  const BattleStartResponse({
    required this.token,
    required this.enemyKey,
    required this.enemyName,
    required this.enemySpriteKey,
    required this.enemyHp,
    required this.enemyAtk,
    required this.enemySpd,
    this.playerJob,
    this.enemyPhysicalResistance = 1.0,
    this.enemyMagicalResistance = 1.0,
    this.enemyWeakUltCost,
    this.enemyBackgroundImagePath = '',
  });

  final String token;
  final String enemyKey;
  final String enemyName;
  final String enemySpriteKey;
  final int enemyHp;
  final int enemyAtk;
  final int enemySpd;

  /// 【FEAT-299】プレイヤーの active_character.job から派生したジョブ情報。
  /// Backend 側で warrior フォールバックされるため通常は non-null だが、
  /// 古い Backend と通信した場合の安全側として null 許容にしておく。
  final Job? playerJob;

  /// 【FEAT-302】敵の弱点 / 耐性パラメータ。Combatant に反映してダメージ計算で使う。
  /// 古い Backend 互換: default 1.0 / null = 「耐性なし、弱点なし」。
  final double enemyPhysicalResistance;
  final double enemyMagicalResistance;
  final int? enemyWeakUltCost;

  /// 【FEAT-381 (2026-05-29)】戦闘画面背景画像 asset path (tier 別汎用 or Enemy 個別)。
  /// battle_page.dart の Stack 最下層で参照、空文字 = 単色フォールバック。
  /// 古い Backend 互換: default ''。
  final String enemyBackgroundImagePath;

  factory BattleStartResponse.fromJson(Map<String, dynamic> json) {
    final enemy = json['enemy'] as Map<String, dynamic>;
    final jobJson = json['player_job'] as Map<String, dynamic>?;
    return BattleStartResponse(
      token:          json['token'] as String,
      enemyKey:       enemy['key']        as String,
      enemyName:      enemy['name']       as String,
      enemySpriteKey: enemy['sprite_key'] as String,
      enemyHp:        enemy['hp']         as int,
      enemyAtk:       enemy['atk']        as int,
      enemySpd:       enemy['spd']        as int,
      playerJob:      jobJson == null ? null : Job.fromJson(jobJson),
      // 【FEAT-302】null 安全（古い Backend と通信した場合の Pre-mortem #5 退行回避）。
      enemyPhysicalResistance:
          (enemy['physical_resistance'] as num?)?.toDouble() ?? 1.0,
      enemyMagicalResistance:
          (enemy['magical_resistance']  as num?)?.toDouble() ?? 1.0,
      enemyWeakUltCost: enemy['weak_ult_cost'] as int?,
      // 【FEAT-381】未デプロイ環境では default '' (背景なし、安全 fallback)。
      // 【FEAT-513 v1.1 hotfix 4 (2026-07-31)】旧 shim `.replaceAll('.png', '.webp')`
      // は Backend migration 0197 (2026-07-31) で DB 値を '.webp' 化したため削除。
      // Backend が旧 '.png' を返す環境 (未 deploy dev / rollback 直後) 対応が
      // 必要になったら再度 shim を復活可 (idempotent なため副作用なし)。
      enemyBackgroundImagePath:
          (enemy['background_image_path'] as String?) ?? '',
    );
  }
}

/// `/battle/finish/` のレスポンス。
class BattleFinishResponse {
  const BattleFinishResponse({
    required this.coinsGained,
    required this.expGained,
    required this.leveledUp,
    this.newLevel,
    required this.newCoins,
    required this.newExp,
    required this.battleCharges,
    this.battleFirstDiamond = false,
    this.weaponDropped,
    this.puzzlePieceColored,
    this.jobMastery,
  });

  final int coinsGained;
  final int expGained;
  final bool leveledUp;
  final int? newLevel;
  final int newCoins;
  final int newExp;
  final int battleCharges;

  /// 【FEAT-314】その日初のバトル勝利で +5 ダイヤが付与されたか。
  /// Backend が `battle_first_diamond: true` を返した場合のみ true。
  /// 古い Backend では default false（後方互換）。
  final bool battleFirstDiamond;

  /// 【FEAT-443 (2026-06-20)】バトル勝利時 10% 確率で木製武器がドロップ。
  /// null = ドロップなし (90% + 全 11 種所持済時)、
  /// non-null = 取得した武器情報 (Mobile 側で SnackBar 発火)。
  /// 古い Backend では null (後方互換)。
  final BattleWeaponDrop? weaponDropped;

  /// 【FEAT-479 (2026-07-06)】その日初回のバトル勝利で grey ピースを color 化。
  /// null = 発火せず (同日既取得 / active_scene 未設定 / grey ピース 0 個)、
  /// non-null = 演出情報 (piece_index / new_state / scene_key / scene_completed)。
  /// scene_completed=true のときは追加で reward_exp / reward_diamonds /
  /// next_scene_hint を含む (Phase 4 完成モーダル用)。
  /// 生 JSON Map で保持 (fromJson は上位で行い、Phase 3 では PuzzlePieceColored
  /// にパースして provider に set する)。
  final Map<String, dynamic>? puzzlePieceColored;

  /// 【FEAT-511 Phase A (2026-07-30)】ジョブ熟練度。
  /// null = active_character.job 未設定 (古い Backend も null で互換)。
  /// non-null = 現ジョブの EXP 加算結果 (leveled_up_now / maxed_now を含む)。
  final JobMastery? jobMastery;

  factory BattleFinishResponse.fromJson(Map<String, dynamic> json) {
    final dropRaw = json['weapon_dropped'];
    final masteryRaw = json['job_mastery'];
    return BattleFinishResponse(
      coinsGained:        json['coins_gained']         as int? ?? 0,
      expGained:          json['exp_gained']           as int? ?? 0,
      leveledUp:          json['leveled_up']           as bool? ?? false,
      newLevel:           json['new_level']            as int?,
      newCoins:           json['new_coins']            as int? ?? 0,
      newExp:             json['new_exp']              as int? ?? 0,
      battleCharges:      json['battle_charges']       as int? ?? 0,
      battleFirstDiamond: json['battle_first_diamond'] as bool? ?? false,
      weaponDropped:      dropRaw is Map<String, dynamic>
          ? BattleWeaponDrop.fromJson(dropRaw)
          : null,
      puzzlePieceColored: json['puzzle_piece_colored'] as Map<String, dynamic>?,
      jobMastery:         masteryRaw is Map<String, dynamic>
          ? JobMastery.fromJson(masteryRaw)
          : null,
    );
  }

  @override
  String toString() => '[BattleFinishResponse] +$coinsGained coins / +$expGained EXP'
      '${leveledUp ? ' / Lv.$newLevel UP!' : ''}'
      '${battleFirstDiamond ? ' / +5💎 (first-of-day)' : ''}'
      '${weaponDropped != null ? ' / drop=${weaponDropped!.weaponName}' : ''}';
}

/// 【FEAT-443 (2026-06-20)】バトル勝利時の武器ドロップ情報。
class BattleWeaponDrop {
  const BattleWeaponDrop({
    required this.weaponKey,
    required this.weaponName,
    required this.atkBonus,
  });

  final String weaponKey;
  final String weaponName;
  final int atkBonus;

  factory BattleWeaponDrop.fromJson(Map<String, dynamic> json) {
    return BattleWeaponDrop(
      weaponKey:  json['weapon_key']  as String? ?? '',
      weaponName: json['weapon_name'] as String? ?? '',
      atkBonus:   json['atk_bonus']   as int? ?? 0,
    );
  }
}

/// Debug 用 fallback constructor: Phase 1c のローカル戦闘で Backend 未実装時に使う。
extension BattleFinishResponseFallback on BattleFinishResponse {
  static BattleFinishResponse offlineLocal({
    required int coins,
    required int exp,
  }) {
    debugPrint('[BattleService] offlineLocal fallback used (Backend not reachable)');
    return BattleFinishResponse(
      coinsGained:   coins,
      expGained:     exp,
      leveledUp:     false,
      newCoins:      0,
      newExp:        0,
      battleCharges: 0,
    );
  }
}

/// 【FEAT-505】バトル速度モード (1x / 1.5x / 2x / 3x / Skip)。
///
/// SharedPreferences キー:
///   'battle_speed_multiplier' (double): 1.0 / 1.5 / 2.0 / 3.0  (通常モード)
///   'battle_skip_mode'        (bool):   true = Skip モード有効
///
/// Pre-mortem S3: `0.0` などの float sentinel は混同リスクがあるため、
/// skip は専用の bool キーで管理し、既存の double キーは通常モードのみで使用。
enum BattleSpeedMultiplier {
  x1, x15, x2, x3, skip;

  double get speedValue => switch (this) {
    x1   => 1.0,
    x15  => 1.5,
    x2   => 2.0,
    x3   => 3.0,
    skip => 1.0, // headless 実行は speed 概念を持たない
  };

  bool get isSkip => this == skip;

  String get label => switch (this) {
    x1   => '1x',
    x15  => '1.5x',
    x2   => '2x',
    x3   => '3x',
    skip => '⏭',
  };
}
