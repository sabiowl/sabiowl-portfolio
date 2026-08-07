import '../../battle/models/job.dart';  // 【FEAT-430】Character.job (ジョブ修飾子表示用)

// ── キャラクターステータス ──────────────────────────────────────
class CharacterStat {
  final int id;
  final String name;
  final int level;
  final int currentExp;
  final int maxExp;

  const CharacterStat({
    required this.id,
    required this.name,
    required this.level,
    required this.currentExp,
    required this.maxExp,
  });

  factory CharacterStat.fromJson(Map<String, dynamic> j) {
    // P2-07: 必須 id が欠落していたらアプリを真っ白にせず明示的な FormatException で
    // クラッシュ要因をログに残す（mock サーバ・部分レスポンス等に対する防御）。
    final id = j['id'] as int?;
    if (id == null) {
      throw const FormatException('CharacterStat.fromJson: missing id field');
    }
    return CharacterStat(
      id: id,
      name: j['name'] as String? ?? '',
      level: j['level'] as int? ?? 1,
      currentExp: j['current_exp'] as int? ?? 0,
      maxExp: j['max_exp'] as int? ?? 100,
    );
  }

  double get expRate => maxExp <= 0 ? 0.0 : (currentExp / maxExp).clamp(0.0, 1.0);
}

/// 【2026-06-27】6 ステータスを総合評価した格付けランク。
///
/// PM 推奨採択 (2026-06-27): SS / S / A / B / C / D の 6 段階。
/// 元案 8 段階 (G まで) は Sabiowl の「静かな肯定」哲学と整合性が薄く、
/// 初期ユーザーへの F/G 表示によるネガティブ印象を避けるため除外。
/// SS は「全 stat MAX 近い究極形態」のやり込みシンボル。
enum StatRank {
  ss, s, a, b, c, d;

  /// 表示用ラベル ("SS", "S", "A", "B", "C", "D")
  String get label {
    switch (this) {
      case StatRank.ss: return 'SS';
      case StatRank.s:  return 'S';
      case StatRank.a:  return 'A';
      case StatRank.b:  return 'B';
      case StatRank.c:  return 'C';
      case StatRank.d:  return 'D';
    }
  }
}

/// 6 ステータスのリスト全体を集計し、平均 progressPercent から総合ランクを
/// 算出する extension。`stats_page` のランクバッジ表示で利用する。
extension CharacterStatRanking on List<CharacterStat> {
  /// 6 stat の `progressPercent` 平均 (0.0〜100.0)。
  /// 空配列の場合は 0.0。
  double get averageProgressPercent {
    if (isEmpty) return 0.0;
    final sum = fold<int>(0, (acc, s) => acc + s.progressPercent);
    return sum / length;
  }

  /// 平均 progressPercent から総合ランクを判定する。
  /// 判定基準 (PM 確定 2026-06-27):
  ///   SS >= 90% (全 Lv 27+)、S >= 70% (全 Lv 21+)、A >= 50% (全 Lv 15+)、
  ///   B >= 30% (全 Lv 9+)、C >= 15% (全 Lv 5+)、D < 15% (始まりの人)。
  /// 【2026-06-27 v2】kMaxLevel 50 → 30 への変更に伴い、各ランクに必要な Lv 目安も
  /// 自動下方シフト (閾値 % は不変、Lv 換算値だけ docstring を更新)。
  /// 偏った育成 (運動だけ Lv 30 / 他 0) でも平均が低くなりランクが伸びない設計で、
  /// 「6 軸バランス育成」を間接的に促す。
  /// 【2026-07-06 hotfix v3】progressRate を `(level - 1 + EXP/maxExp) /
  /// (kMaxLevel - 1)` に変更 (Lv 1 で 0% 表示) したことに伴い、各ランクの Lv
  /// 目安 (27 / 21 / 15 / 9 / 5) を保持したまま閾値 % を再計算:
  ///   SS 90 / S 69 / A 48 / B 28 / C 14 (旧: 90 / 70 / 50 / 30 / 15)。
  StatRank get overallRank {
    final avg = averageProgressPercent;
    if (avg >= 90) return StatRank.ss;
    if (avg >= 69) return StatRank.s;
    if (avg >= 48) return StatRank.a;
    if (avg >= 28) return StatRank.b;
    if (avg >= 14) return StatRank.c;
    return StatRank.d;
  }
}

/// 【2026-06-27】6 ステータス可視化用の派生値ヘルパー。
///
/// - `cumulativeExp`: Lv 1 から現在 Lv までの「次の Lv に到達するために費やした
///   累計 EXP」+ 現在 Lv の途中 EXP (currentExp)。ユーザーに「成長を感じやすい
///   実数値」として StatHexagonChart / StatSummaryList で表示する。
/// - `progressRate` / `progressPercent`: Lv 30 を 100% とした絶対上限基準の進捗。
///   旧仕様の「stats 内最大 Lv 相対比」を撤回し、各ステータスの MAX 到達度を
///   そのまま表示する設計に切替 (2026-06-27 ユーザー要件)。
///
/// 【2026-06-27 v2】`kMaxLevel` を 50 → 30 に下方修正 (PM 推奨採択)。
/// 根拠 4 軸:
///   1. 戦闘バランス整合 (FEAT-382 連動式) — Lv 50 は クリ 25% / 回避 25% で
///      過剰、Lv 30 で クリ 15% / 回避 15% の適正範囲
///   2. 累計 EXP テーブル現実性 — Lv 50 累計 87,220 EXP は 1 日 1 習慣で
///      約 7.8 年 (事実上到達不可)、Lv 30 累計 31,320 EXP なら約 2.8 年で現実的
///   3. ユーザー体感 % — Lv 6 で Lv 50 基準 12% は「気が遠い」、Lv 30 基準 20%
///      なら「もう 2 割」とサビ哲学「静かな肯定」と整合
///   4. 総合ランク肯定感 — Lv 6 で D ランク (Lv 50 基準) → C ランク
///      (Lv 30 基準) に上がり、初期ユーザーへの肯定感が増す
/// CLAUDE.md「ゲームバランス定数」には Lv 上限は明示されていないが、本値は
/// 上記 4 軸から導出。将来 Backend で max_level が明示された場合は差し替える。
extension CharacterStatComputed on CharacterStat {
  static const int kMaxLevel = 30;

  /// 累計 EXP。`max_exp(k) = k * 70 + 30` (Lv k → k+1 に必要な EXP、CLAUDE.md
  /// `level_to_max_exp` 真実値) を Lv 1 〜 (level-1) まで Σ し、currentExp を足す。
  ///
  /// 例: Lv 5 で currentExp=0 →
  ///   Σ_{k=1}^{4} (k*70 + 30) = (1+2+3+4)*70 + 4*30 = 700 + 120 = 820
  int get cumulativeExp {
    var sum = 0;
    for (var k = 1; k < level; k++) {
      sum += k * 70 + 30;
    }
    return sum + currentExp;
  }

  /// Lv 30 を 100% とした絶対上限ベースの進捗 (0.0〜1.0)。
  /// Lv 30 を超えた場合は 1.0 で clamp。
  ///
  /// 【2026-07-06 hotfix】旧式 `level / kMaxLevel` (= Lv 1 で 3.3% 開始) を
  /// `(level - 1 + currentExp/maxExp) / (kMaxLevel - 1)` に変更。
  /// - Lv 1, currentExp 0 → **0%** (ユーザー期待「開始時は 0%」)
  /// - Lv 1, currentExp 50/100 → 1.7% (EXP 進捗で smooth に増加)
  /// - Lv 30, currentExp 0 → **100%** (両端固定)
  ///
  /// これに合わせて `StatsListExt.overallRank` の閾値も微調整:
  /// SS 90 / S 69 / A 48 / B 28 / C 14 (旧: 90 / 70 / 50 / 30 / 15)
  /// 各 Lv 目安 (Lv 27 / 21 / 15 / 9 / 5) は不変、% 換算値のみ再計算。
  double get progressRate {
    if (kMaxLevel <= 1) return 0.0;
    // 現在 Lv 内での EXP 進捗 (0.0〜1.0)。maxExp=0 は防御的に 0 扱い。
    final withinLevel = maxExp > 0
        ? (currentExp / maxExp).clamp(0.0, 1.0)
        : 0.0;
    // 「有効レベル」= 整数 Lv + 内部 EXP 進捗 (小数付き)
    final effective = level + withinLevel;
    // Lv 1 で 0、Lv 30 で 1 になる線形マッピング
    return ((effective - 1) / (kMaxLevel - 1)).clamp(0.0, 1.0);
  }

  /// `progressRate * 100` の整数値 (0〜100)。
  int get progressPercent => (progressRate * 100).round();
}

// ── キャラクター ───────────────────────────────────────────────
class Character {
  final int id;
  final String key;
  final String name;
  final String role;
  final String description;
  final String imagePath;
  final int price;
  final int unlockLevel;
  final bool isStarter;
  final int order;
  final bool owned;
  final bool active;
  // 【FEAT-430】「キャラ = ジョブ」固定化。キャラの初期ジョブ (修飾子表示用)。
  final Job? job;
  // 【2026-06-27】新キャラ追加機能 (Gemini 要件)。
  // tagline: キャッチコピー (詳細シート / popup で role の下に小さく表示)
  // isNew:   Backend 側で release_date ≤ 今日 + 30 日以内なら true、Mobile 描画ガード用
  final String tagline;
  final bool isNew;

  const Character({
    required this.id,
    required this.key,
    required this.name,
    required this.role,
    required this.description,
    required this.imagePath,
    required this.price,
    required this.unlockLevel,
    required this.isStarter,
    required this.order,
    required this.owned,
    required this.active,
    this.job,
    this.tagline = '',
    this.isNew = false,
  });

  factory Character.fromJson(Map<String, dynamic> j) {
    // P2-07: id 欠落時の防御
    final id = j['id'] as int?;
    if (id == null) {
      throw const FormatException('Character.fromJson: missing id field');
    }
    final jobJson = j['job'] as Map<String, dynamic>?;
    return Character(
      id: id,
      key: j['key'] as String? ?? '',
      name: j['name'] as String? ?? '',
      role: j['role'] as String? ?? '',
      description: j['description'] as String? ?? '',
      imagePath: j['image_path'] as String? ?? '',
      price: j['price'] as int? ?? 0,
      unlockLevel: j['unlock_level'] as int? ?? 1,
      isStarter: j['is_starter'] as bool? ?? false,
      order: j['order'] as int? ?? 0,
      owned: j['owned'] as bool? ?? false,
      active: j['active'] as bool? ?? false,
      job: jobJson != null ? Job.fromJson(jobJson) : null,
      // 【2026-06-27】旧 Backend 互換: tagline/is_new 欠落時は空文字 / false fallback
      tagline: j['tagline'] as String? ?? '',
      isNew: j['is_new'] as bool? ?? false,
    );
  }
}

// ── ショップアイテム ───────────────────────────────────────────
class ShopItem {
  final String id;
  final String name;
  final String category;
  final String emoji;
  final int rarity;
  final int price;
  final int diamondPrice;  // FEAT-129: ダイヤ消費価格（0 = ダイヤ不要）
  final String effect;
  final String itemType;
  final int ownedQuantity;

  /// 【FEAT-429 (2026-06-12)】累進価格アイテム (legendary_slot_expand /
  /// daily_quest_slot_expand) の累計購入回数。対象外アイテムは null。
  final int? purchaseCount;

  /// 【FEAT-429 (2026-06-12)】累進価格アイテムの上限購入回数。対象外アイテムは null。
  final int? maxPurchaseCount;

  /// 【codebase_review 20260704 P3-#8 (2026-07-05)】売却価格 (コイン)。
  /// Backend `_calc_sell_price_coins` が単一真実値。Mobile 側の独自計算
  /// (`item.price ~/ 2`) は撤廃済。売却不可アイテム (ダイヤ購入 / gacha_only /
  /// slot_expansion / streak_protection / consumable) は 0 が返るため、
  /// `sellPrice > 0` で売却可否を判定できる。旧 Backend (未対応版) からの
  /// レスポンスでは field 欠落 → default 0 で「売却不可」扱いになる安全側動作。
  final int sellPrice;

  /// 【FEAT-497 (2026-08-04)】交換ピース価格 (0 = ピースでは買えない)。
  ///
  /// 交換ピースは重複ガチャの救済で貯まる通貨。v1.0 は消費経路がゼロの
  /// dead currency だった。`piecePrice > 0` の item は **ピース専用**で、
  /// `price` / `diamondPrice` はどちらも 0 になる。
  ///
  /// 旧 Backend (未対応版) からは field 欠落 → 0 = 「ピースでは買えない」
  /// 扱いになり、ピースタブが空になるだけで壊れない安全側動作。
  final int piecePrice;

  /// ピース専用アイテムか。UI の通貨表示 / 購入経路の分岐に使う。
  bool get isPieceExchange => piecePrice > 0;

  /// 【BUG-143 (2026-08-07)】この item に **購入手段があるか**。
  ///
  /// 3 通貨 (coin / ダイヤ / 交換ピース) のいずれかに価格が付いていれば購入可能。
  /// すべて 0 なら「買う方法が無い」= ショップの購入リストに出してはいけない。
  ///
  /// ## なぜ必要か
  ///
  /// Backend の `ShopItemsView` は、所持品リストに出すために
  /// **catalog に entry が無い所持武器** (ミスリルの剣 / 竜殺しの剣 /
  /// 見習いの剣) を `price: 0` で動的注入する (2026-07-09)。
  ///
  /// その実装は「Mobile が価格 0 の item を購入モードから除外する」ことを
  /// 前提に書かれていた (shop.py のコメントが本ファイルの行番号を名指ししている)
  /// が、**当時も今もそのロジックは存在しなかった**。実際のフィルタは
  /// `itemType != 'gacha_only'` のみで、注入 entry は `item_type: 'weapon'` の
  /// ため素通りし、**竜殺しの剣が 0 コインでショップに並んでいた**。
  ///
  /// (購入自体は Backend が `_CATALOG_BY_ID` に無い item_id を 404 で弾くため
  ///  成立しない。0 コインで SSR 武器が手に入る抜け穴ではなく、
  ///  「タップするとエラーになる商品が並ぶ」という表示上の不具合だった。)
  ///
  /// ## `gacha_only` フィルタとの関係
  ///
  /// 併用する。`gacha_only` は「ガチャ入手品である」という**意味**の宣言、
  /// 本 getter は「買う手段が無い」という**構造**の判定で、根拠が異なる。
  /// 現在の catalog では前者は後者に含まれるが、将来 gacha_only 品に
  /// ダイヤ価格が付いた場合に両者は分岐する。
  bool get isPurchasable => price > 0 || diamondPrice > 0 || piecePrice > 0;

  const ShopItem({
    required this.id,
    required this.name,
    required this.category,
    required this.emoji,
    required this.rarity,
    required this.price,
    this.diamondPrice = 0,  // FEAT-129
    required this.effect,
    required this.itemType,
    required this.ownedQuantity,
    this.purchaseCount,  // FEAT-429
    this.maxPurchaseCount,  // FEAT-429
    this.sellPrice = 0,  // 2026-07-05 P3-#8
    this.piecePrice = 0,  // 【FEAT-497】
  });

  factory ShopItem.fromJson(Map<String, dynamic> j) {
    // P2-07: id 欠落時の防御
    final id = j['id'] as String?;
    if (id == null) {
      throw const FormatException('ShopItem.fromJson: missing id field');
    }
    return ShopItem(
      id: id,
      name: j['name'] as String? ?? '',
      category: j['category'] as String? ?? '',
      emoji: j['emoji'] as String? ?? '⭐',
      rarity: j['rarity'] as int? ?? 1,
      price: j['price'] as int? ?? 0,
      diamondPrice: j['diamond_price'] as int? ?? 0,  // FEAT-129
      effect: j['effect'] as String? ?? '',
      itemType: j['item_type'] as String? ?? 'consumable',
      ownedQuantity: j['owned_quantity'] as int? ?? 0,
      // 【FEAT-429】累進価格アイテムのみ Backend が返却。対象外は null。
      purchaseCount: j['purchase_count'] as int?,
      maxPurchaseCount: j['max_purchase_count'] as int?,
      // 【2026-07-05 P3-#8】Backend `_calc_sell_price_coins` の値。
      // 未対応 Backend レスポンスでは field 欠落 → 0 (売却不可 fallback)。
      sellPrice: j['sell_price'] as int? ?? 0,
      // 【FEAT-497】未対応 Backend では欠落 → 0 (ピースでは買えない fallback)。
      piecePrice: j['piece_price'] as int? ?? 0,
    );
  }

  String get rarityLabel {
    const map = {1: 'N', 2: 'R', 3: 'SR'};
    return map[rarity] ?? 'N';
  }
}

// ── ガチャ履歴アイテム ─────────────────────────────────────────
class GachaHistoryItem {
  final String rarity;
  final String icon;
  final String name;
  final String detail;
  final String ticketType;

  const GachaHistoryItem({
    required this.rarity,
    required this.icon,
    required this.name,
    required this.detail,
    required this.ticketType,
  });

  factory GachaHistoryItem.fromJson(Map<String, dynamic> j) =>
      GachaHistoryItem(
        rarity: j['rarity'] as String? ?? 'N',
        icon: j['icon'] as String? ?? '⭐',
        name: j['name'] as String? ?? '',
        detail: j['detail'] as String? ?? '',
        ticketType: j['ticket_type'] as String? ?? 'daily',
      );
}

// ── ガチャステータス ───────────────────────────────────────────
class GachaStatus {
  final int dailyTickets;
  final int dailyPity;
  final int weeklyTickets;
  final int weeklyPity;
  final int monthlyTickets;
  final int monthlyPity;
  final int weeklyPct;
  final int weeklyDaysDone;    // 今週の達成日数 (API: weekly_days_done)
  final int monthlyDaysDone;   // 今月の達成日数 (API: monthly_days_done)
  // 【BUG-102 (2026-06-14)】全 SSR キャラ開放済判定。Monthly = SSR 確定ガチャの
  // 「引く」ボタン非活性化に使う (全所持時は dead pieces 救済を避ける UX 配慮)。
  final bool allSsrUnlocked;
  // 【新規 (2026-06-25)】FEAT-433: 当月 21 日達成で SSR 確定チケット +1 配布。
  // 配布済かどうかをガチャ画面 SSR カードに表示するため真実値を Backend から
  // 受け取る。フィールド名は API スネークケース `monthly_ticket_granted_this_month`
  // を Dart 命名規約に合わせて camelCase 化。
  final bool monthlyTicketGrantedThisMonth;
  // 【新規 (2026-06-25)】当週のウィークリーチケット (前週 5 日達成を条件に配布)
  // を既に受け取っているか。Mobile が Weekly カードに「✓ 取得済み」表示と
  // 「今週N日達成 (Y%)」進捗表示を切り替える判定に使う。
  final bool weeklyTicketGrantedThisWeek;
  // 【20260729 user feedback (案 C) 対応】本日の grant で初めて daily/weekly
  // チケットが MAX に到達した瞬間のみ true。gacha_page listener で満タン到達
  // SnackBar (Sabi 口調) の発火 trigger。既に MAX の場合や未到達なら false
  // (Backend 側で MAX-1 → MAX の遷移を厳密検出、SnackBar 過剰発火を防止)。
  final bool dailyTicketJustReachedMax;
  final bool weeklyTicketJustReachedMax;
  final List<GachaHistoryItem> history;

  const GachaStatus({
    required this.dailyTickets,
    required this.dailyPity,
    required this.weeklyTickets,
    required this.weeklyPity,
    required this.monthlyTickets,
    required this.monthlyPity,
    required this.weeklyPct,
    required this.weeklyDaysDone,
    required this.monthlyDaysDone,
    required this.allSsrUnlocked,
    required this.monthlyTicketGrantedThisMonth,
    required this.weeklyTicketGrantedThisWeek,
    required this.dailyTicketJustReachedMax,
    required this.weeklyTicketJustReachedMax,
    required this.history,
  });

  factory GachaStatus.fromJson(Map<String, dynamic> j) => GachaStatus(
        dailyTickets:   j['daily_tickets']    as int? ?? 0,
        dailyPity:      j['daily_pity']       as int? ?? 0,
        weeklyTickets:  j['weekly_tickets']   as int? ?? 0,
        weeklyPity:     j['weekly_pity']      as int? ?? 0,
        monthlyTickets: j['monthly_tickets']  as int? ?? 0,
        monthlyPity:    j['monthly_pity']     as int? ?? 0,
        weeklyPct:      j['weekly_pct']       as int? ?? 0,
        weeklyDaysDone:  j['weekly_days_done']  as int? ?? 0,
        monthlyDaysDone: j['monthly_days_done'] as int? ?? 0,
        allSsrUnlocked:  j['all_ssr_unlocked']  as bool? ?? false,
        // 【新規 (2026-06-25)】default false で古い Backend レスポンスとも互換性維持。
        monthlyTicketGrantedThisMonth:
            j['monthly_ticket_granted_this_month'] as bool? ?? false,
        weeklyTicketGrantedThisWeek:
            j['weekly_ticket_granted_this_week'] as bool? ?? false,
        // 【20260729】default false で新旧 Backend 双方と互換 (旧レスポンスは
        // key 無し → false = SnackBar 出ない、正しい fallback)。
        dailyTicketJustReachedMax:
            j['daily_ticket_just_reached_max'] as bool? ?? false,
        weeklyTicketJustReachedMax:
            j['weekly_ticket_just_reached_max'] as bool? ?? false,
        history: (j['history'] as List<dynamic>?)
                ?.map((e) =>
                    GachaHistoryItem.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
      );
}

// ── ガチャ報酬 ────────────────────────────────────────────────
/// 【2026-06-14】排出キャラ情報 (reward_type='character' のとき backend が
/// レスポンスに含める)。Mobile UI で「キャラ画像 + キャラ名 (SSR)」表示用。
class GrantedCharacterInfo {
  final int id;
  final String name;
  final String imagePath;
  final String role;

  const GrantedCharacterInfo({
    required this.id,
    required this.name,
    required this.imagePath,
    required this.role,
  });

  factory GrantedCharacterInfo.fromJson(Map<String, dynamic> j) =>
      GrantedCharacterInfo(
        id:        j['id']         as int? ?? 0,
        name:      j['name']       as String? ?? '',
        imagePath: j['image_path'] as String? ?? '',
        role:      j['role']       as String? ?? '',
      );
}

class GachaReward {
  final String rarity;
  final String rewardType;
  final String container; // 'chest' | 'stone' (API: container)
  final String name;
  final String detail;
  final String icon;
  /// 月次ガチャで重複キャラクターを引いた場合 true
  final bool isDuplicate;
  /// isDuplicate == true のとき交換待ちレコードの ID
  final int? pendingRewardId;
  /// 【FEAT-427 (2026-06-11)】マンスリー天井到達でキャラ交換券が付与された場合 true
  final bool characterExchangeTicketAwarded;
  /// 【2026-06-14】排出キャラ情報 (reward_type='character' のときのみ非 null)。
  /// Mobile UI で「キャラ画像 + キャラ名 (SSR)」表示に使う。
  final GrantedCharacterInfo? character;

  const GachaReward({
    required this.rarity,
    required this.rewardType,
    required this.container,
    required this.name,
    required this.detail,
    required this.icon,
    this.isDuplicate = false,
    this.pendingRewardId,
    this.characterExchangeTicketAwarded = false,
    this.character,
  });

  factory GachaReward.fromJson(Map<String, dynamic> j) => GachaReward(
        rarity:          j['rarity']            as String? ?? 'N',
        rewardType:      j['reward_type']       as String? ?? 'exp',
        container:       j['container']         as String? ?? 'chest',
        name:            j['name']              as String? ?? '',
        detail:          j['detail']            as String? ?? '',
        icon:            j['icon']              as String? ?? '⭐',
        isDuplicate:     j['is_duplicate']      as bool?   ?? false,
        pendingRewardId: j['pending_reward_id'] as int?,
        characterExchangeTicketAwarded:
            j['character_exchange_ticket_awarded'] as bool? ?? false,
        character: j['character'] is Map<String, dynamic>
            ? GrantedCharacterInfo.fromJson(j['character'] as Map<String, dynamic>)
            : null,
      );
}

// ── 重複ガチャ報酬（交換待ち） ────────────────────────────────
class PendingReward {
  final int id;
  final GachaReward reward;
  final String status;       // 'pending' | 'exchanged' | 'expired'
  final String exchangeType;
  final DateTime expiresAt;
  final DateTime createdAt;

  const PendingReward({
    required this.id,
    required this.reward,
    required this.status,
    required this.exchangeType,
    required this.expiresAt,
    required this.createdAt,
  });

  factory PendingReward.fromJson(Map<String, dynamic> j) {
    // P2-07: id / reward 欠落と日時 parse 失敗で画面が真っ白にならないようにする。
    final id = j['id'] as int?;
    if (id == null) {
      throw const FormatException('PendingReward.fromJson: missing id field');
    }
    final rewardJson = j['reward'] as Map<String, dynamic>?;
    if (rewardJson == null) {
      throw const FormatException('PendingReward.fromJson: missing reward field');
    }
    return PendingReward(
      id:           id,
      reward:       GachaReward.fromJson(rewardJson),
      status:       j['status']        as String? ?? 'pending',
      exchangeType: j['exchange_type'] as String? ?? '',
      // 日時は tryParse + フォールバック（不正データでも画面崩壊を回避）
      expiresAt:    DateTime.tryParse(j['expires_at'] as String? ?? '') ?? DateTime.now(),
      createdAt:    DateTime.tryParse(j['created_at'] as String? ?? '') ?? DateTime.now(),
    );
  }
}

// 【廃止 (2026-06-26)】 称号 6 段階システムは実績 30 件統合で全廃。
// 旧 Title / TitlesData クラス + factory.fromJson + progressRate getter を削除。
// gamification_service.fetchTitles() / TitlesView (Backend) も同時撤去済。

// ── ガチャ排出確率 (FEAT-518) ──────────────────────────────────
// App Store Guideline 3.1.1 対応。Backend が正規化済みの probability (%) を返すため、
// クライアント側で weight から割り算しない (誤表示防止のためサーバー側で完結させている)。

/// 1 件の報酬とその排出確率。
class GachaOddsReward {
  final String name;
  final String detail;
  final String rarity;
  final String rewardType;
  final String icon;

  /// 百分率 (0.0〜100.0)。小数第 2 位まで意味を持つ (例: Weekly キャラ 0.5%)。
  final double probability;

  const GachaOddsReward({
    required this.name,
    required this.detail,
    required this.rarity,
    required this.rewardType,
    required this.icon,
    required this.probability,
  });

  factory GachaOddsReward.fromJson(Map<String, dynamic> j) {
    return GachaOddsReward(
      name: j['name'] as String? ?? '',
      detail: j['detail'] as String? ?? '',
      rarity: j['rarity'] as String? ?? 'N',
      rewardType: j['reward_type'] as String? ?? '',
      icon: j['icon'] as String? ?? '',
      probability: (j['probability'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

/// レアリティ単位の集計。
class GachaOddsRaritySummary {
  final String rarity;
  final double probability;

  const GachaOddsRaritySummary({required this.rarity, required this.probability});

  factory GachaOddsRaritySummary.fromJson(Map<String, dynamic> j) {
    return GachaOddsRaritySummary(
      rarity: j['rarity'] as String? ?? 'N',
      probability: (j['probability'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

/// チケット種別ごとの確率テーブル。
class GachaOddsTicketType {
  final String ticketType;
  final String label;
  final List<GachaOddsRaritySummary> raritySummary;
  final List<GachaOddsReward> rewards;

  const GachaOddsTicketType({
    required this.ticketType,
    required this.label,
    required this.raritySummary,
    required this.rewards,
  });

  factory GachaOddsTicketType.fromJson(Map<String, dynamic> j) {
    return GachaOddsTicketType(
      ticketType: j['ticket_type'] as String? ?? '',
      label: j['label'] as String? ?? '',
      raritySummary: (j['rarity_summary'] as List<dynamic>? ?? [])
          .map((e) => GachaOddsRaritySummary.fromJson(e as Map<String, dynamic>))
          .toList(),
      rewards: (j['rewards'] as List<dynamic>? ?? [])
          .map((e) => GachaOddsReward.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// `/api/gacha/odds/` のレスポンス全体。
class GachaOdds {
  final List<GachaOddsTicketType> ticketTypes;
  final List<String> notes;

  const GachaOdds({required this.ticketTypes, required this.notes});

  factory GachaOdds.fromJson(Map<String, dynamic> j) {
    return GachaOdds(
      ticketTypes: (j['ticket_types'] as List<dynamic>? ?? [])
          .map((e) => GachaOddsTicketType.fromJson(e as Map<String, dynamic>))
          .toList(),
      notes: (j['notes'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
    );
  }
}
