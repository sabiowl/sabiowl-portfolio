import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';  // 【FEAT-416】倍速永続化

import '../../../core/analytics/posthog_service.dart';  // 【FEAT-511 Phase A】
import '../../../core/api/api_client.dart';
import '../../../core/services/toast_center.dart';  // 【gameplay_review 20260803 §2-2 b】
import '../../gamification/models/gamification_models.dart' show CharacterStat;  // FEAT-333
import '../../gamification/providers/gamification_provider.dart' show statsNotifierProvider;  // FEAT-333
import '../../habits/providers/habits_provider.dart' show playerNotifierProvider;
// 【FEAT-295 hotfix 2026-05-25】戦闘終了後の Player + SWR キャッシュ即時 invalidate 用
import '../../habits/providers/home_bootstrap_provider.dart'
    show homeBootstrapRawProvider, homeIsLiveProvider;
import '../../puzzle_world/models/puzzle_world.dart' show PuzzlePieceColored;  // 【FEAT-479】
import '../../puzzle_world/providers/puzzle_world_provider.dart' show puzzlePieceColoredProvider;  // 【FEAT-479】
import '../constants/battle_constants.dart';
import '../models/battle_log_entry.dart';  // FEAT-305
import '../models/battle_state.dart';
import '../models/combatant.dart';
import '../models/enemy.dart';  // FEAT-296
import '../models/job.dart';    // FEAT-299
import '../models/tactic.dart';
import '../services/ambient_auto_battle_preferences.dart';  // 【FEAT-528】
import '../services/battle_orchestrator.dart';
import '../services/battle_service.dart';
import '../../../core/l10n/service_l10n.dart';  // 【FEAT-489 Phase 2F-a】
// 【FEAT-513 v1.1 hotfix 2 follow-up (2026-07-31)】旧 headless_battle_runner import
// (FEAT-505) は runSkipBattle 撤去に伴い削除済 (Skip Mode は battle 画面速度選択
// 5 番目 ⏭ = 50x tick 速度に統合、FEAT-505 §2.1 原仕様復元)。

/// 【FEAT-295 Phase 1d】バトル関連の Riverpod プロバイダー群。

/// BattleService DI。
final battleServiceProvider = Provider<BattleService>((ref) {
  return BattleService(ref.watch(apiClientProvider));
});

// 【FEAT-513 v1.1 hotfix 2 follow-up (2026-07-31)】旧 skipModeProvider (FEAT-505、
// Guild toggle 用) は撤去済。Skip は battle 画面速度選択 5 番目 (⏭) に統合されて
// bool state 保持は不要になった (battle_page 内で ephemeral 選択)。

/// 【FEAT-513】Ambient Auto Battle の有効/無効状態。
///
/// GuildPage.initState で SharedPreferences から読み込まれる。
/// Toggle 時は AmbientAutoBattlePreferences.setEnabled() で永続化する。
final ambientAutoBattleEnabledProvider = StateProvider<bool>((ref) => false);

/// 【FEAT-528 (2026-08-22)】オートバトルの ON/OFF を切り替える唯一の入口。
///
/// 🔴 **バーとモーダルの 2 箇所から呼ぶので、処理をコピーしない。**
/// この関数は 3 つのことを同時にやる:
///   1. `ambientAutoBattleEnabledProvider` の更新（描画の真実値）
///   2. `SharedPreferences` への永続化（orchestrator 発火の真実値）
///   3. PostHog `ambient_battle_toggled` の送信
///
/// コピペして 2 箇所に分けると、**片方だけ直したときにもう片方が古くなる**。
/// 特に 3 の計測が「バーからの toggle だけ」になっても、数字が減ったことに
/// 誰も気付けない（FEAT-528 Pre-mortem #6）。
Future<void> setAmbientAutoBattleEnabled(WidgetRef ref, bool value) async {
  ref.read(ambientAutoBattleEnabledProvider.notifier).state = value;
  final prefs = await SharedPreferences.getInstance();
  await AmbientAutoBattlePreferences.setEnabled(prefs, value);
  PosthogService.instance.capture(
    'ambient_battle_toggled',
    properties: {'enabled': value},
  );
}

/// 【FEAT-528 (2026-08-22)】バトル速度の永続設定（1.0 / 1.5 / 2.0 / 3.0 / 50.0 = ⏭）。
///
/// ## 🔴 `battle_speed_multiplier` への書き込みはここに一本化する
///
/// 直接 `prefs.setDouble('battle_speed_multiplier', ...)` を書くと、
/// **BUG-79 と同型の「二重の真実値」に戻る** —— FEAT-416 の hotfix で実際に
/// 「`_SpeedChip` は 1x をハイライトしているのに実速度は 3x」というユーザー報告が
/// 出ている。書き手が 2 つある限り、どちらかが片方を更新し忘れる。
/// `test/battle/battle_settings_dialog_test.dart` の D-1 がソース走査で縛っている。
///
/// ## なぜ自分でロードするのか
///
/// `ambientAutoBattleEnabledProvider` は `_GuildPageState.initState` から
/// 流し込まれる形で、**ギルド画面を開くまで既定値のまま**になる
/// （実際に gameplay_review 20260803 §2-1 の事故を起こしている）。
/// 同じ形にすると、モーダルを他画面に置いた瞬間に同じ穴が開く
/// （FEAT-528 Pre-mortem #3）。だからホスト画面に依存せず自分で読む。
///
/// ⚠️ オートバトル側の既存の形は本 FEAT の範囲外として据え置いた。
/// **モーダルをギルド以外の画面に置くときは、必ず一緒に直すこと。**
class BattleSpeedPreferenceNotifier extends StateNotifier<double> {
  BattleSpeedPreferenceNotifier() : super(1.0) {
    _load();
  }

  /// SharedPreferences のキー。`startBattle` の読み出し側と同じ文字列。
  static const String prefsKey = 'battle_speed_multiplier';

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getDouble(prefsKey);
      if (saved != null && mounted) state = saved;
    } catch (_) {
      // テスト環境 / 初回起動でプラグイン未初期化 → 既定 1.0 のまま継続。
      // `startBattle` の復元側と同じ握り方にしておく。
    }
  }

  /// 速度を変更して永続化する。
  Future<void> setSpeed(double value) async {
    state = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(prefsKey, value);
    } catch (_) {
      // 永続化に失敗しても in-memory の state は更新済（今回の戦闘には効く）。
    }
  }
}

/// 【FEAT-528】非 autoDispose。画面をまたいで保持する設定なので破棄しない。
final battleSpeedPreferenceProvider =
    StateNotifierProvider<BattleSpeedPreferenceNotifier, double>(
  (ref) => BattleSpeedPreferenceNotifier(),
);

/// 【FEAT-305】直近 N 件の BattleLog 一覧。リリア（ギルド受付）の状態判定で
/// 「直近 5 分以内勝敗」「連戦判定」に使用。
///
/// `autoDispose.family` の引数 `limit` で取得件数指定（default 10）。
/// 失敗時は空リスト返却（サイレントフォールバック、ギルド画面 receptionview が
/// 崩れない）。ギルド画面入場時に毎回 fetch（autoDispose で離脱時に破棄）。
final recentBattlesProvider =
    FutureProvider.autoDispose.family<List<BattleLogEntry>, int>(
  (ref, limit) async {
    return ref.read(battleServiceProvider).fetchBattleLogs(limit: limit);
  },
);

/// 【FEAT-296】Enemy 一覧（ギルド画面で使用）。
///
/// `tier` 引数:
///   - `null`   → 全 Enemy（goblin + 4 ボス）
///   - `'zako'` → 雑魚種のみ
///   - `'boss'` → ボス種のみ
///
/// Backend は 5 分キャッシュ、Flutter 側は `family` の自動 dispose で
/// メモリ管理（Pre-mortem #2 対応）。
final enemyListProvider =
    FutureProvider.autoDispose.family<List<EnemyMaster>, String?>(
  (ref, tier) async {
    return ref.read(battleServiceProvider).fetchEnemyList(tier: tier);
  },
);

// ─────────────────────────────────────────────────────────────
// BattleAvailability: ホームウィジェットの「出陣可能か」表示用
// ─────────────────────────────────────────────────────────────

/// バトル可否のスナップショット（ホームウィジェットで watch）。
class BattleAvailability {
  const BattleAvailability({
    required this.charges,
    required this.canBattle,
    required this.label,
    required this.description,
    this.dailyBattleCount = 0,       // 【FEAT-398】
    this.dailyBattleLimitReached = false,  // 【FEAT-398】
    this.dailyBattleLimit = 10,      // 【FEAT-429】
  });

  /// 【FEAT-311 / FEAT-406 / FEAT-410】Backend 値そのまま (0-30、clamp なし)。
  /// FEAT-406 で chargesPerBattle=3 + 日次リセット導入、3 達成 = 1 戦参加可能。
  /// FEAT-410 で maxBattleCharges を 3 → 30 に拡大 (= 10 戦分ストック、daily 上限と整合)。
  /// 最大 10 戦ストック (= 30 達成で満タン)、stockCount = charges // 3 (0-10)。
  final int charges;
  final bool canBattle;
  final String label;
  final String description;

  /// 【FEAT-398 (2026-05-31)】本日の出陣回数 (0-10)。
  /// 10 到達で `dailyBattleLimitReached=true` → バッジ 🔒 表示。
  final int dailyBattleCount;

  /// 【FEAT-398】本日の出陣上限 (10 回) に到達しているか。
  /// True なら charges がいくつあっても出陣不可 (Backend が 403 を返す)。
  final bool dailyBattleLimitReached;

  /// 【FEAT-429 (2026-06-12)】本日の出陣上限 (10 + dailyBattleLimitBonus)。
  /// Shop でクエスト枠拡張を購入すると 11-15 に増加する。
  final int dailyBattleLimit;

  /// 【FEAT-311 / FEAT-403】参加可能回数のストック数。
  /// FEAT-403 で `chargesPerBattle=1` のため stockCount = charges (0-10)。
  int get stockCount => charges ~/ BattleConstants.chargesPerBattle;

  /// 【FEAT-311 / FEAT-406 / FEAT-409】ホームバッジ表示用ラベル。
  ///
  /// 【FEAT-409 (2026-06-01)】「達成 N/3 → 次戦」表記を撤廃 (文字量過多)。
  /// バッジは「戦える時のアクション促進」に純化、charges < 3 では `shouldShowBadge=false`
  /// で Badge 自体非表示にする (進捗確認はギルド画面の subtext 経由)。
  ///
  /// 表示パターン:
  /// - dailyBattleLimitReached=true → `'🔒'` (日次上限到達)
  /// - charges >= chargesPerBattle   → `'✓×$stockCount'` (例: '✓×1', '✓×2', '✓×3')
  /// - それ以外                      → `''` (空文字、Badge.isLabelVisible で非表示制御)
  String get badgeLabel {
    if (dailyBattleLimitReached) return '🔒';
    if (charges >= BattleConstants.chargesPerBattle) {
      return '✓×$stockCount';
    }
    return '';  // 【FEAT-409】文字量削減のため空文字、shouldShowBadge=false で非表示
  }

  /// 【FEAT-409 (2026-06-01)】Badge widget の `isLabelVisible` 制御用。
  /// 戦える状態 (charges >= chargesPerBattle) または日次上限到達時のみ true。
  /// charges < 3 (=戦えない、達成途中) では false でバッジ自体を非表示にし、
  /// BottomNav の視覚ノイズを削減する (ユーザー要望 2026-06-01)。
  bool get shouldShowBadge =>
      dailyBattleLimitReached || charges >= BattleConstants.chargesPerBattle;

  // 【FEAT-489 Phase 2F-a】旧 `get tooltipText` (日本語 hardcode 4 行) を削除。
  // FEAT-406 で盾バッジの long press 用に追加されたが、その後 FEAT-409 で
  // バッジ表示が「✓×3 / 🔒」に簡素化された際に参照が外れ、以降 dead code
  // だった (呼び出し元 0 件)。復活させる場合は ARB 化してから。

  /// 【FEAT-489 Phase 2F-a】文言が locale 依存になったため `const` → getter 化。
  /// BuildContext を持たない provider 層なので [ServiceL10n] 経由で解決する。
  static BattleAvailability get empty => BattleAvailability(
        charges: 0,
        canBattle: false,
        label: ServiceL10n.current.battleAvailabilityLabelEmpty,
        description:
            ServiceL10n.current.battleAvailabilityDescriptionNeedMoreSabi_message,
      );
}

/// `playerNotifierProvider` を watch して、`battleCharges` から
/// `BattleAvailability` を導出する派生プロバイダー。
final battleAvailabilityProvider = Provider<BattleAvailability>((ref) {
  // 【FEAT-489 Phase 2F-a】BuildContext を持たない provider なので ServiceL10n 経由。
  final l10n = ServiceL10n.current;
  final playerAsync = ref.watch(playerNotifierProvider);
  final player = playerAsync.valueOrNull;
  if (player == null) return BattleAvailability.empty;

  final charges = player.battleCharges;
  final dailyBattleCount = player.dailyBattleCount;  // 【FEAT-398】
  // 【FEAT-398 + FEAT-429】日次出陣上限到達 (10 + bonus 回) → charges がいくつあっても出陣不可
  final dailyBattleLimit = 10 + player.dailyBattleLimitBonus;
  final dailyLimitReached = dailyBattleCount >= dailyBattleLimit;

  final canBattleByCharges = charges >= BattleConstants.chargesPerBattle;
  // 【FEAT-398】canBattle は charges AND 日次上限両方を満たす場合のみ True
  final canBattle = canBattleByCharges && !dailyLimitReached;

  if (dailyLimitReached) {
    return BattleAvailability(
      charges:               charges,
      canBattle:             false,
      label: l10n.battleAvailabilityLabelDailyLimit(
          dailyBattleCount, dailyBattleLimit),
      description:
          l10n.battleAvailabilityDescriptionDailyLimitSabi_message,
      dailyBattleCount:      dailyBattleCount,
      dailyBattleLimitReached: true,
      dailyBattleLimit:      dailyBattleLimit,
    );
  } else if (canBattle) {
    // 【FEAT-406】chargesPerBattle=3, clamp なし 0-3。
    final stockCount = charges ~/ BattleConstants.chargesPerBattle;
    return BattleAvailability(
      charges:     charges,
      canBattle:   true,
      label: stockCount > 1
          ? l10n.battleAvailabilityLabelReadyWithStock(stockCount)
          : l10n.battleAvailabilityLabelReadySabi_message,
      description: l10n.battleAvailabilityDescriptionReadySabi_message,
      dailyBattleCount: dailyBattleCount,
      dailyBattleLimit: dailyBattleLimit,
    );
  } else {
    // 【FEAT-406】chargesPerBattle=3 のため remaining = 3 - charges。
    final remaining = BattleConstants.chargesPerBattle - charges;
    return BattleAvailability(
      charges:     charges,
      canBattle:   false,
      label: l10n.battleAvailabilityLabelNeedMore(remaining),
      description:
          l10n.battleAvailabilityDescriptionNeedMoreSabi_message,
      dailyBattleCount: dailyBattleCount,
      dailyBattleLimit: dailyBattleLimit,
    );
  }
});

// ─────────────────────────────────────────────────────────────
// BattleSession: 全画面 BattlePage で listen する戦闘状態
// ─────────────────────────────────────────────────────────────

/// 戦闘セッション state（BattlePage / MiniBattleArena で listen）。
class BattleSession {
  const BattleSession({
    this.state,
    this.token,
    this.rewardCoinsGained = 0,
    this.rewardExpGained = 0,
    this.leveledUp = false,
    this.newLevel,
    this.errorMessage,
    // 【FEAT-296 hotfix 2026-05-24】_sendFinish API 応答完了フラグ。
    // battle_page.dart の listen は status == won/lost に加えて本フラグが
    // true になるのを待ってからモーダル発火する（rewardCoinsGained = 0
    // のまま表示するバグの根本対策）。catch 経路でも true に設定する
    // ことで Backend 失敗時もモーダルは表示される（UX 途切れ防止）。
    this.finishCompleted = false,
    // 【FEAT-297 Pre-mortem #3】モーダル発火重複防止フラグ。
    // BattlePage と WorldFrameSection (経由のホーム画面) どちらが先に
    // モーダルを出しても、後発はスキップする設計。
    // 最初に発火した listener が `markModalShown()` で true に設定する。
    this.modalShown = false,
    // 【FEAT-298】回復薬関連の state。
    // potionsPlanned: 戦闘開始前の使用予定数 (0-3)
    // potionsUsed:    戦闘中に実際に消費した数（PotionCountIndicator の表示用）
    this.potionsPlanned = 0,
    this.potionsUsed = 0,
    // 【FEAT-314】その日初の勝利で +5 ダイヤが付与されたか（ToastCenter 発火キー）。
    this.battleFirstDiamond = false,
    // 【FEAT-315】最後の勝利確定時刻（リリア吹き出しパネル発火キー）。
    // ホーム画面の ref.listen が 5 秒以内の変化を検出して LiliaFloatingPanel を出す。
    this.lastVictoryAt,
    // 【FEAT-443 (2026-06-20)】バトル勝利時 10% 確率の木製武器ドロップ情報。
    // null = ドロップなし、non-null = battle_page で SnackBar 発火キー。
    this.weaponDropped,
    // 【FEAT-511 Phase A (2026-07-30)】ジョブ熟練度 Max 到達時のジョブ名。
    // null = Max 未到達、non-null = battle_page で MaxedDialog 発火キー。
    this.jobMasteryMaxedJobName,
  });

  final BattleState? state;
  final String? token;
  final int rewardCoinsGained;
  final int rewardExpGained;
  final bool leveledUp;
  final int? newLevel;
  final String? errorMessage;
  /// 【FEAT-296 hotfix】_sendFinish の API 応答完了を示すフラグ。
  /// battle_page.dart の listen がモーダル発火条件として参照する。
  final bool finishCompleted;
  /// 【FEAT-297 Pre-mortem #3】モーダル発火済みフラグ（二重発火防止）。
  /// 最初に listen した側が `markModalShown()` で true に設定する。
  final bool modalShown;
  /// 【FEAT-298】戦闘開始前に申告した回復薬使用予定数 (0-3)。
  final int potionsPlanned;
  /// 【FEAT-298】戦闘中に実際に消費した回復薬数（PotionCountIndicator で参照）。
  final int potionsUsed;
  /// 【FEAT-314】その日初の勝利で +5 ダイヤが付与された場合 true。
  /// battle_page の listen がモーダル発火後に ToastCenter で「+5💎」を表示する。
  final bool battleFirstDiamond;

  /// 【FEAT-315】最後の勝利確定時刻。`_sendFinish` で `result == 'win'` の時のみ更新。
  /// ホーム画面の `ref.listen` が「直近 5 秒以内に変化」を検出して
  /// `LiliaFloatingPanel.show()` を呼び、リリアの勝利祝福セリフを下部に出す。
  /// startBattle 時に既定で null リセット（次バトル分の発火準備）。
  final DateTime? lastVictoryAt;

  /// 【FEAT-443 (2026-06-20)】バトル勝利時 10% 確率の木製武器ドロップ情報。
  /// battle_page の _handleBattleEnd がモーダル後に SnackBar 発火。
  final BattleWeaponDrop? weaponDropped;

  /// 【FEAT-511 Phase A (2026-07-30)】ジョブ熟練度 Max 到達時のジョブ名。
  /// null = Max 未到達、non-null = battle_page の _handleBattleEnd が MaxedDialog を発火。
  final String? jobMasteryMaxedJobName;

  /// 残数（plan - used）。UI 表示用ヘルパー。
  int get potionsRemaining => potionsPlanned - potionsUsed;

  BattleSession copyWith({
    BattleState? state,
    String? token,
    int? rewardCoinsGained,
    int? rewardExpGained,
    bool? leveledUp,
    int? newLevel,
    String? errorMessage,
    bool? finishCompleted,
    bool? modalShown,
    int? potionsPlanned,
    int? potionsUsed,
    bool? battleFirstDiamond,
    DateTime? lastVictoryAt,
    BattleWeaponDrop? weaponDropped,
    String? jobMasteryMaxedJobName,
    bool clearError = false,
  }) =>
      BattleSession(
        state:              state              ?? this.state,
        token:              token              ?? this.token,
        rewardCoinsGained:  rewardCoinsGained  ?? this.rewardCoinsGained,
        rewardExpGained:    rewardExpGained    ?? this.rewardExpGained,
        leveledUp:          leveledUp          ?? this.leveledUp,
        newLevel:           newLevel           ?? this.newLevel,
        errorMessage:       clearError ? null : (errorMessage ?? this.errorMessage),
        finishCompleted:    finishCompleted    ?? this.finishCompleted,
        modalShown:         modalShown         ?? this.modalShown,
        potionsPlanned:     potionsPlanned     ?? this.potionsPlanned,
        potionsUsed:        potionsUsed        ?? this.potionsUsed,
        battleFirstDiamond: battleFirstDiamond ?? this.battleFirstDiamond,
        // 【FEAT-315】 lastVictoryAt は明示渡されたら更新、null 渡しはそのまま保持
        // （`clearError` パターンと同じく "明示リセット" 要件は startBattle 側で
        //  `const BattleSession()` ベース再構築で対応するため copyWith では維持）。
        lastVictoryAt:      lastVictoryAt      ?? this.lastVictoryAt,
        // 【FEAT-443】lastVictoryAt と同じく明示渡しのみ更新 (null 渡し = 保持)。
        weaponDropped:      weaponDropped      ?? this.weaponDropped,
        // 【FEAT-511 Phase A】Max 到達時のみ非 null (null 渡し = 保持)。
        jobMasteryMaxedJobName: jobMasteryMaxedJobName ?? this.jobMasteryMaxedJobName,
      );
}

/// 戦闘セッションを管理する StateNotifier。
///
/// `BattlePage.initState` から `startBattle()` を呼び、戦闘終了時（won/lost）に
/// 自動で `finishBattle()` を発火 → Backend に結果送信 + 報酬反映。
class BattleSessionNotifier extends StateNotifier<BattleSession> {
  BattleSessionNotifier(this._ref) : super(const BattleSession());

  final Ref _ref;
  BattleOrchestrator? _orchestrator;
  bool _finishSent = false;

  /// 【FEAT-531 (2026-08-29)】直近に開始したバトルの計測メタ。
  ///
  /// `battle_started` と `battle_finished` を **同じ 1 戦として突き合わせる**ために
  /// 開始時の値をここへ持ち越す。`_sendFinish` は `startBattle` が作った
  /// orchestrator 経由でしか到達しないので、両方とも必ず設定済みになる。
  ///
  /// 🔴 **`entry` の判定はここに入れる 1 箇所だけ。** FEAT-529 の `ambient`
  /// フラグをそのまま流す。別途「額縁かどうか」を判定し直すと、片方だけ直した
  /// ときに **ダッシュボードの手動 / 自動の比率が静かに狂う** —— 数字が
  /// おかしいことに誰も気付けない種類の壊れ方になる (FEAT-531 Pre-mortem #2)。
  String _lastBattleEntry = '';
  String _lastBattleEnemyKey = '';

  /// 【FEAT-296】開始する敵の識別子（次回 `BattlePage.initState` or WorldFrameSection 経由
  /// での startBattle 用）。ギルド画面の `_onJoin(enemy)` → `selectEnemyForNextBattle(enemy.key)`
  /// → 【FEAT-297】context.go(/home) → WorldFrameSection が pending 検出 → startBattle
  /// の流れで使う。null なら default ゴブリン（BattleWidget 既存経路）。
  String? _pendingEnemyKey;

  /// 【FEAT-298】戦闘開始前 BottomSheet で選択された回復薬使用予定数 (0-3)。
  int _pendingPotionsToUse = 0;
  /// 【FEAT-376】上位回復薬・攻撃の薬の使用予定数。
  int _pendingPotionsPlusToUse   = 0;
  int _pendingAttackPotionsToUse = 0;
  /// 【FEAT-432】防御の薬の使用予定数、攻撃の薬と完全対称。
  int _pendingDefensePotionsToUse = 0;

  /// 【FEAT-297】WorldFrameSection が「pending 検出 → 自動 startBattle」判定に使う。
  /// 既存セッション進行中 (`hasActiveSession == true`) なら pending は触らない設計。
  String? get pendingEnemyKey => _pendingEnemyKey;

  /// 【FEAT-297】既存セッションが進行中か（_orchestrator が生きているか）。
  /// 注: 終了済（won/lost）でも `_orchestrator` は dispose されず残存する設計
  /// （FEAT-296 で autoDispose 外し、reward 表示や victory listener が state を
  /// 参照し続けるため）。
  /// このため「running 中かどうか」の判定には [isBattleRunning] を使うこと。
  bool get hasActiveSession => _orchestrator != null;

  /// 【FEAT-325 (2026-05-27) 】戦闘が現在 running 中か（won/lost は false）。
  ///
  /// **バグ修正**: WorldFrameSection の自動 startBattle 発火条件で旧
  /// `!hasActiveSession` を使っていたが、`_orchestrator` は終了済 (won/lost) でも
  /// dispose されず残存するため、2 戦目以降「終了済 orchestrator が残存 →
  /// hasActiveSession=true → !hasActiveSession=false → startBattle 発火しない」
  /// で戦闘が開始されないバグ発生。`isBattleRunning` を新規追加し、status==running
  /// のみ true を返すことで「終了済を新規開始の障害物にしない」契約を担保。
  /// startBattle() は内部で「終了済なら破棄して新規開始」ロジック完備のため、
  /// running でなければ呼んで OK。
  bool get isBattleRunning =>
      _orchestrator != null &&
      _orchestrator!.state.value.status == BattleStatus.running;

  /// ギルド画面 → ホーム遷移 → ワールドフレーム自動 startBattle の橋渡し。
  /// 値は次回 `startBattle()` で消費され、消費後は null にリセットされる。
  void selectEnemyForNextBattle(String enemyKey) {
    _pendingEnemyKey = enemyKey;
  }

  /// 【FEAT-298】次回戦闘で使用する回復薬数を予約する (BottomSheet → ホーム経路)。
  /// `enemyKey` 同様、`startBattle()` で消費 → 0 リセット。
  /// 0-`RecoveryPotion.maxPerBattle` 範囲外は clamp する（呼び出し側でも事前チェック想定）。
  void setPendingPotionsToUse(int count) {
    _pendingPotionsToUse = count.clamp(0, 3);
  }

  /// 【FEAT-376】新規ポーション種別の事前設定。
  void setPendingPotionsPlusToUse(int count) {
    _pendingPotionsPlusToUse = count.clamp(0, 3);
  }

  void setPendingAttackPotionsToUse(int count) {
    _pendingAttackPotionsToUse = count.clamp(0, 3);
  }

  /// 【FEAT-432】防御の薬の事前設定。攻撃の薬と完全対称。
  void setPendingDefensePotionsToUse(int count) {
    _pendingDefensePotionsToUse = count.clamp(0, 3);
  }

  /// 【FEAT-298】次回戦闘で使用予約された回復薬数（読み取り専用、テスト用）。
  int get pendingPotionsToUse => _pendingPotionsToUse;

  /// `BattlePage.initState` で呼ぶ。Backend に開始通知 → orchestrator 起動。
  ///
  /// `enemyKey` が明示指定されればそれを使い、null なら `_pendingEnemyKey`
  /// （ギルド画面経由で先にセット済み）を使い、それも null なら Backend が
  /// default ゴブリンを返す（後方互換、Pre-mortem #3）。
  ///
  /// 【FEAT-529】`ambient` はホーム額縁のアンビエントバトルからの呼び出しを表す。
  /// `true` のとき倍速の**実効値だけ** [BattleConstants.ambientMaxSpeedMultiplier]
  /// で頭打ちにする（Skip を額縁に持ち込まないため）。既定値は必ず `false` ——
  /// ここを `true` にすると Skip 機能そのものが壊れる（Pre-mortem #2）。
  Future<void> startBattle({String? enemyKey, bool ambient = false}) async {
    // 【FEAT-297 hotfix 2026-05-24】戦闘終了済（won/lost）なら _orchestrator を
    // 破棄してリセット → 新規セッション開始を許可する。running 中の二重開始のみ防ぐ。
    // 旧実装は `_orchestrator != null` で常に早期 return していたため、
    // 1 戦目敗北 → 習慣積み直し → 2 戦目開始時に「画面に描写されない」バグ発生。
    if (_orchestrator != null) {
      final currentStatus = _orchestrator!.state.value.status;
      if (currentStatus == BattleStatus.running) {
        return; // 進行中の二重開始防止（既存挙動）
      }
      // 終了済（won/lost）: 既存 orchestrator を破棄して新規セッション準備
      _orchestrator!.state.removeListener(_onOrchestratorUpdate);
      _orchestrator!.dispose();
      _orchestrator = null;
    }
    _finishSent = false;
    try {
      final svc = _ref.read(battleServiceProvider);
      // 優先順位: 引数 > selectEnemyForNextBattle 値 > null (default goblin)
      final effectiveKey = enemyKey ?? _pendingEnemyKey;
      _pendingEnemyKey = null; // 消費
      // 【FEAT-298 + FEAT-376 + FEAT-432】ポーション使用予定数を消費。
      final potionsToUse        = _pendingPotionsToUse;
      final potionsPlusToUse    = _pendingPotionsPlusToUse;
      final attackPotionsToUse  = _pendingAttackPotionsToUse;
      final defensePotionsToUse = _pendingDefensePotionsToUse;
      _pendingPotionsToUse        = 0;
      _pendingPotionsPlusToUse    = 0;
      _pendingAttackPotionsToUse  = 0;
      _pendingDefensePotionsToUse = 0;
      final start = await svc.startBattle(
        enemyKey:            effectiveKey,
        potionsToUse:        potionsToUse,
        potionsPlusToUse:    potionsPlusToUse,
        attackPotionsToUse:  attackPotionsToUse,
        defensePotionsToUse: defensePotionsToUse,
      );

      // 【FEAT-416 (2026-06-01)】SharedPreferences から倍速設定を復元 (Pre-mortem S2)。
      // svc.startBattle 後に取得することでテスト環境でのプラグイン未初期化問題を回避。
      // 取得失敗時は default 1.0 のまま継続（戦闘開始を妨げない）。
      double savedSpeed = 1.0;
      try {
        final prefs = await SharedPreferences.getInstance();
        savedSpeed = prefs.getDouble('battle_speed_multiplier') ?? 1.0;
      } catch (_) {
        // プリファレンス取得失敗 (test 環境 / 初回起動) → default 1.0 を使用
      }

      // 【FEAT-529 (2026-08-22)】額縁は Skip (50x) を持ち込まない。
      // FEAT-527 の攻撃モーションは 400ms 固定で倍速に追従しないため、
      // Skip のままだと戦闘のほうが先に終わり、モーションが一度も見えない。
      //
      // 🔴 clamp するのは savedSpeed（このバトルでの実効値）だけで、
      // **prefs は書き換えない**。書き戻すと、額縁バトルが 1 回走っただけで
      // バトル画面の Skip 設定が勝手に 3x に落ちる（ユーザーには「設定が
      // いつの間にか消えた」に見え、ホームに戻っただけなので操作と結び付かない）。
      if (ambient && savedSpeed > BattleConstants.ambientMaxSpeedMultiplier) {
        savedSpeed = BattleConstants.ambientMaxSpeedMultiplier;
      }

      // 【FEAT-531】バトル本流の開始を計測する。
      //
      // ここまで来ていれば Backend の出陣は成立している (charges 消費 / 日次上限の
      // 判定は `svc.startBattle` の中)。**上限で弾かれた回は started に数えない。**
      //
      // 🔵 `ambient_battle_started` (FEAT-513) とは**粒度が違う** ——
      // あちらは連戦ループ 1 run の開始で、こちらは 1 戦ごと。両立する。
      //
      // 🔴 送るのは **key だけ**。`enemy_name` のような表示名を足すと
      // ロケール依存の文字列が入り、集計が ja / en で割れる (Pre-mortem #5)。
      _lastBattleEntry = ambient ? 'ambient' : 'manual';
      _lastBattleEnemyKey = start.enemyKey;
      PosthogService.instance.capture('battle_started', properties: {
        'enemy_key':        _lastBattleEnemyKey,
        'entry':            _lastBattleEntry,
        'speed_multiplier': savedSpeed,
      });

      // 【FEAT-299】Backend `player_job` をプレイヤー Combatant に反映する。
      // null（古い Backend / 異常状態）の場合は `Job.fallback`（既存挙動互換）。
      final playerCombatant = _buildPlayerCombatant(
        job: start.playerJob ?? Job.fallback,
      );
      final enemyCombatant = Combatant(
        id:        'enemy_${start.enemyKey}',
        name:      start.enemyName,
        spriteKey: start.enemySpriteKey,
        maxHp:     start.enemyHp,
        currentHp: start.enemyHp,
        atk:       start.enemyAtk,
        spd:       start.enemySpd,
        // 敵にはジョブを与えない（MVP では敵の通常攻撃のみで modifier 不要）。
        // 【FEAT-302】弱点 / 耐性を Combatant に反映 → BattleOrchestrator が
        // attacker.jobName で physical/magical 判定して resistance 乗算。
        physicalResistance: start.enemyPhysicalResistance,
        magicalResistance:  start.enemyMagicalResistance,
        weakUltCost:        start.enemyWeakUltCost,
      );

      _orchestrator = BattleOrchestrator(
        player: playerCombatant,
        enemy:  enemyCombatant,
        tactic: Tactic.offense,
        potionsPlanned:        potionsToUse,
        potionsPlusPlanned:    potionsPlusToUse,    // 【FEAT-376】
        attackPotionsPlanned:  attackPotionsToUse,  // 【FEAT-376】
        defensePotionsPlanned: defensePotionsToUse, // 【FEAT-432】
        // 【FEAT-381 (2026-05-29)】戦闘画面背景画像 (Backend Enemy.background_image_path)。
        // Orchestrator 内部で初期 BattleState に設定 → 毎 tick s.copyWith() で
        // `this` から自動引き継ぎ。戦闘終了時の「元に戻す」処理は不要
        // (Navigator.pop で元画面 Scaffold に自動復帰)。
        enemyBackgroundImagePath: start.enemyBackgroundImagePath,
        initialSpeedMultiplier: savedSpeed,  // 【FEAT-416】前回選択の倍速を復元
      );

      _orchestrator!.state.addListener(_onOrchestratorUpdate);
      // 【FEAT-296 hotfix 2026-05-24】新規バトル開始時に BattleSession を
      // 完全リセット（前回バトルの finishCompleted = true / rewardCoinsGained
      // 等が残らないよう、初期値 BattleSession ベースに token と state を載せる）。
      // autoDispose を外したため、provider 自体は破棄されず state は持続する。
      // 【FEAT-298】potionsPlanned もリセット時点で記録（UI 残数表示用）。
      state = const BattleSession().copyWith(
        state: _orchestrator!.state.value,
        token: start.token,
        potionsPlanned: potionsToUse,
        potionsUsed: 0,
      );
      _orchestrator!.start();
    } on DailyBattleLimitReachedException catch (e) {
      // 【FEAT-398】日次上限到達 → 専用 errorMessage (Dialog 表示用)
      // 【FEAT-429 (2026-06-12)】動的上限 (10 + bonus) を末尾に併記。
      // 【2026-07-09 hotfix】前 battle の finish 済 modal state (finishCompleted /
      //   rewardCoinsGained 等) が残ると、次 tab で「10 回目タップしても 9 回目の
      //   モーダルが復活する」bug の原因になる。const BattleSession() で完全リセット
      //   してから errorMessage set。詳細は下の一般 catch 参照。
      debugPrint('[BattleSession.startBattle] daily_battle_limit_reached: ${e.message}');
      state = const BattleSession().copyWith(
        // 'daily_battle_limit_reached:' prefix は UI 側の分岐 key なので翻訳しない。
        errorMessage: 'daily_battle_limit_reached:${e.message}\n\n'
            '${ServiceL10n.current.battleErrorDailyQuestQuota(e.currentCount, e.limit)}',
      );
    } catch (e, st) {
      // 【2026-07-09 hotfix】startBattle 失敗時に BattleSession を完全リセット。
      //
      // 【症状】user 報告: ボス連戦で「9 回目 coins/exp=0」→「10 回目タップしても
      //   前回討伐後の状態が表示され、変化しない」→ 一晩経ったら復旧。
      //
      // 【原因】旧実装は errorMessage だけ set していたため、前 battle の finish
      //   modal state (finishCompleted=true, rewardCoinsGained=0 等) がそのまま
      //   保持され、user 目線「10 回目タップしても 9 回目の結果画面が表示され続ける」
      //   状態になっていた。line 491 の `state = const BattleSession().copyWith(...)`
      //   で state はリセットされる想定だが、そこに到達するのは svc.startBattle が
      //   成功した時のみ。失敗経路では前 state が残る = 本 bug の主原因。
      //
      // 【修正】catch でも同じ「新規セッション baseline」を state に載せる (const
      //   BattleSession() は fresh instance) ため、前 battle の finish state が
      //   構造的に持ち越されない。
      //
      // 【翌朝復旧の説明】Backend の日次リセット (battle_charges / daily_battle_count)
      //   で startBattle が成功 → line 491 到達 → state リセットで自然復旧していた。
      //   本 fix で「翌朝待たなくても error dialog 閉じて再試行すれば復旧」の UX に。
      debugPrint('[BattleSession.startBattle] failed: $e\n$st');
      state = const BattleSession().copyWith(
        errorMessage: ServiceL10n.current.battleStartFailedSabi_message,
      );
    }
  }

  /// 【FEAT-398】日次上限 Dialog 表示後に errorMessage をクリアする。
  /// 再発火防止 (listener が 2 回 Dialog を出さないよう)。
  void clearBattleError() {
    state = state.copyWith(clearError: true);
  }

  // ──────────────────────────────────────────────────────────────────────────
  // 【FEAT-505 案 Y → FEAT-513 v1.1 hotfix 2 follow-up (2026-07-31)】
  // 旧 runSkipBattle (headless tick → /battle/finish/ 送信、~110 LOC) は撤去済。
  //
  // 撤去理由: FEAT-505 §2.1 原仕様「速度選択 UI に Skip を 5 番目として追加」
  // (battle_page.dart:_SpeedChip value=50.0 label='⏭' = 50x tick 速度) に統合、
  // Guild toggle → headless runner の別経路は不要になった。visible battle
  // (startBattle + BattleSpeedMultiplier=50.0) が Skip の実装本体。
  //
  // 副産物撤去:
  //   - skip_confirm_dialog.dart (SkipConfirmDialog + SkipResultDialog)
  //   - headless_battle_runner.dart (HeadlessBattleRunner + HeadlessBattleResult)
  //   - PostHog events (battle_skip_used / _win / _lose / _duration_ms)
  //     → 新体験は既存 battle 経路の events で計測 (別 event 不要)
  // ──────────────────────────────────────────────────────────────────────────

  /// 【FEAT-297 Pre-mortem #3】モーダル発火を表明する（最初の listener が呼ぶ）。
  /// 既に true なら何もしない（既存呼び出し側の `if (modalShown) return;` で守られている）。
  /// 戻り値 true = この呼び出しで初めて true にした（モーダル発火 OK）。
  /// 戻り値 false = 既に他で発火済（モーダルを出さずに skip）。
  bool markModalShown() {
    if (state.modalShown) return false;
    state = state.copyWith(modalShown: true);
    return true;
  }

  /// 【FEAT-301】手動必殺ボタンの押下を Orchestrator に委譲する。
  ///
  /// 戻り値:
  ///   - `queued`          → サビ口調 Tooltip「次の一手で必殺技が放たれます 🪶」
  ///   - `alreadyQueued`   → SnackBar 不要（連打冪等化、Pre-mortem #4）
  ///   - `notEnoughCharge` → サビ口調 SnackBar「あと N 回通常攻撃を重ねれば…」
  ///   - `notRunning`      → button 無効化済の前提、UI 側は通常 SnackBar 出さない
  ///
  /// Orchestrator 未初期化（startBattle 未呼び出し）は `notRunning` 扱い。
  UltimateQueueResult tryQueueUltimate() {
    if (_orchestrator == null) return UltimateQueueResult.notRunning;
    return _orchestrator!.tryQueueUltimate();
  }

  /// 作戦切替: 戦闘中も可能。
  ///
  /// 【BUG (2026-06-25)】旧実装は orchestrator state を更新せず provider state
  /// のみ copyWith していたため、FEAT-404 (2026-06-01) で ATB tick 通知が
  /// 10fps 化された結果、`_onAtbProgress` 経由で 100ms 以内に古い tactic に
  /// 巻き戻る退行が発生していた。orchestrator.setTactic に委譲し、provider
  /// state は `_onOrchestratorUpdate` listener 経由で自動同期に切り替えた。
  void switchTactic(Tactic tactic) {
    if (_orchestrator == null) return;
    _orchestrator!.setTactic(tactic);
  }

  /// 【BUG (2026-06-25)】戦闘開始時に回復薬 (基本 + 上位) を 1 個以上
  /// セットしているかどうか。UI (`_BattleLogAndTacticsPanel`) の
  /// `Tactic.recovery` 非表示判定に使用。orchestrator 未起動時は false。
  bool get hasRecoveryPotions => _orchestrator?.hasRecoveryPotions ?? false;

  /// 【FEAT-416 (2026-06-01)】UI (_SpeedChip) からの倍速変更要求。
  /// Orchestrator 未起動時は no-op (Pre-mortem S2: startBattle 完了前のタップ)。
  void setSpeedMultiplier(double value) {
    if (_orchestrator == null) return;
    _orchestrator!.setSpeedMultiplier(value);
  }

  void _onOrchestratorUpdate() {
    if (_orchestrator == null) return;
    final next = _orchestrator!.state.value;
    // 【FEAT-298】orchestrator 内部の potionsUsed を session state に同期する。
    // 自動使用発火時に PotionCountIndicator の残数が即反映される。
    state = state.copyWith(
      state: next,
      potionsUsed: _orchestrator!.potionsUsed,
    );

    if (!_finishSent &&
        (next.status == BattleStatus.won ||
            next.status == BattleStatus.lost)) {
      _finishSent = true;
      _sendFinish(next);
    }
  }

  Future<void> _sendFinish(BattleState finalState) async {
    final token = state.token;
    if (token == null) return;
    try {
      final svc = _ref.read(battleServiceProvider);
      // 【FEAT-298 + FEAT-376 + FEAT-432】戦闘中に実消費したポーション数を Backend に送信。
      final potionsUsed        = _orchestrator?.potionsUsed        ?? 0;
      final potionsPlusUsed    = _orchestrator?.potionsPlusUsed    ?? 0;
      final attackPotionsUsed  = _orchestrator?.attackPotionsUsed  ?? 0;
      final defensePotionsUsed = _orchestrator?.defensePotionsUsed ?? 0;
      final res = await svc.finishBattle(
        token:               token,
        result:              finalState.status == BattleStatus.won ? 'win' : 'lose',
        durationSec:         finalState.durationSec,
        damageDealt:         finalState.totalDamageDealt,
        damageTaken:         finalState.totalDamageTaken,
        rounds:              finalState.rounds,
        summaryText:         finalState.summaryText,
        potionsUsed:         potionsUsed,
        potionsPlusUsed:     potionsPlusUsed,    // 【FEAT-376】
        attackPotionsUsed:   attackPotionsUsed,  // 【FEAT-376】
        defensePotionsUsed:  defensePotionsUsed, // 【FEAT-432】
      );
      // 【FEAT-479 (2026-07-06)】その日初回のバトル勝利で quest piece 演出発火。
      // Backend が `puzzle_piece_colored` を返した場合のみ set、PuzzlePieceListener
      // が provider を watch して overlay モーダルを起動する。
      if (res.puzzlePieceColored != null) {
        _ref.read(puzzlePieceColoredProvider.notifier).state =
            PuzzlePieceColored.fromJson(res.puzzlePieceColored!);
      }
      // 【FEAT-315】 勝利確定時のみ lastVictoryAt を最新時刻に更新。
      // ホーム画面の ref.listen が「prev != next」検出 + 5 秒以内判定で
      // LiliaFloatingPanel を発火する。敗北 / 中断時は更新しない。
      final isWin = finalState.status == BattleStatus.won;

      // 【FEAT-531】バトル本流の結果を計測する。
      //
      // 🔴 **勝敗の分岐の外に置く。** 報酬 0 の敗北パスは処理が短いので
      // `if (isWin)` の中に書いてしまいやすいが、**敗北が測れないと
      // 「負けた翌日また戦うか」に永久に答えられない** (Pre-mortem #4)。
      //
      // 🔵 **途中離脱では飛ばないのが正しい。** 戻るジェスチャ / アプリ終了 /
      // 日次上限では `_sendFinish` 自体が走らないので `battle_started` だけが
      // 残る。**その差分が離脱率**である (deploy_ops.md の表に明記済)。
      PosthogService.instance.capture('battle_finished', properties: {
        'enemy_key':    _lastBattleEnemyKey,
        'entry':        _lastBattleEntry,
        'result':       isWin ? 'win' : 'lose',
        'rounds':       finalState.rounds,
        'duration_sec': finalState.durationSec,
      });
      // 【FEAT-511 Phase A】PostHog event 送信 (level-up / maxed)
      final mastery = res.jobMastery;
      if (mastery != null) {
        if (mastery.leveledUpNow) {
          PosthogService.instance.capture(
            'job_mastery_level_up',
            properties: {
              'job_id':    mastery.jobId,
              'job_name':  mastery.jobName,
              'new_level': mastery.level,
            },
          );
          // 【gameplay_review 20260803 §2-2 a / 要素 C-1】FEAT-511 §2.2 が指定していた
          // サビ口調 SnackBar が未実装で、Lv 1 → Max (786 EXP ≒ 雑魚 157 勝) の道中に
          // 9 回あるはずの「上がった」瞬間が **どこにも表示されない**状態だった。
          // 「積み上げの可視化」を掲げるアプリで新設の積み上げメーターが不可視なのは
          // 本末転倒なので、PostHog の隣で必ずユーザーにも届ける。
          //
          // 語彙は CharacterStat (習慣の積み重ね = 「地層」) と意図的に分ける。
          // ジョブは「戦闘の積み重ね」なので「腕が上がる」を使い、6 軸ステータスとの
          // 混同を避ける (FEAT-511 S5 の区分を文言でも保つ)。
          ToastCenter.showSuccess(
            ServiceL10n.current.battleJobMasteryLevelUpToastSabi_message(
              mastery.jobName,
              mastery.level,
            ),
          );
        }
        if (mastery.maxedNow) {
          PosthogService.instance.capture(
            'job_mastery_maxed',
            properties: {
              'job_id':   mastery.jobId,
              'job_name': mastery.jobName,
            },
          );
        }
      }
      state = state.copyWith(
        rewardCoinsGained:  res.coinsGained,
        rewardExpGained:    res.expGained,
        leveledUp:          res.leveledUp,
        newLevel:           res.newLevel,
        // 【FEAT-296 hotfix 2026-05-24】API 応答完了 → battle_page.dart の
        // listen が本フラグでモーダル発火 → rewardCoinsGained 反映済みの値を表示。
        finishCompleted:    true,
        // 【FEAT-314】その日初の勝利時のみ true、ToastCenter で「+5💎」誘導。
        battleFirstDiamond: res.battleFirstDiamond,
        lastVictoryAt:      isWin ? DateTime.now() : null,
        // 【FEAT-443 (2026-06-20)】10% 確率の木製武器ドロップ情報
        // (null 渡しなら copyWith は保持するが、ここでは res.weaponDropped を
        // 明示的に上書き反映するため null でも一律渡す)。
        weaponDropped:      res.weaponDropped,
        // 【FEAT-511 Phase A】Max 到達時のみジョブ名を渡す (null = 到達なし)。
        jobMasteryMaxedJobName: mastery?.maxedNow == true ? mastery!.jobName : null,
      );
      // 【FEAT-530】再取得はここ 1 箇所に集約した (catch 側も同じものを呼ぶ)。
      await _refreshAfterFinish();
      // 【FEAT-439 (2026-06-17)】勝利時に EnemyListView.defeated を即時更新するため
      // enemy 一覧 (family 全体) を invalidate。次回ギルド画面で勝利済敵の弱点 chip
      // と BattlePreStartSheet の advisory が即座に表示される。
      // 敗北時も invalidate しておく (将来「敗北で何か変化」を入れた時の保険)。
      // ignore: invalid_use_of_visible_for_testing_member
      _ref.invalidate(enemyListProvider);
    } catch (e, st) {
      debugPrint('[BattleSession._sendFinish] failed: $e\n$st');
      // Backend 失敗時もユーザー体験は途切れさせない（モーダルは表示する）
      // 【FEAT-296 hotfix 2026-05-24】catch 経路でも finishCompleted を true に
      // することで、API 失敗時もモーダル発火（reward 0 + errorMessage 表示）
      // でフリーズせず、ユーザーがホーム戻りできる。
      state = state.copyWith(
        errorMessage: ServiceL10n.current.battleFinishRewardFailedSabi_message,
        finishCompleted: true,
      );
      // 【2026-07-05】Backend 送信失敗 (damage_unreasonable / token_expired 等) 時も
      // playerNotifierProvider を refresh することで、ギルド画面の「本日のクエスト」
      // 数値の陳腐化を防ぐ。旧実装は try 側でのみ refresh していたため、finish が
      // 400 で reject されるとギルド画面が 1/10 のまま止まり、pull-to-refresh
      // (RefreshIndicator.onRefresh) しないと 2/10 に更新されないバグがあった
      // (daily_battle_count は BattleStartView で既に +1 済のためサーバー側は正)。
      try {
        await _refreshAfterFinish();
      } catch (_) {
        // player refresh も失敗するケース (ネットワーク完全断など) は諦めて
        // モーダルだけ出す。次回画面遷移で自然と最新化される。
      }
    }
  }

  /// 【FEAT-530 (2026-08-29)】バトル終了後の再取得。
  ///
  /// 🔴 **成功パスと catch の両方が呼ぶ、唯一の場所。** 以前は同じ 2 行が
  /// `_sendFinish` の中に 2 箇所あり、成功パスだけ直して catch 側を取りこぼす
  /// —— という形の事故が起きうる状態だった (FEAT-530 §2.1 / Pre-mortem #2)。
  /// **足すときも減らすときも、ここ 1 箇所を触ること。**
  ///
  /// ## なぜ分岐なのか
  ///
  /// ホームが生きているときは、`invalidate` が即時再取得になり、player は
  /// bootstrap の `'player'` から `setFromBootstrap` で入る。つまり
  /// `GET /api/player/` は**丸ごと余る**。
  /// 逆にホームが居ないとき、`invalidate` は再取得までは走らせるが、
  /// `homeBootstrapControllerProvider` が誰にも listen されていないので
  /// **player には伝わらない** —— ここでは `refresh()` が仕事をしている。
  ///
  /// 🔴 **どちらか一方を消すのは誤り。** 過去 2 回 (FEAT-295 hotfix /
  /// 2026-07-05 追記) は「反映されない」を見て `refresh()` を**足す**方向で
  /// 解決してきた。3 度目を防ぐため、**両方の文脈を縛るテスト**を
  /// `test/battle/battle_finish_refresh_test.dart` に置いてある。
  ///
  /// ## 経緯 (消さないこと)
  ///
  /// - **FEAT-295 hotfix (2026-05-25)**: 旧実装は `invalidate(playerNotifierProvider)`
  ///   だけで、これは「次回 watch 時に再 fetch」にしかならず、戦闘後もホーム盾
  ///   バッジが「✓」のまま残った。ここで `refresh()` (強制再 fetch) が入り、
  ///   `battle_charges -1` (FEAT-403) を確実に反映するようになった。
  /// - **2026-07-05 追記**: finish が 400 で reject されるとギルド画面の
  ///   「本日のクエスト」が 1/10 のまま止まったため、catch 側にも同じ 2 行が入った。
  ///
  /// ホーム不在時も `invalidate` はしておく (次にホームへ来たとき新しい値になる)。
  Future<void> _refreshAfterFinish() async {
    final homeIsLive = _ref.exists(homeIsLiveProvider);
    if (!homeIsLive) {
      await _ref.read(playerNotifierProvider.notifier).refresh();
    }
    // ignore: invalid_use_of_visible_for_testing_member
    _ref.invalidate(homeBootstrapRawProvider);
  }

  /// 【FEAT-299】`job` 引数でジョブ駆動 modifier を Combatant に反映する。
  /// 呼び出し側は `start.playerJob ?? Job.fallback` を渡す前提。
  Combatant _buildPlayerCombatant({required Job job}) {
    final player = _ref.read(playerNotifierProvider).valueOrNull;
    if (player == null) {
      // 【Pre-mortem #5】Player ロード失敗時の Sabi フォールバック
      // ジョブ駆動 modifier も既存挙動互換（Job.fallback）にしておく。
      return Combatant(
        id:        'sabi_default',
        name:      ServiceL10n.current.battleSabiCombatantName,
        spriteKey: 'sabi',
        maxHp:     BattleConstants.sabiFallbackHp,
        currentHp: BattleConstants.sabiFallbackHp,
        atk:       BattleConstants.sabiFallbackAtk,
        spd:       BattleConstants.sabiFallbackSpd,
        atbSpeedModifier:    job.atbSpeedModifier,
        attackPowerModifier: job.attackPowerModifier,
        onHitEffect:         job.onHitEffect,
        ultCost:             job.ultCost,
        jobName:             job.jobName,
      );
    }
    // MVP: PlayerProfile.level に基づく簡易計算（設計ノート §4.3）
    // ATK = 10 + level × 2 + 武器ボーナス
    // 【FEAT-326】 武器ボーナスは `player.equippedWeapon.atkBonus` を参照。
    // 古い Backend (FEAT-326 未デプロイ環境) や未装備の極端ケースでは
    // inline `?? 10` で starter_sword 同等にフォールバック。
    // 【FEAT-295 hotfix 2026-05-25】HP マジックナンバー(100 / 10)を BattleConstants
    // 集約。ギルド画面の _GuildHeader (HP 表示) と同定数を参照することで整合性確保。
    final weaponAtk = player.equippedWeapon?.atkBonus ?? 10;
    // 【FEAT-390】BattleDisplay ヘルパーに集約 (単一真実値化)。
    // computeAtk が attackPowerModifier まで乗算するため、Combatant の
    // attackPowerModifier は 1.0 に設定して二重適用を防ぐ設計。
    // (atk × 1.0 = computeAtk の結果がそのまま damage 計算に使われる)
    // ← studyLv / mentalLv は後述の stat lookup で取得後に渡す。
    final baseMaxHp = BattleConstants.playerBaseHp
        + player.level * BattleConstants.playerHpPerLevel;

    // 【FEAT-333 (2026-05-27)】CharacterStat 6 軸 → バトル能力 1 対 1 連動 (設計案 A)。
    // ユーザー判断 (PM 長期設計セッション 2026-05-27) で v1.0 採択、Sabiowl コア哲学
    // 「習慣達成が世界を動かす」のメカニクス化完成。
    //
    // 連動式 (各ステ Lv 5 で効果例):
    //   運動力 → maxHp += level × 5 (Lv5: +25 HP)
    //   学習力 → atk += level × 1 (Lv5: +5 ATK)
    //   健康力 → 毎 turn HP 自動回復 +level × 2 (Lv5: +10 HP/turn、上限 maxHp)
    //   精神力 → atbSpeedModifier += level × 0.01 (Lv5: +5% 充填速度)
    //   創造力 → critRate = level × 0.005 (Lv5: 2.5% クリ率、damage × 1.5)
    //   貢献力 → damageReduction = level × 0.005 (Lv5: 2.5% 被ダメ軽減)
    //
    // stats null フォールバック: 全ステ Lv 0 として扱い、default 値で既存挙動互換
    // (FEAT-295 baseline + FEAT-299 ジョブ駆動のみ、ステ加算ゼロ)。
    final statsAsync = _ref.read(statsNotifierProvider);
    final stats = statsAsync.valueOrNull ?? const <CharacterStat>[];
    final statLevels = <String, int>{
      for (final s in stats) s.name: s.level,
    };
    final athleticLv     = statLevels['運動力'] ?? 0;
    final studyLv        = statLevels['学習力'] ?? 0;
    final healthLv       = statLevels['健康力'] ?? 0;
    final mentalLv       = statLevels['精神力'] ?? 0;
    final creativityLv   = statLevels['創造力'] ?? 0;
    final contributionLv = statLevels['貢献力'] ?? 0;

    // 【FEAT-390】stat lookup 完了後に BattleDisplay ヘルパーを呼び出す。
    // 計算式の単一真実値化: _StatusSection と同一ヘルパーを参照。
    final displayedAtk = BattleDisplay.computeAtk(
      level:               player.level,
      weaponAtk:           weaponAtk,
      studyLv:             studyLv,         // 【FEAT-333】学習力連動
      attackPowerModifier: job.attackPowerModifier,
    );
    final displayedAtbModifier = BattleDisplay.computeAtb(
      atbSpeedModifier: job.atbSpeedModifier,
      mentalLv:         mentalLv,           // 【FEAT-333】精神力連動
    );

    return Combatant(
      id:        'player',
      name:      player.name,
      spriteKey: player.activeCharacter?.key ?? 'sabi',
      maxHp:     baseMaxHp + (athleticLv * 5),  // 【FEAT-333】運動力連動
      currentHp: baseMaxHp + (athleticLv * 5),
      // 【FEAT-390】BattleDisplay.computeAtk() で計算 (modifier 込み)。
      // attackPowerModifier を 1.0 にすることで二重適用を防止。
      atk:       displayedAtk,
      spd:       10, // MVP は固定
      // 【FEAT-299 / FEAT-390】ATB modifier は BattleDisplay.computeAtb() に集約。
      atbSpeedModifier:    displayedAtbModifier,
      attackPowerModifier: 1.0,  // 【FEAT-390】computeAtk で吸収済み、二重適用防止
      onHitEffect:         job.onHitEffect,
      ultCost:             job.ultCost,
      jobName:             job.jobName,
      // 【FEAT-333】CharacterStat 6 軸連動 (健康力/創造力/貢献力)
      hpRegenPerTurn:      healthLv * 2,
      critRate:            creativityLv * 0.005,
      damageReduction:     contributionLv * 0.005,
    );
  }

  @override
  void dispose() {
    // 【Pre-mortem #1】Orchestrator dispose → 内部の AtbController が Timer cancel
    _orchestrator?.state.removeListener(_onOrchestratorUpdate);
    _orchestrator?.dispose();
    _orchestrator = null;
    super.dispose();
  }
}

// 【FEAT-296 hotfix 2026-05-24】autoDispose を外した。
// 旧実装: StateNotifierProvider.autoDispose<...>
// 問題: ギルド画面 _onJoin で selectEnemyForNextBattle('goblin_king') を呼んでも、
// BattlePage への push 遷移時に watcher が変わり autoDispose 発火
// → BattleSessionNotifier 再生成 → _pendingEnemyKey = null にリセット
// → BattlePage.initState の startBattle() で null が使われ Backend default goblin
// → ユーザーが「ゴブリンキング選択しても普通のゴブリンと戦闘」する事象が発生。
// BattleOrchestrator の Timer cleanup は dispose() で適切に行われるため、
// keepAlive 化してもメモリリーク懸念なし（FEAT-295 Pre-mortem #1 既存対応）。
final battleSessionProvider =
    StateNotifierProvider<BattleSessionNotifier, BattleSession>(
  (ref) => BattleSessionNotifier(ref),
);
