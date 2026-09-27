import '../widgets/combatant_sprite.dart' show SpriteAction;
import 'combatant.dart';
import 'tactic.dart';

/// 【FEAT-385 (2026-05-29)】戦闘ダメージイベント (Floating Damage 数値表示用)。
///
/// `BattleOrchestrator._applyAbility` で攻撃発生時に作成、
/// `BattleState.enemyDamageEvent` / `playerDamageEvent` に設定される。
/// `timestamp` は一意性確保 (連続攻撃で同値ダメージでも別イベントとして
/// FloatingDamageText が ValueKey で再描画されるため)。
class DamageEvent {
  DamageEvent({
    required this.amount,
    required this.isCritical,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  /// ダメージ量 (正の整数)。
  final int amount;

  /// クリティカル判定 (true なら色 + サイズで強調表示)。
  final bool isCritical;

  /// イベント発生時刻 (FloatingDamageText の ValueKey に使用、連続攻撃で
  /// 同値ダメージでも別イベントとして再描画トリガーとなる)。
  final DateTime timestamp;

  @override
  bool operator ==(Object other) =>
      other is DamageEvent &&
      other.amount == amount &&
      other.isCritical == isCritical &&
      other.timestamp == timestamp;

  @override
  int get hashCode => Object.hash(amount, isCritical, timestamp);
}

/// 【新規 (2026-06-26)】必殺技命中イベント (スマブラ撃墜風エフェクト発火用)。
///
/// プレイヤーが ultimate ability で敵にヒットした瞬間、`BattleOrchestrator`
/// が本イベントを作成して [BattleState.ultimateHitEvent] に設定する。UI 側
/// (battle_page) は `ref.listen` で transition (null → non-null) を検知し、
/// 同一フレームで以下を同期発火:
///   - 画面シェイク (横振 ±10 px、減衰)
///   - 白フラッシュ overlay (0→0.6→0、220ms)
///   - 放射状爆発リング (CustomPainter、0→1.5x スケール)
///   - Floating Damage 強化表示 (フォント大 + 黄色)
///   - ハプティクス余韻 (250-350ms `playUltimateHit`)
///   - ヒットストップ (短時間 ATB stop)
///
/// `timestamp` 一意性により連続発火でも別イベント扱い ([DamageEvent] と同設計)。
class UltimateHitEvent {
  UltimateHitEvent({
    required this.damage,
    required this.isCritical,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  /// 与えたダメージ量 (Floating Damage 表示用、UltimateHitEvent 専用)。
  final int damage;

  /// クリティカル判定 (true なら更に強い演出ブースト)。
  final bool isCritical;

  /// イベント発生時刻 (ValueKey で別 widget 扱いにするための一意性)。
  final DateTime timestamp;

  @override
  bool operator ==(Object other) =>
      other is UltimateHitEvent &&
      other.damage == damage &&
      other.isCritical == isCritical &&
      other.timestamp == timestamp;

  @override
  int get hashCode => Object.hash(damage, isCritical, timestamp);
}

/// 【FEAT-526 (2026-08-21)】敵を倒した **最後の一撃** が命中した瞬間のイベント。
///
/// `BattleOrchestrator` が `status = won` を確定させる **同じ `copyWith`** で設定する。
/// UI 側 (battle_page) が `ref.listen` で null → non-null 遷移を検知し、
/// ヒットストップ + ズーム + 暗転 +「K.O.」+ シェイクを同期発火する。
///
/// ## なぜ `BattleStatus` に値を足さないのか
///
/// 出典 (`doc/instructions_from_gemini/KO.md`) は `finalHit` / `hitStop` / `koZoom`
/// といった状態を提案しているが、`BattleStatus.running` を見ているガードは
/// `battle_orchestrator` だけで 6 箇所あり、`battle_provider._finishSent` /
/// `ambient_auto_battle_orchestrator` の終了判定 / backend への finish payload まで
/// 波及する。**KO 演出中かどうかは表示レイヤーの関心事**なので、モデルに足すのは
/// 「いつ killing blow が入ったか」を伝える本イベント 1 つだけにする。
///
/// ## 重複発火が構造的に起きない理由
///
/// 設定箇所は `status = won` と 1 対 1。`status` が一度 `won` になると
/// `running` ガードで以降の tick が入らないので、**1 バトルにつき 1 回しか立たない**。
/// 敗北時 (`lost`) には設定しない ——「決めた」と「やられた」は演出の意味が逆で、
/// 別設計が要る (指示書 決定事項 3)。
class KoEvent {
  KoEvent({
    required this.damage,
    required this.isCritical,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  /// とどめの一撃で与えたダメージ量。
  final int damage;

  /// とどめがクリティカルだったか (演出強度のブースト判定用)。
  final bool isCritical;

  /// イベント発生時刻 ([UltimateHitEvent] / [DamageEvent] と同じ一意性設計)。
  final DateTime timestamp;

  @override
  bool operator ==(Object other) =>
      other is KoEvent &&
      other.damage == damage &&
      other.isCritical == isCritical &&
      other.timestamp == timestamp;

  @override
  int get hashCode => Object.hash(damage, isCritical, timestamp);
}

/// 【FEAT-295 Phase 1a】戦闘状態の immutable スナップショット。
///
/// 設計ノート §4.2。freezed は **使わない**（仕様変更追従コストを下げるため、
/// MVP では手書きの copyWith / equality に留める）。
///
/// `BattleOrchestrator` が tick ごとに `BattleState` を作り直して
/// `BattleStateNotifier.state = newState;` で通知する設計。
class BattleState {
  const BattleState({
    required this.player,
    required this.enemy,
    required this.tactic,
    required this.status,
    required this.logLines,
    this.chargedSpecialCount = 0,
    this.queueUltimate = false,
    this.startedAt,
    this.endedAt,
    this.totalDamageDealt = 0,
    this.totalDamageTaken = 0,
    this.rounds = 0,
    this.enemyBackgroundImagePath = '',
    this.enemyAction = SpriteAction.idle,
    this.playerAction = SpriteAction.idle,
    this.enemyDamageEvent,
    this.playerDamageEvent,
    this.speedMultiplier = 1.0,
    // 【新規 (2026-06-26)】必殺技命中イベント。プレイヤーが ultimate を撃って
    // 敵に当てた瞬間に non-null となり、UI 側で撃墜エフェクト + 強化ハプティクス
    // を同期発火。発火後 ~400ms で _clearUltimateHitEvent() により null に戻る。
    this.ultimateHitEvent,
    // 【FEAT-526】とどめの一撃イベント。`status = won` と同時に non-null になり、
    // **クリアされない** (バトルが終わるまで立ちっぱなし)。
    this.koEvent,
  });

  final Combatant player;
  final Combatant enemy;
  final Tactic tactic;
  final BattleStatus status;
  final List<String> logLines;

  /// 「ゲージ満タン保留」回数（大技解放用）。
  final int chargedSpecialCount;

  /// 【FEAT-301】手動必殺ボタンで「次の ATB 満タンで必殺技を撃つ」キューフラグ。
  /// `tryQueueUltimate()` で true、ultimate 発動時に false にリセット。
  /// Tactic 非依存（press されたら次撃で Resolver を上書きして ultimate）。
  final bool queueUltimate;

  /// 戦闘開始時刻（Backend に duration_sec 送信用）。
  final DateTime? startedAt;
  final DateTime? endedAt;
  final int totalDamageDealt;
  final int totalDamageTaken;
  final int rounds;

  /// 【FEAT-381 (2026-05-29)】戦闘画面背景画像 asset path。
  /// BattleStartResponse.enemyBackgroundImagePath から渡され、battle_page.dart の
  /// Stack 最下層で `Image.asset` 描画。空文字 = 単色フォールバック。
  /// 戦闘終了時の「元に戻す」処理は不要 (Scaffold スコープで完結、Navigator.pop で
  /// 元画面の背景に自動復帰)。
  final String enemyBackgroundImagePath;

  /// 【FEAT-385 (2026-05-29)】敵 sprite の現在 action (攻撃/被弾エフェクト)。
  /// BattleOrchestrator が攻撃発生時に charge → slash → idle、被攻撃時に
  /// recoil → idle へ Timer で遷移させる。default idle = 待機ユラユラ。
  /// 戦闘終了時 (won) は CombatantSprite 側で fadeOut に強制切替されるため、
  /// 本フィールドの状態は維持されたまま fadeOut が表示される。
  final SpriteAction enemyAction;

  /// 【FEAT-385】味方 sprite の現在 action (攻撃/被弾エフェクト)。
  final SpriteAction playerAction;

  /// 【FEAT-385】敵が受けた最新ダメージイベント (Floating Damage 表示用)。
  /// null = まだダメージなし or 表示済みでクリア後。
  /// FloatingDamageText の ValueKey に timestamp を使うことで連続攻撃で
  /// 同値ダメージでも別イベントとして再描画される。
  final DamageEvent? enemyDamageEvent;

  /// 【FEAT-385】味方が受けた最新ダメージイベント (Floating Damage 表示用)。
  final DamageEvent? playerDamageEvent;

  /// 【FEAT-416 (2026-06-01)】現在の倍速乗数 (1.0 / 1.5 / 2.0 / 3.0)。
  /// UI 同期用 — _SpeedChip がこのフィールドを watch して selected 状態を判定する。
  final double speedMultiplier;

  /// 【新規 (2026-06-26)】必殺技命中イベント (撃墜エフェクト発火キー)。
  /// プレイヤー ultimate ヒット時 non-null、~400ms 後に null に戻る。
  /// UI 側 (battle_page) が ref.listen で transition を検知し、ハプティクス +
  /// 画面シェイク + 白フラッシュ + 爆発リング を同一フレームで開始する。
  final UltimateHitEvent? ultimateHitEvent;

  /// 【FEAT-526】とどめの一撃イベント (KO 演出の発火キー)。
  ///
  /// `ultimateHitEvent` と違い **自動クリアしない**。KO は 1 バトルに 1 回きりで、
  /// 次のバトルは新しい `BattleOrchestrator` が新しい `BattleState` を作るため、
  /// クリア用の Timer を持つ必要がない (= 消し忘れ / 消しすぎの事故が起きない)。
  final KoEvent? koEvent;

  BattleState copyWith({
    Combatant? player,
    Combatant? enemy,
    Tactic? tactic,
    BattleStatus? status,
    List<String>? logLines,
    int? chargedSpecialCount,
    bool? queueUltimate,
    DateTime? startedAt,
    DateTime? endedAt,
    int? totalDamageDealt,
    int? totalDamageTaken,
    int? rounds,
    String? enemyBackgroundImagePath,
    SpriteAction? enemyAction,
    SpriteAction? playerAction,
    // 【FEAT-385】damage event は明示 null 化が必要 (表示後クリアのため)。
    // Object? 経由で `null` を「明示的にクリア」と「変更なし」を区別する。
    Object? enemyDamageEvent = _unset,
    Object? playerDamageEvent = _unset,
    double? speedMultiplier,
    // 【新規 (2026-06-26)】撃墜イベントも同様に明示 null 化サポート
    Object? ultimateHitEvent = _unset,
    // 【FEAT-526】koEvent は **_unset センチネルを使わない**。明示 null 化する
    // 用途が無いうえ、`?? this.koEvent` にしておけば「うっかり null を渡して
    // とどめイベントを消す」経路が構造的に存在しなくなる。
    KoEvent? koEvent,
  }) =>
      BattleState(
        player:              player              ?? this.player,
        enemy:               enemy               ?? this.enemy,
        tactic:              tactic              ?? this.tactic,
        status:              status              ?? this.status,
        logLines:            logLines            ?? this.logLines,
        chargedSpecialCount: chargedSpecialCount ?? this.chargedSpecialCount,
        queueUltimate:       queueUltimate       ?? this.queueUltimate,
        startedAt:           startedAt           ?? this.startedAt,
        endedAt:             endedAt             ?? this.endedAt,
        totalDamageDealt:    totalDamageDealt    ?? this.totalDamageDealt,
        totalDamageTaken:    totalDamageTaken    ?? this.totalDamageTaken,
        rounds:              rounds              ?? this.rounds,
        enemyBackgroundImagePath:
            enemyBackgroundImagePath ?? this.enemyBackgroundImagePath,
        enemyAction:         enemyAction         ?? this.enemyAction,
        playerAction:        playerAction        ?? this.playerAction,
        enemyDamageEvent: identical(enemyDamageEvent, _unset)
            ? this.enemyDamageEvent
            : enemyDamageEvent as DamageEvent?,
        playerDamageEvent: identical(playerDamageEvent, _unset)
            ? this.playerDamageEvent
            : playerDamageEvent as DamageEvent?,
        speedMultiplier: speedMultiplier ?? this.speedMultiplier,
        ultimateHitEvent: identical(ultimateHitEvent, _unset)
            ? this.ultimateHitEvent
            : ultimateHitEvent as UltimateHitEvent?,
        koEvent: koEvent ?? this.koEvent,
      );

  /// `duration_sec` 計算（Backend `/battle/finish/` 送信用）。
  int get durationSec {
    if (startedAt == null) return 0;
    final end = endedAt ?? DateTime.now();
    return end.difference(startedAt!).inSeconds;
  }

  /// `summary_text` 生成（Backend `/battle/finish/` 送信 + リプレイ表示用）。
  String get summaryText => logLines.join('\n');
}

/// 【FEAT-385】copyWith で nullable フィールドの「変更なし」と「明示 null」を
/// 区別するためのセンチネル。null != _unset なので、`enemyDamageEvent: null` 渡し
/// で「表示済みクリア」、省略で「既存値維持」が両立する。
const Object _unset = Object();

enum BattleStatus {
  /// 戦闘開始前。
  waiting,

  /// 戦闘中（ATB tick 進行中）。
  running,

  /// 勝利確定（敵 HP 0）。
  won,

  /// 敗北確定（味方 HP 0）。
  lost,

  /// 中断（ユーザー操作）。
  abandoned;
}
