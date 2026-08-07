import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../battle/providers/battle_provider.dart';
import '../../habits/providers/habits_provider.dart' show playerNotifierProvider;
import '../services/receptionist_service.dart';
import '../services/receptionist_state_service.dart';  // 【FEAT-308】
import 'speech_bubble.dart';

/// 【FEAT-305】ギルド画面 上部に表示するリリア（受付 NPC）+ 吹き出し UI。
///
/// 構造（指示書 §2.5/2.6）:
///   - 左: リリア dot 絵 64×64（正面、`assets/images/npc/lilia_64.webp`、UI sprite カテゴリ）
///   - 右: SpeechBubble（状態連動セリフ）
///   - 背景: AppTheme.card → surface のグラデーション、下端に primary border
///
/// セリフ判定（指示書 §2.3 優先順位）:
///   - ギルド画面 enter 時に 1 回だけ評価（リスナーで再評価しない、UX 安定）
///   - 状態が変化したら次回入場時に切り替わる
///
/// Pre-mortem #5 緩和:
///   - 評価は `WidgetsBinding.instance.addPostFrameCallback` で 1 フレーム遅延
///     しない（StatelessWidget では不可能、再ビルド時の判定で吸収）
///   - 状態取得に async が必要なため `recentBattlesProvider` の AsyncValue を当てる
class GuildReceptionView extends ConsumerStatefulWidget {
  const GuildReceptionView({super.key});

  @override
  ConsumerState<GuildReceptionView> createState() => _GuildReceptionViewState();
}

class _GuildReceptionViewState extends ConsumerState<GuildReceptionView> {
  /// 画面入場時に 1 回計算されたメッセージをキャッシュ（UX 安定、頻繁切替防止）。
  /// 戻ってくる度に再評価するため、State 変更で setState せず、build で 1 回だけ算出。
  String? _cachedMessage;

  /// ReceptionistService（DI せずローカル new、純粋ロジック層なので問題なし）。
  final _service = ReceptionistService();

  /// 【FEAT-308】SharedPreferences ベース level コンテキスト。
  /// `initState` で非同期 load、build で利用。null = まだ未ロード or 初回。
  LevelUpContext? _levelContext;
  bool _levelContextLoaded = false;

  // 【FEAT-489 Phase 2A】resolveLiliaMessage は receptionist_service.dart に公開済み。

  @override
  void initState() {
    super.initState();
    // 非同期ロード: SharedPreferences から前回 level を取得。
    // 完了したら setState で再 build → 正しい level_up / boss_unlocked 判定が走る。
    // 未ロード中は null コンテキスト = default セリフにフォールバック（UX 安定）。
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final player = ref.read(playerNotifierProvider).valueOrNull;
      if (player == null) {
        // Player 未ロード時はスキップ。次回 build で Player ロード後の再評価に委ねる。
        // (本 widget は ConsumerStatefulWidget なので Player AsyncValue 変化で再 build)
        if (!mounted) return;
        setState(() => _levelContextLoaded = true);
        return;
      }
      final svc = ref.read(receptionistStateServiceProvider);
      final ctx = await svc.resolveLevelUpContext(player.level);
      if (!mounted) return;
      setState(() {
        _levelContext = ctx;
        _levelContextLoaded = true;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    // ── 状態取得 ──────────────────────────────────────────────────
    final playerAsync = ref.watch(playerNotifierProvider);
    final battlesAsync = ref.watch(recentBattlesProvider(10));
    final enemiesAsync = ref.watch(enemyListProvider(null));

    // ── メッセージ算出（フレームごとに毎回計算しても重くないが、UX 安定のため
    //   _cachedMessage で 1 回固定。画面再入場で _GuildReceptionViewState が
    //   再生成されるため、自動で「次回入場で切り替わる」が成立）─────────────
    final player = playerAsync.valueOrNull;
    final battles = battlesAsync.valueOrNull ?? const [];
    final enemies = enemiesAsync.valueOrNull ?? const [];

    // 【FEAT-308】Player ロード完了 + LevelContext ロード完了の両方を待ってから
    // 初回 message 算出。未完了時は default fallback で表示安定。
    if (_cachedMessage == null && player != null && _levelContextLoaded) {
      _cachedMessage = _service.pickMessageFor(
        playerLevel:        player.level,
        playerCreatedAt:    player.createdAt,
        // 【FEAT-308】SharedPreferences ベース暫定実装で v1.0 内に動作化。
        // v1.1 FEAT-310 (SP/JP 育成) で Backend に PlayerProfile.last_level_up_at +
        // previous_level 追加時、本サービス廃止 → playerNotifierProvider 直接読みに移行。
        lastLevelUpAt:       _levelContext?.lastLevelUpAt,
        previousPlayerLevel: _levelContext?.previousLevel,
        isRestDayToday:      false,  // 【FEAT-424】休息日機能廃止により常に false
        recentBattles:       battles,
        enemies:             enemies,
      );
      // 【FEAT-308】セリフ表示後、SharedPreferences の last_seen_level を現在 level に更新。
      // 次回入場時に同じ Lv UP を再発火させない (二度祝福防止、契約テスト B 担保)。
      // fire-and-forget (await しない、UX 即時性優先、write 失敗してもサイレント)。
      // ignore: discarded_futures
      ref
          .read(receptionistStateServiceProvider)
          .markLevelSeen(player.level);
    }

    // 【FEAT-489 Phase 2A】ARB key → localized string の解決。
    // _cachedMessage は ARB key (例: 'guildLiliaDefault1')。level 付き key は
    // level_up 系のみ (guildLiliaLevelUp1/2) で player.level を渡す。
    final l10n = AppLocalizations.of(context)!;
    final messageKey = _cachedMessage ?? 'guildLiliaFallback';
    final message = resolveLiliaMessage(l10n, messageKey, level: player?.level);


    // ── 描画 ─────────────────────────────────────────────────────
    // 【FEAT-306 案 C 修正 2026-05-25】
    // 元: Container 単体で gradient → 半透明黒オーバーレイで透過 (案 B)
    // 修正: SizedBox + Stack 構造化し、背景画像をリリア領域内に閉じ込め (案 C)
    //   - Layer 1: 背景画像 guild_reception_2.png (Positioned.fill、リリア領域 100%)
    //   - Layer 2: 半透明黒オーバーレイ alpha=0.25 (吹き出し UI コントラスト確保)
    //   - Layer 3: 下端 border (1px、領域の区切り明示)
    //   - Layer 4: リリア + 吹き出し Row (Padding 12px、最上層)
    // ボスリスト領域には背景画像が及ばず、Scaffold.backgroundColor (AppTheme.surface) で
    // 従来通りの暗背景。ユーザー要望「リリア領域のみ背景画像」と完全一致。
    return SizedBox(
      width: double.infinity,
      // 画面 25% を確保（指示書 §2.5 設計判断）。
      height: MediaQuery.of(context).size.height * 0.25,
      child: Stack(
        children: [
          // ── Layer 1: 背景画像（ギルド受付木造内装） ──────────────────
          // PM (長期設計) セッション 2026-05-25 でユーザー提供 Gemini 画像 1024px を
          // PixelLab で「背景のみ」調整した guild_reception_2.png を採用。
          Positioned.fill(
            child: Image.asset(
              'assets/images/backgrounds/guild_reception_2.webp',
              fit: BoxFit.cover,
              filterQuality: FilterQuality.none, // ドット絵 nearest 厳守
              errorBuilder: (_, __, ___) =>
                  Container(color: AppTheme.surface),
            ),
          ),
          // ── Layer 2: 半透明黒オーバーレイ ──────────────────────────
          // 吹き出し UI のコントラスト確保 (Pre-mortem #1 対応)。alpha=0.25 で
          // 背景画像の「ギルドという場所感」と UI 視認性の両立。
          Positioned.fill(
            child: Container(color: Colors.black.withValues(alpha: 0.25)),
          ),
          // ── Layer 3: 下端 border (区切り線) ────────────────────────
          // ボスリスト領域との境界を明示。
          Positioned(
            bottom: 0,
            left:   0,
            right:  0,
            child: Container(
              height: 1,
              color: AppTheme.primary.withValues(alpha: 0.3),
            ),
          ),
          // ── Layer 4: リリア + 吹き出し（最上層） ──────────────────
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // ── リリア dot 絵（正面、UI sprite カテゴリ）─────────
                // 受付業務 = ユーザーとの対面のため正面向き sprite を採用（指示書 §2.1.2）。
                // Sidescroller battle sprite（敵 = East / 味方 = West）とは別ルール。
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: AppTheme.surface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: AppTheme.primary.withValues(alpha: 0.4),
                      width: 1.5,
                    ),
                  ),
                  padding: const EdgeInsets.all(6),
                  child: Image.asset(
                    'assets/images/npc/lilia_64.webp',
                    filterQuality: FilterQuality.none, // ドット絵 nearest 厳守
                    errorBuilder: (_, __, ___) => const Icon(
                      Icons.person_outline,
                      color: Colors.white54,
                      size: 36,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                // ── 右: 吹き出し + 本日のクエスト参加回数 chip ────────
                // 【FEAT-411 (2026-06-01)】ユーザー要望「ギルド画面で 1 日参加回数の
                // 上限を表示」採択。リリア吹き出しの下に小さな情報 chip を併記する
                // 案 B 採用 = リリアの「業務的接客」役割 (CLAUDE.md) と整合、
                // セリフプール変更不要で工数最小。daily 残数の状態色 (紫→橙→赤+🔒)
                // で視認性確保。
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SpeechBubble(message: message),
                      const SizedBox(height: 6),
                      const _DailyBattleCountChip(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 【FEAT-411 (2026-06-01)】本日のクエスト参加回数を表示する chip。
///
/// ユーザー要望「ギルド画面で 1 日参加回数の上限を表示」採択 (案 B 採用)。
/// リリア吹き出しの直下に小さく配置し、「業務的接客」役割と整合させる。
///
/// 表示パターン (Y = 10 + player.dailyBattleLimitBonus、【FEAT-429】で動的化):
/// - 0 〜 Y-3 戦: 紫系 (通常) 「⚔️ 本日のクエスト N/Y」
/// - Y-2 〜 Y-1 戦: オレンジ系 (警告) 「⚔️ 本日のクエスト N/Y」(残 1-2 戦)
/// - Y 戦  : 赤系 + 🔒 「🔒 本日のクエスト Y/Y」(上限到達)
///
/// BottomNav バッジ (FEAT-409 ストック「✓×N」表示) と補完関係:
/// - バッジ: 「✓×N」= 今すぐ何戦できるか (charges // chargesPerBattle)
/// - chip:  「⚔️ N/Y」= 本日もう何戦したか (daily 上限まで残り何戦)
class _DailyBattleCountChip extends ConsumerWidget {
  const _DailyBattleCountChip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final avail = ref.watch(battleAvailabilityProvider);
    final isLocked = avail.dailyBattleLimitReached;
    // 【FEAT-429】警告閾値も動的上限基準 (残り 2 戦) に追従させる。
    final isWarning = !isLocked && avail.dailyBattleCount >= avail.dailyBattleLimit - 2;

    final Color borderColor;
    final Color bgColor;
    final Color textColor;
    if (isLocked) {
      borderColor = Colors.red.withValues(alpha: 0.45);
      bgColor     = Colors.red.withValues(alpha: 0.18);
      textColor   = Colors.red.shade300;
    } else if (isWarning) {
      borderColor = Colors.orange.withValues(alpha: 0.45);
      bgColor     = Colors.orange.withValues(alpha: 0.18);
      textColor   = Colors.orange.shade300;
    } else {
      borderColor = AppTheme.primary.withValues(alpha: 0.35);
      bgColor     = AppTheme.primary.withValues(alpha: 0.14);
      textColor   = Colors.white.withValues(alpha: 0.88);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor, width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            isLocked ? '🔒' : '⚔️',
            style: const TextStyle(fontSize: 11),
          ),
          const SizedBox(width: 4),
          Text(
            AppLocalizations.of(context)!.guildReceptionDailyQuestLabel(
              avail.dailyBattleCount, avail.dailyBattleLimit,
            ),
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: textColor,
            ),
          ),
        ],
      ),
    );
  }
}
