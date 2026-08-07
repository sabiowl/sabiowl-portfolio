import '../../battle/models/job.dart';  // 【FEAT-304】Job (PartyEditDialog 用)
import '../../battle/models/weapon_info.dart';  // 【FEAT-326】WeaponInfo (装備変更 + damage)

/// 【FEAT-379 (2026-05-29)】ステータス結晶インベントリ (6 軸累積カウンター)。
///
/// Backend `PlayerProfileSerializer.crystals` のネスト dict に対応。
/// v1.0 では累積表示のみ、装着効果は v1.1+ 解禁予定 (Pre-mortem #3: 約束表現禁止)。
/// キーは CATEGORY_STAT_MAP 英語キーと完全整合。
class CrystalInventory {
  final int exercise;
  final int learning;
  final int health;
  final int mental;
  final int creation;
  final int contribution;

  const CrystalInventory({
    this.exercise     = 0,
    this.learning     = 0,
    this.health       = 0,
    this.mental       = 0,
    this.creation     = 0,
    this.contribution = 0,
  });

  factory CrystalInventory.fromJson(Map<String, dynamic> json) {
    return CrystalInventory(
      exercise:     json['exercise']     as int? ?? 0,
      learning:     json['learning']     as int? ?? 0,
      health:       json['health']       as int? ?? 0,
      mental:       json['mental']       as int? ?? 0,
      creation:     json['creation']     as int? ?? 0,
      contribution: json['contribution'] as int? ?? 0,
    );
  }

  // 【FEAT-489 Phase 2F-a】旧 crystalName(key) (日本語 hardcode) を削除。
  // 表示は level_up_dialog.dart の `_crystalName(l10n, key)` と
  // stats_page.dart の l10n switch が担っており、本 method は参照 0 件だった。

  int operator [](String key) {
    switch (key) {
      case 'exercise':     return exercise;
      case 'learning':     return learning;
      case 'health':       return health;
      case 'mental':       return mental;
      case 'creation':     return creation;
      case 'contribution': return contribution;
      default:             return 0;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is CrystalInventory &&
      other.exercise == exercise && other.learning == learning &&
      other.health == health && other.mental == mental &&
      other.creation == creation && other.contribution == contribution;

  @override
  int get hashCode => Object.hash(
      exercise, learning, health, mental, creation, contribution);
}

class ActiveCharacter {
  final int id;
  final String key;
  final String name;
  final String role;
  final String imagePath;
  // 【FEAT-430】「キャラ = ジョブ」固定化、battle のジョブ解決の唯一の真実値。
  final Job? job;

  const ActiveCharacter({
    required this.id,
    required this.key,
    required this.name,
    required this.role,
    required this.imagePath,
    this.job,
  });

  factory ActiveCharacter.fromJson(Map<String, dynamic> json) {
    final jobJson = json['job'] as Map<String, dynamic>?;
    return ActiveCharacter(
      id: json['id'] as int,
      key: json['key'] as String? ?? '',
      name: json['name'] as String? ?? '',
      role: json['role'] as String? ?? '',
      imagePath: json['image_path'] as String? ?? '',
      job: jobJson != null ? Job.fromJson(jobJson) : null,
    );
  }
}

class Player {
  final int id;
  final String name;
  final String gender;
  final int level;
  final int currentExp;   // API: current_exp
  final int maxExp;       // API: max_exp
  final int allocatablePoints;
  final int diamonds;
  final int diamondsTotal;

  /// 【FEAT-497 (2026-08-04)】交換ピース残高。
  ///
  /// 重複ガチャの救済 (100 ピース) で貯まる通貨。v1.0 は消費経路がゼロの
  /// dead currency で UI 参照も無かったため、本 field も持っていなかった。
  /// Shop の「ピース」タブで消費できるようになったので残高を持つ。
  final int exchangePieces;
  final String friendId;
  final int dailyTickets;
  final int weeklyTickets;
  final int monthlyTickets;
  final bool reminderEnabled;
  final String? reminderTime; // 'HH:MM:SS' 形式（API）、null = 未設定
  final ActiveCharacter? activeCharacter;
  /// 【FEAT-304】旧 PartyEditDialog で選択されたアクティブジョブ。
  /// 【FEAT-430】v1.0 では battle のジョブ解決に使われない (active_character.job が
  /// 唯一の真実値)。field 自体は v1.1+ 熟練度システムでの再活用のため維持。
  final Job? activeJob;
  final String mode;   // 'training' | 'adventure'
  final DateTime? createdAt; // アカウント作成日時（3日後ヘルスケア判定に使用）
  /// 【FEAT-257】Sabiowl の予定を Google カレンダーに書き出すかどうか。
  /// default=true。Settings 画面のトグルで OFF にできる。
  final bool gcalPushEnabled;

  /// 【FEAT-295】バトル出陣チケット蓄積数（習慣 +1 ごとに +1、3 で出陣可能）。
  /// 上限は `BattleConstants.maxBattleCharges`。
  final int battleCharges;

  /// 【FEAT-273】タイムライン予定の +15 分未完了リマインダー有効フラグ。
  /// default=false（FEAT-263 と同じ「明示同意なしには通知しない」哲学）。
  /// マイページの ReminderSettingsPage SwitchListTile で個別 ON。
  final bool timelineUncompletedReminderEnabled;

  /// 【FEAT-326】現在装備中の武器 (read-only、更新は EquipWeaponView 経由)。
  /// null = 未装備 (オンボーディング直後の極端ケース or 古い Backend)。
  /// `BattleOrchestrator` の damage 計算で `atkBonus ?? 10` で参照される。
  /// `PartyEditDialog` の装備スロット表示にも使用。
  final WeaponInfo? equippedWeapon;

  /// 【FEAT-334 (2026-05-27)】Legend 難易度スロット上限 (read-only)。
  /// 【FEAT-380 (2026-05-29)】「6 軸全 Lv 5 ALL で 1 枠目解放」仕様にアップグレード。
  /// 計算式: `min(6 軸 CharacterStat.level) // 5` (案 W ボトルネック方式、+1 オフセット削除)。
  /// 初期 0 個 (未解禁) → 6 軸 Lv 5 ALL で 1 個 (初解禁) → 6 軸 Lv 50 ALL で 10 個 (現実上限)。
  /// + FEAT-375 ダイヤ購入 (legendary_slots_bonus) で +1〜4 枠 (上限合計 5 枠)。
  /// 古い Backend (legendary_slots_total キー欠落) では default=0 にフォールバック (新仕様の未解禁状態)。
  final int legendarySlotsTotal;

  /// 【FEAT-334】現在 active な legendary 習慣数 (上限カウンタ)。
  /// `add_habit_page` / `edit_habit_page` の「伝説 (残 N/M)」表示 + 上限到達時 disabled 用。
  final int legendarySlotsUsed;

  /// 【FEAT-377 (2026-05-29)】ストリーク保護 在庫 (Shop で 💎 30/個 購入、上限 3 個)。
  /// Settings / Home 画面で表示。0 = 在庫なし。
  final int streakProtectionCount;

  /// 【FEAT-377】自動保護 ON/OFF (default=false)。
  /// Settings 画面のトグルで変更可能。ON = 途切れ瞬間に在庫から自動消費。
  final bool streakProtectionAutoEnabled;

  /// 【FEAT-420 (2026-06-10)】予約モード: 「使う」押下時に True、翌日の習慣達成判定で
  /// 消費 (途切れ救済) または False にリセット (途切れなし)。Settings 画面で
  /// 「予約中 🪶」chip 表示 + 取消ボタンの表示判定に使用。
  final bool streakProtectionPending;

  /// 【FEAT-379 (2026-05-29)】ステータス結晶インベントリ (6 軸累積カウンター)。
  /// 各ステータス Lv UP 時に +1、v1.0 は表示のみ、装着は v1.1+。
  final CrystalInventory crystals;

  /// 【FEAT-388 (2026-05-30)】直近レベルアップ発生日時 (v1.1 FEAT-310 先取り)。
  /// WorldBackgroundService が「レベルアップ直後 5min 以内」を判定し、
  /// 夜時間帯に酒場 (祝祭) 背景を発火させるために使用。
  /// v1.0 では Backend 未送信 → null → 酒場非発火 (graceful degradation)。
  /// v1.1 で Backend から送信開始時に有効化される。
  final DateTime? lastLevelUpAt;

  /// 【FEAT-398 (2026-05-31)】本日のバトル出陣回数 (0-10)。
  /// 10 回到達で AppBar 盾バッジが 🔒 表示に変化。
  /// 旧 Backend (FEAT-398 未デプロイ) では default 0 にフォールバック。
  final int dailyBattleCount;

  /// 【FEAT-427 (2026-06-11)】マンスリー天井で配布されるキャラ交換券の在庫。
  /// キャラクター画面で未所持 SSR キャラと交換できる (期限なし)。
  /// 旧 Backend (FEAT-427 未デプロイ) では default 0 にフォールバック。
  final int characterExchangeTickets;

  /// 【FEAT-429 (2026-06-12)】Legendary 枠拡張の累計購入回数 (0-5)。
  /// Shop の「上限到達」表示判定に使用。旧 Backend では default 0。
  final int legendarySlotsPurchaseCount;

  /// 【FEAT-429 (2026-06-12)】クエスト枠拡張の累計購入ボーナス (0-5)。
  /// `DAILY_BATTLE_LIMIT (10) + dailyBattleLimitBonus` がギルド画面の動的上限。
  /// 旧 Backend では default 0。
  final int dailyBattleLimitBonus;

  /// 【FEAT-429 (2026-06-12)】クエスト枠拡張の累計購入回数 (0-5)。
  /// Shop の「上限到達」表示判定に使用。旧 Backend では default 0。
  final int dailyBattleLimitPurchaseCount;

  /// 【FEAT-318 (2026-06-13 再活性化)】XP ブースト有効期限 (UTC)。
  /// null = 非アクティブ。`isXpBoostActive` / `xpBoostRemaining` で判定。
  final DateTime? xpBoostActiveUntil;

  /// 【FEAT-493 (2026-07-25) / 2026-07-26 更新】仮メモ機能 kill-switch flag。
  /// migration 0186 (2026-07-25) で default False → True 化、既存 row backfill 済。
  /// = 「使わない人向けの非表示スイッチ」として機能。実質全 user が True。
  /// ON = Home FAB が 📝 に変わり (Home Quick Capture)、Home メモセクションが表示。
  /// Calendar FAB は 4cd104d (2026-07-25) で分岐撤廃済 → 常に予定追加固定 (メモ経路
  /// から日付コンテキスト消失を防ぐため、Home = メモ、Calendar = 予定の役割分離)。
  final bool freeMemoEnabled;

  const Player({
    required this.id,
    required this.name,
    required this.gender,
    required this.level,
    required this.currentExp,
    required this.maxExp,
    required this.allocatablePoints,
    required this.diamonds,
    required this.diamondsTotal,
    this.exchangePieces = 0,  // 【FEAT-497】旧 Backend では欠落しうる
    required this.friendId,
    required this.dailyTickets,
    required this.weeklyTickets,
    required this.monthlyTickets,
    required this.reminderEnabled,
    this.reminderTime,
    this.activeCharacter,
    this.activeJob,
    required this.mode,
    this.createdAt,
    this.gcalPushEnabled = true,
    this.timelineUncompletedReminderEnabled = false,
    this.battleCharges = 0,
    this.equippedWeapon,
    this.legendarySlotsTotal = 0,  // 【FEAT-380】default 0 = 未解禁 (新仕様)
    this.legendarySlotsUsed = 0,
    this.streakProtectionCount = 0,
    this.streakProtectionAutoEnabled = false,
    this.streakProtectionPending = false,
    this.crystals = const CrystalInventory(),
    this.lastLevelUpAt,
    this.dailyBattleCount = 0,  // 【FEAT-398】
    this.characterExchangeTickets = 0,  // 【FEAT-427】
    this.legendarySlotsPurchaseCount = 0,  // 【FEAT-429】
    this.dailyBattleLimitBonus = 0,  // 【FEAT-429】
    this.dailyBattleLimitPurchaseCount = 0,  // 【FEAT-429】
    this.xpBoostActiveUntil,  // 【FEAT-318】
    this.freeMemoEnabled = false,  // 【FEAT-493】
  });

  /// 【2026-08-02 hotfix】指定フィールドだけを差し替えた複製を返す。
  ///
  /// ## なぜ必要か
  ///
  /// 楽観 UI 更新 (`setStreakProtectionAutoEnabled` 等) は従来
  /// `Player(id: current.id, name: current.name, ...)` と **全 37 フィールドを
  /// 手書きで詰め替えて**いた。この方式は「新しいフィールドを追加したとき、
  /// 既存の全コピー箇所に追記しないと、そのフィールドだけ既定値に戻る」という
  /// silent degradation を構造的に招く。
  ///
  /// 実際 `setStreakProtectionAutoEnabled` は 9 フィールド
  /// (`freeMemoEnabled` / `crystals` / `dailyBattleCount` /
  /// `dailyBattleLimitBonus` / `dailyBattleLimitPurchaseCount` /
  /// `characterExchangeTickets` / `legendarySlotsPurchaseCount` /
  /// `lastLevelUpAt` / `xpBoostActiveUntil`) を落としており、連続記録の保護を
  /// トグルすると仮メモ機能が一瞬 OFF に見える不具合として実機で顕在化した
  /// (2026-08-02 user 報告)。
  ///
  /// **今後、楽観更新は必ず本メソッドを使うこと。** 手書きの詰め替えを追加しない。
  ///
  /// ## 制約
  ///
  /// nullable フィールドを **明示的に null へ戻すことはできない** (引数省略と
  /// 区別できないため)。楽観更新の用途では発生しないが、必要になったら
  /// `ValueGetter<T?>` を受ける形に拡張すること。
  Player copyWith({
    int? id,
    String? name,
    String? gender,
    int? level,
    int? currentExp,
    int? maxExp,
    int? allocatablePoints,
    int? diamonds,
    int? diamondsTotal,
    int? exchangePieces,
    String? friendId,
    int? dailyTickets,
    int? weeklyTickets,
    int? monthlyTickets,
    bool? reminderEnabled,
    String? reminderTime,
    ActiveCharacter? activeCharacter,
    Job? activeJob,
    String? mode,
    DateTime? createdAt,
    bool? gcalPushEnabled,
    bool? timelineUncompletedReminderEnabled,
    int? battleCharges,
    WeaponInfo? equippedWeapon,
    int? legendarySlotsTotal,
    int? legendarySlotsUsed,
    int? streakProtectionCount,
    bool? streakProtectionAutoEnabled,
    bool? streakProtectionPending,
    CrystalInventory? crystals,
    DateTime? lastLevelUpAt,
    int? dailyBattleCount,
    int? characterExchangeTickets,
    int? legendarySlotsPurchaseCount,
    int? dailyBattleLimitBonus,
    int? dailyBattleLimitPurchaseCount,
    DateTime? xpBoostActiveUntil,
    bool? freeMemoEnabled,
  }) {
    return Player(
      id:                id ?? this.id,
      name:              name ?? this.name,
      gender:            gender ?? this.gender,
      level:             level ?? this.level,
      currentExp:        currentExp ?? this.currentExp,
      maxExp:            maxExp ?? this.maxExp,
      allocatablePoints: allocatablePoints ?? this.allocatablePoints,
      diamonds:          diamonds ?? this.diamonds,
      diamondsTotal:     diamondsTotal ?? this.diamondsTotal,
      exchangePieces:    exchangePieces ?? this.exchangePieces,
      friendId:          friendId ?? this.friendId,
      dailyTickets:      dailyTickets ?? this.dailyTickets,
      weeklyTickets:     weeklyTickets ?? this.weeklyTickets,
      monthlyTickets:    monthlyTickets ?? this.monthlyTickets,
      reminderEnabled:   reminderEnabled ?? this.reminderEnabled,
      reminderTime:      reminderTime ?? this.reminderTime,
      activeCharacter:   activeCharacter ?? this.activeCharacter,
      activeJob:         activeJob ?? this.activeJob,
      mode:              mode ?? this.mode,
      createdAt:         createdAt ?? this.createdAt,
      gcalPushEnabled:   gcalPushEnabled ?? this.gcalPushEnabled,
      timelineUncompletedReminderEnabled:
          timelineUncompletedReminderEnabled ??
              this.timelineUncompletedReminderEnabled,
      battleCharges:     battleCharges ?? this.battleCharges,
      equippedWeapon:    equippedWeapon ?? this.equippedWeapon,
      legendarySlotsTotal: legendarySlotsTotal ?? this.legendarySlotsTotal,
      legendarySlotsUsed:  legendarySlotsUsed ?? this.legendarySlotsUsed,
      streakProtectionCount:
          streakProtectionCount ?? this.streakProtectionCount,
      streakProtectionAutoEnabled:
          streakProtectionAutoEnabled ?? this.streakProtectionAutoEnabled,
      streakProtectionPending:
          streakProtectionPending ?? this.streakProtectionPending,
      crystals:          crystals ?? this.crystals,
      lastLevelUpAt:     lastLevelUpAt ?? this.lastLevelUpAt,
      dailyBattleCount:  dailyBattleCount ?? this.dailyBattleCount,
      characterExchangeTickets:
          characterExchangeTickets ?? this.characterExchangeTickets,
      legendarySlotsPurchaseCount:
          legendarySlotsPurchaseCount ?? this.legendarySlotsPurchaseCount,
      dailyBattleLimitBonus:
          dailyBattleLimitBonus ?? this.dailyBattleLimitBonus,
      dailyBattleLimitPurchaseCount:
          dailyBattleLimitPurchaseCount ?? this.dailyBattleLimitPurchaseCount,
      xpBoostActiveUntil: xpBoostActiveUntil ?? this.xpBoostActiveUntil,
      freeMemoEnabled:    freeMemoEnabled ?? this.freeMemoEnabled,
    );
  }

  factory Player.fromJson(Map<String, dynamic> json) {
    // BUG-K: id 欠落時の防御。サーバが想定外のレスポンス（部分エラー / null）を
    // 返した際に Player.fromJson 全体がスローし、ホーム画面が真っ白になるのを防ぐ。
    // CharacterStat / Character / PendingReward 等で既に施されている防御を統一する。
    final id = json['id'] as int?;
    if (id == null) {
      throw const FormatException('Player.fromJson: missing id field');
    }
    final charJson = json['active_character'] as Map<String, dynamic>?;
    final gachaJson = json['gacha_tickets'] as Map<String, dynamic>? ?? {};
    return Player(
      id: id,
      name: json['name'] as String? ?? '勇者',
      gender: json['gender'] as String? ?? 'f',
      level: json['level'] as int? ?? 1,
      currentExp: json['current_exp'] as int? ?? 0,
      maxExp: json['max_exp'] as int? ?? 100,
      allocatablePoints: json['allocatable_points'] as int? ?? 0,
      diamonds: json['diamonds'] as int? ?? 0,
      diamondsTotal: json['diamonds_total'] as int? ?? 0,
      exchangePieces: json['exchange_pieces'] as int? ?? 0,
      friendId: json['friend_id'] as String? ?? '',
      dailyTickets:   gachaJson['daily']   as int? ?? 0,
      weeklyTickets:  gachaJson['weekly']  as int? ?? 0,
      monthlyTickets: gachaJson['monthly'] as int? ?? 0,
      reminderEnabled: json['reminder_enabled'] as bool? ?? false,
      reminderTime:    json['reminder_time'] as String?,
      activeCharacter:
          charJson != null ? ActiveCharacter.fromJson(charJson) : null,
      // 【FEAT-304】古い Backend では `active_job` キー欠落 → null = 既存挙動互換
      // (Backend 側で active_character.job フォールバックが効く)。
      activeJob: json['active_job'] != null
          ? Job.fromJson(json['active_job'] as Map<String, dynamic>)
          : null,
      mode: json['mode'] as String? ?? 'training',
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String)
          : null,
      // 【FEAT-257】未デプロイ環境では default true で後方互換。
      gcalPushEnabled: json['gcal_push_enabled'] as bool? ?? true,
      // 【FEAT-273】未デプロイ環境では default false（明示同意なしには通知しない）。
      timelineUncompletedReminderEnabled:
          json['timeline_uncompleted_reminder_enabled'] as bool? ?? false,
      // 【FEAT-295】未デプロイ環境では default 0（バトル機能未有効）。
      battleCharges: json['battle_charges'] as int? ?? 0,
      // 【FEAT-326】未デプロイ環境では null = 旧 starter_sword フォールバック。
      // Backend は equipped_weapon を常に返す (PlayerWeapon 0 件時のみ null)。
      equippedWeapon: json['equipped_weapon'] != null
          ? WeaponInfo.fromJson(json['equipped_weapon'] as Map<String, dynamic>)
          : null,
      // 【FEAT-334 + FEAT-380】未デプロイ環境では default 0/0 = 未解禁状態 (新仕様: 6 軸全 Lv 5 ALL で初解禁)。
      legendarySlotsTotal: json['legendary_slots_total'] as int? ?? 0,
      legendarySlotsUsed:  json['legendary_slots_used']  as int? ?? 0,
      // 【FEAT-377】未デプロイ環境では default 0/false (保護なし = 安全側)。
      streakProtectionCount:        json['streak_protection_count']        as int?  ?? 0,
      streakProtectionAutoEnabled:  json['streak_protection_auto_enabled'] as bool? ?? false,
      // 【FEAT-420】未デプロイ環境では default false (予約なし = 安全側)。
      streakProtectionPending:      json['streak_protection_pending']      as bool? ?? false,
      // 【FEAT-379】未デプロイ環境では全 0 (結晶なし)。
      crystals: json['crystals'] != null
          ? CrystalInventory.fromJson(json['crystals'] as Map<String, dynamic>)
          : const CrystalInventory(),
      // 【FEAT-388 (2026-05-30)】v1.0 では Backend 未送信 → null (graceful degradation)。
      // v1.1 FEAT-310 で Backend 送信開始、酒場背景が発火するようになる。
      lastLevelUpAt: json['last_level_up_at'] != null
          ? DateTime.tryParse(json['last_level_up_at'] as String)
          : null,
      // 【FEAT-398 (2026-05-31)】旧 Backend (FEAT-398 未デプロイ) では default 0。
      dailyBattleCount: json['daily_battle_count'] as int? ?? 0,
      // 【FEAT-427 (2026-06-11)】旧 Backend (FEAT-427 未デプロイ) では default 0。
      characterExchangeTickets: json['character_exchange_tickets'] as int? ?? 0,
      // 【FEAT-429 (2026-06-12)】旧 Backend (FEAT-429 未デプロイ) では default 0。
      legendarySlotsPurchaseCount: json['legendary_slots_purchase_count'] as int? ?? 0,
      dailyBattleLimitBonus: json['daily_battle_limit_bonus'] as int? ?? 0,
      dailyBattleLimitPurchaseCount: json['daily_battle_limit_purchase_count'] as int? ?? 0,
      // 【FEAT-318 (2026-06-13 再活性化)】Backend は UTC isoformat で返却 (Pre-mortem #2)。
      // 旧 Backend (FEAT-318 未デプロイ) では null = 非アクティブ。
      xpBoostActiveUntil: json['xp_boost_active_until'] != null
          ? DateTime.tryParse(json['xp_boost_active_until'] as String)?.toUtc()
          : null,
      // 【FEAT-493】旧 Backend (FEAT-493 未デプロイ) では default false = opt-in 未適用。
      freeMemoEnabled: json['free_memo_enabled'] as bool? ?? false,
    );
  }

  /// 【FEAT-334】legendary 習慣を新規作成可能か (UI 側で「伝説」chip disabled 判定用)。
  bool get canCreateLegendary => legendarySlotsUsed < legendarySlotsTotal;

  /// 【FEAT-334 + FEAT-380】次の legendary slot が開放されるために必要な全 stat Lv (UI ヒント用)。
  /// FEAT-380 新仕様 (calc = min_level // 5):
  ///   slot=0 (Lv 0-4) → 次は Lv 5 で 1 枠目解放
  ///   slot=1 (Lv 5-9) → 次は Lv 10 で 2 枠目解放
  ///   一般化: `(slotsTotal + 1) * 5`
  ///   旧式 `slotsTotal * 5` は + 1 オフセット撤廃で意味が変わったため修正。
  int get nextLegendaryUnlockLevel => (legendarySlotsTotal + 1) * 5;

  double get expProgress {
    if (maxExp <= 0) return 0.0;
    return (currentExp / maxExp).clamp(0.0, 1.0);
  }

  bool get isAdventureMode => mode == 'adventure';

  /// 【FEAT-318 (2026-06-13 再活性化)】XP ブースト (×1.5) が現在有効かどうか。
  /// `xpBoostActiveUntil` は UTC、`DateTime.now().toUtc()` と比較 (Pre-mortem #2)。
  bool get isXpBoostActive =>
      xpBoostActiveUntil != null &&
      xpBoostActiveUntil!.isAfter(DateTime.now().toUtc());

  /// 【FEAT-318】XP ブーストの残り時間。非アクティブ時は `Duration.zero`。
  Duration get xpBoostRemaining => isXpBoostActive
      ? xpBoostActiveUntil!.difference(DateTime.now().toUtc())
      : Duration.zero;
}
