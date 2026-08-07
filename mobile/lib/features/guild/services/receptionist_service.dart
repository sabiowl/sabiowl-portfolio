import 'dart:math';

import '../../battle/models/battle_log_entry.dart';
import '../../battle/models/enemy.dart';
import '../../../l10n/app_localizations.dart';

/// 【FEAT-305】ギルド受付 NPC「リリア」の状態判定 + セリフ選択ロジック。
///
/// 設計判断（指示書 §2.4）: Backend API を増やさず Flutter ローカルで完結。
/// 【FEAT-489 Phase 2A】_kDialogue が日本語テキスト → ARB key に変更。
/// widget 層で AppLocalizations.resolveLiliaMessage() を使って日本語/英語を解決する。
///
/// 優先順位（指示書 §2.3、上から順に判定、最初に該当した state を採用）:
///   1. `defeatJustNow`: 最後の Battle が lose + 5min 以内
///   2. `victoryJustNow`: 最後の Battle が win + 5min 以内
///   3. `bossUnlocked`: 直近 1h で player.level が unlock threshold (15/25/35) を跨いだ
///   4. `levelUp`: 直近 5min で player.level が上がった（5min 経過したら消える）
///   5. `consecutiveBattles`: 直近 1h で Battle 5 件以上
///   6. `restDay`: rest_day=true
///   7. `firstLogin`: player.createdAt が 24h 以内
///   8. `defaultGreeting`: 上記すべて非該当
///
/// CLAUDE.md「受付女性リリア（ギルド NPC）の口調ルール」厳守:
///   - 〜ですよ! / 〜ましょう! / 〜です
///   - 一人称「私」、二人称「あなた様」/「お客様」
///   - 状況連動絵文字 🗡️ / ⚔️ / 🌸 / 🛡️ 等
///   - サビ専用の 🪶 マーカーは使わない
class ReceptionistService {
  ReceptionistService({Random? random}) : _random = random ?? Random();

  final Random _random;

  /// 状態判定 → セリフ選択を 1 ステップで行う公開エントリ。
  /// ARB key を返す。widget 層で AppLocalizations.resolveLiliaMessage(key, level) を使う。
  String pickMessageKeyFor({
    required int playerLevel,
    DateTime? playerCreatedAt,
    DateTime? lastLevelUpAt,
    int? previousPlayerLevel,
    required bool isRestDayToday,
    required List<BattleLogEntry> recentBattles,
    required List<EnemyMaster> enemies,
    DateTime? now,
  }) {
    final state = resolveState(
      playerLevel:          playerLevel,
      playerCreatedAt:      playerCreatedAt,
      lastLevelUpAt:        lastLevelUpAt,
      previousPlayerLevel:  previousPlayerLevel,
      isRestDayToday:       isRestDayToday,
      recentBattles:        recentBattles,
      enemies:              enemies,
      now:                  now,
    );
    return pickMessageKey(state);
  }

  /// 後方互換 alias: pickMessageFor → pickMessageKeyFor。
  /// widget が key を受け取り、AppLocalizations で解決する。
  String pickMessageFor({
    required int playerLevel,
    DateTime? playerCreatedAt,
    DateTime? lastLevelUpAt,
    int? previousPlayerLevel,
    required bool isRestDayToday,
    required List<BattleLogEntry> recentBattles,
    required List<EnemyMaster> enemies,
    DateTime? now,
  }) => pickMessageKeyFor(
    playerLevel:          playerLevel,
    playerCreatedAt:      playerCreatedAt,
    lastLevelUpAt:        lastLevelUpAt,
    previousPlayerLevel:  previousPlayerLevel,
    isRestDayToday:       isRestDayToday,
    recentBattles:        recentBattles,
    enemies:              enemies,
    now:                  now,
  );

  /// 状態判定のみを公開（テスト + UI の優先順位検証用）。
  ReceptionistState resolveState({
    required int playerLevel,
    DateTime? playerCreatedAt,
    DateTime? lastLevelUpAt,
    int? previousPlayerLevel,
    required bool isRestDayToday,
    required List<BattleLogEntry> recentBattles,
    required List<EnemyMaster> enemies,
    DateTime? now,
  }) {
    final t = now ?? DateTime.now();

    // 1. defeat_just_now / 2. victory_just_now（直近の戦闘 5min 以内、最優先）
    if (recentBattles.isNotEmpty) {
      final completed = recentBattles
          .where((b) => b.finishedAt != null && (b.isWin || b.isLose))
          .toList()
        ..sort((a, b) => b.finishedAt!.compareTo(a.finishedAt!));
      if (completed.isNotEmpty) {
        final latest = completed.first;
        final elapsed = t.difference(latest.finishedAt!);
        if (elapsed <= const Duration(minutes: 5)) {
          if (latest.isLose) return ReceptionistState.defeatJustNow;
          if (latest.isWin) return ReceptionistState.victoryJustNow;
        }
      }
    }

    // 3. boss_unlocked
    if (previousPlayerLevel != null &&
        lastLevelUpAt != null &&
        t.difference(lastLevelUpAt) <= const Duration(hours: 1) &&
        playerLevel > previousPlayerLevel) {
      const thresholds = [15, 25, 35];
      for (final th in thresholds) {
        if (previousPlayerLevel < th && playerLevel >= th) {
          final hasEnemyAtThreshold =
              enemies.any((e) => e.unlockLevel == th);
          if (hasEnemyAtThreshold) {
            return ReceptionistState.bossUnlocked;
          }
        }
      }
    }

    // 4. level_up
    if (lastLevelUpAt != null &&
        t.difference(lastLevelUpAt) <= const Duration(minutes: 5)) {
      return ReceptionistState.levelUp;
    }

    // 5. consecutive_battles
    final battlesIn1h = recentBattles.where((b) {
      if (b.finishedAt == null) return false;
      return t.difference(b.finishedAt!) <= const Duration(hours: 1);
    }).length;
    if (battlesIn1h >= 5) {
      return ReceptionistState.consecutiveBattles;
    }

    // 6. rest_day
    if (isRestDayToday) {
      return ReceptionistState.restDay;
    }

    // 7. first_login
    if (playerCreatedAt != null &&
        t.difference(playerCreatedAt) <= const Duration(hours: 24)) {
      return ReceptionistState.firstLogin;
    }

    // 8. default
    return ReceptionistState.defaultGreeting;
  }

  /// 指定 state の ARB key pool からランダム選択。
  /// プールが空の場合は default にフォールバック。
  String pickMessageKey(ReceptionistState state) {
    final pool = _kDialogueKeys[state] ?? _kDialogueKeys[ReceptionistState.defaultGreeting]!;
    if (pool.isEmpty) {
      return 'guildLiliaFallback';
    }
    return pool[_random.nextInt(pool.length)];
  }
}

/// リリアの状態タイプ（指示書 §2.3 の 8 シナリオ）。
enum ReceptionistState {
  defaultGreeting,
  firstLogin,
  levelUp,
  restDay,
  consecutiveBattles,
  bossUnlocked,
  victoryJustNow,
  defeatJustNow,
}

/// 【FEAT-489 Phase 2A】ARB key pool。日本語テキストではなく ARB key を格納。
/// widget 層で AppLocalizations.resolveLiliaMessage(key, level) を使って解決する。
/// 各 key は app_ja.arb / app_en.arb に対応エントリあり。
const Map<ReceptionistState, List<String>> _kDialogueKeys = {
  ReceptionistState.defaultGreeting: [
    'guildLiliaDefault1',
    'guildLiliaDefault2',
    'guildLiliaDefault3',
    'guildLiliaDefault4',
    'guildLiliaDefault5',
  ],
  ReceptionistState.firstLogin: [
    'guildLiliaFirstLogin1',
  ],
  ReceptionistState.levelUp: [
    'guildLiliaLevelUp1',
    'guildLiliaLevelUp2',
  ],
  ReceptionistState.restDay: [
    'guildLiliaRestDay1',
  ],
  ReceptionistState.consecutiveBattles: [
    'guildLiliaConsecutiveBattles1',
  ],
  ReceptionistState.bossUnlocked: [
    'guildLiliaBossUnlocked1',
  ],
  ReceptionistState.victoryJustNow: [
    'guildLiliaVictory1',
    'guildLiliaVictory2',
    'guildLiliaVictory3',
  ],
  ReceptionistState.defeatJustNow: [
    'guildLiliaDefeat1',
  ],
};

/// 【FEAT-489 Phase 2A】ARB key → localized string 解決。
/// receptionist_service が返す ARB key を AppLocalizations 経由でテキストに変換する。
/// level は levelUp 系メッセージ (guildLiliaLevelUp1/2) でのみ使用。
String resolveLiliaMessage(AppLocalizations l10n, String key, {int? level}) {
  switch (key) {
    case 'guildLiliaDefault1': return l10n.guildLiliaDefault1;
    case 'guildLiliaDefault2': return l10n.guildLiliaDefault2;
    case 'guildLiliaDefault3': return l10n.guildLiliaDefault3;
    case 'guildLiliaDefault4': return l10n.guildLiliaDefault4;
    case 'guildLiliaDefault5': return l10n.guildLiliaDefault5;
    case 'guildLiliaFirstLogin1': return l10n.guildLiliaFirstLogin1;
    case 'guildLiliaLevelUp1': return l10n.guildLiliaLevelUp1(level ?? 0);
    case 'guildLiliaLevelUp2': return l10n.guildLiliaLevelUp2(level ?? 0);
    case 'guildLiliaRestDay1': return l10n.guildLiliaRestDay1;
    case 'guildLiliaConsecutiveBattles1': return l10n.guildLiliaConsecutiveBattles1;
    case 'guildLiliaBossUnlocked1': return l10n.guildLiliaBossUnlocked1;
    case 'guildLiliaVictory1': return l10n.guildLiliaVictory1;
    case 'guildLiliaVictory2': return l10n.guildLiliaVictory2;
    case 'guildLiliaVictory3': return l10n.guildLiliaVictory3;
    case 'guildLiliaDefeat1': return l10n.guildLiliaDefeat1;
    default: return l10n.guildLiliaFallback;
  }
}

/// テスト + 検証用に ARB key map を読み取り専用で公開する。
Map<ReceptionistState, List<String>> get kReceptionistDialogueForTest =>
    Map<ReceptionistState, List<String>>.unmodifiable(_kDialogueKeys);
