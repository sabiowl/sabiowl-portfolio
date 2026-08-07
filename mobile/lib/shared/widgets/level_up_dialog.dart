import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // FEAT-110: HapticFeedback
import 'package:flutter_riverpod/flutter_riverpod.dart';
// 【BUG-65】go_router / app_router の import は不要化。
// caller (home_page) が `AppRoutes.stats` への push を担うため、dialog 側では import 不要。
import '../../core/services/popup_serializer.dart';  // 【gameplay_review 20260627 P2-1】popup 直列化
import '../../core/theme/app_theme.dart';
import '../../features/gamification/models/gamification_models.dart';
import '../../features/gamification/providers/gamification_provider.dart';
// 【FEAT-489 Phase 2C follow-up】stat 名 (運動力 等) は Backend 由来の日本語 enum 値
// なので、描画時は StatHexagonChart.fullNameFor で l10n 解決する。
import '../../features/gamification/widgets/stat_hexagon_chart.dart';
import '../../features/habits/providers/habits_provider.dart';
import '../../l10n/app_localizations.dart';
import 'sabi_error_chip.dart';

// BUG-38: 旧実装は運動力に AppTheme.expColor（緑 #4CAF50 ＝ EXP 獲得色）を流用しており、
// 自動配分パネル (_AutoAllocationsPanel._icons) のオレンジ #FF9800 と食い違っていた。
// 行全体がオレンジ + 緑 + オレンジボタンの「クリスマスカラー」に見えていたため、
// _AutoAllocationsPanel と同じオレンジに統一し、両パネルの色定義を 1 か所に集約する。
const _statMeta = {
  '運動力': ('💪', Color(0xFFFF9800)),   // オレンジ（運動・エクササイズ）
  '学習力': ('📚', Color(0xFF2196F3)),   // ブルー
  '健康力': ('❤️', Color(0xFFE24B4A)),   // レッド
  '精神力': ('🧘', Color(0xFF9B59B6)),   // パープル
  '創造力': ('🎨', Color(0xFFF59E0B)),   // FEAT-171: アンバー（創造・器用）
  '貢献力': ('🤝', Color(0xFF14B8A6)),   // FEAT-171: ティール（貢献・魅力）
};

class LevelUpDialog extends ConsumerStatefulWidget {
  final int newLevel;
  final Map<String, int> autoAllocations;
  /// 【FEAT-379 (2026-05-29)】今回付与した結晶 { crystal_key: count }。
  /// 空の場合は結晶セクションを非表示。Pre-mortem #3: 約束表現は使わない。
  final Map<String, int> crystalsAwarded;

  const LevelUpDialog({
    super.key,
    required this.newLevel,
    this.autoAllocations = const {},
    this.crystalsAwarded = const {},
  });

  /// レベルアップダイアログを表示する。
  ///
  /// 戻り値:
  /// - `true`: ユーザーが「ステータスについて」をタップ → caller は `/stats` へ push すべき
  /// - `false` / `null`: ユーザーが「続ける」または barrier タップで閉じた
  ///
  /// 【BUG-65】dialog 内で `context.push(AppRoutes.stats)` を直接呼ぶ設計は廃止。
  /// BUG-61（outerContext パターン）/ BUG-64（Future.microtask 遅延）の 2 度の試行で
  /// いずれも実機 freeze が再発した。`Future.microtask` / `addPostFrameCallback` で
  /// 遅延させても、dialog dispose と navigation のフレーム境界の競合は完全には消えない。
  /// 標準パターンに従い、**dialog は結果を返すだけ** で navigation は caller が担う。
  /// `showDialog<T>` の Future は dialog が完全 unmount されたあとに resolve することが
  /// Flutter の API 契約で保証されている。caller は `await LevelUpDialog.show(...)` の
  /// 戻り値で `/stats` への遷移を判断する。
  static Future<bool?> show(
    BuildContext context,
    int newLevel, {
    Map<String, int> autoAllocations = const {},
    Map<String, int> crystalsAwarded = const {},  // 【FEAT-379】
  }) {
    // 【gameplay_review 20260627 P2-1】祝祭系 popup の直列化のため
    // PopupSerializer.enqueueShowDialog 経由に変更。既存 API (show の戻り値)
    // は維持されるため、呼び出し側 (home_page) の変更は不要。
    return PopupSerializer.enqueueShowDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (_) => LevelUpDialog(
        newLevel: newLevel,
        autoAllocations: autoAllocations,
        crystalsAwarded: crystalsAwarded,
      ),
    );
  }

  @override
  ConsumerState<LevelUpDialog> createState() => _LevelUpDialogState();
}

class _LevelUpDialogState extends ConsumerState<LevelUpDialog>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    // 【FEAT-382 (2026-05-29) → FEAT-453 (2026-06-20)】レベルアップハプティクス強化。
    //
    // 旧: HapticFeedback.heavyImpact() 単発 (FEAT-382 軽量先行)。
    //   問題: 強さはあるが瞬間的な thud で終わり、「達成感」「リズム」が乏しい。
    //
    // 新: 3 パルス pattern (heavy → 80ms → heavy → 100ms → medium、約 180ms)。
    //   「鐘が鳴って余韻が残る」感覚で、ユーザー要望「タスク達成が心地良くなる
    //   ようなハプティクス」を実現。iOS UINotificationFeedback.success
    //   (di-dit pattern) の Flutter 標準 API 近似。
    //
    // サビ哲学「静かな聖域」整合: 180ms に抑制 (>500ms は煩わしさ NG)、
    // 強→強→中の decreasing 強度で「祝福してすっと退く」品の良さを維持。
    _playLevelUpHaptic();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _scale = CurvedAnimation(parent: _ctrl, curve: Curves.elasticOut);
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeIn);
    _ctrl.forward();
  }

  /// 【FEAT-453 (2026-06-20)】レベルアップ専用 3 パルスハプティクス pattern。
  ///
  /// パターン: heavy → 80ms → heavy → 100ms → medium (総時間 ~180ms)
  /// - 1 拍目 (heavy): 「達成!」の明確な確信
  /// - 2 拍目 (heavy): 確信の強化、リズム形成
  /// - 3 拍目 (medium): 余韻、自然な減衰
  ///
  /// fire-and-forget (await しない) で initState 内から呼ぶ。各 await の間に
  /// mounted check を入れて dispose 後の安全側 no-op を保証。
  Future<void> _playLevelUpHaptic() async {
    await HapticFeedback.heavyImpact();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    if (!mounted) return;
    await HapticFeedback.heavyImpact();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (!mounted) return;
    await HapticFeedback.mediumImpact();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // 【BUG-66】dialog 全体ではなく内側の `Consumer` で provider 購読する。
    // 旧実装は `_LevelUpDialogState.build` 内で直接 `ref.watch` していたため、
    // dialog 全体の Element が `statsNotifierProvider` / `playerNotifierProvider` の
    // dependent になり、dispose 中（pop から transitionDuration 150ms 以内）に
    // provider 通知（例: FCM 自己プッシュによる overlay rebuild の波）を受けると
    // `markNeedsBuild` が defunct Element に飛んで assertion を発火していた。
    // Consumer で局所化すると、Consumer 自身が unmount された時点で dependency が
    // 解除され、後続の通知は dialog Element に届かない。
    return FadeTransition(
      opacity: _fade,
      child: Dialog(
        backgroundColor: Colors.transparent,
        child: ScaleTransition(
          scale: _scale,
          // BUG-22: ダイアログ全体の最大高さを画面の 85% に制限。
          // これに加え、可変コンテンツ（自動配分パネル + ステータス配分）を
          // Flexible + SingleChildScrollView でラップし、固定コンテンツ
          // （✨ / LEVEL UP! / Lv.XX バッジ / ボタン）は常に完全表示する。
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.85,
            ),
            child: Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    AppTheme.primary.withValues(alpha: 0.95),
                    AppTheme.cardBackground,
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: AppTheme.gold.withValues(alpha: 0.6),
                  width: 2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.primary.withValues(alpha: 0.4),
                    blurRadius: 24,
                    spreadRadius: 4,
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ── 固定: LEVEL UP! 演出 ──────────────────────────────
                  const Text('✨', style: TextStyle(fontSize: 48)),
                  const SizedBox(height: 4),
                  const Text(
                    'LEVEL UP!',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.gold,
                      letterSpacing: 4,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 5),
                    decoration: BoxDecoration(
                      color: AppTheme.gold.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppTheme.gold.withValues(alpha: 0.4)),
                    ),
                    child: Text(
                      'Lv. ${widget.newLevel}',
                      style: const TextStyle(
                        fontSize: 36,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // 【FEAT-382 (2026-05-29) Phase 2】gameplay_review 20260528 P2-5 後半
                  // 「LvUp ダイアログにサビセリフ追加」を軽量先行 Haptic に続いて完了。
                  // CLAUDE.md サビ口調ルール (紳士的トーン + 模範台詞調) + FEAT-333
                  // 「stat → 戦闘能力」連動の意味重視で、「積み上げ → 力」を直接示す。
                  // 🪶 マーカーで「サビが寄り添っている」感を演出 (システム文末尾の慣例)。
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      l10n.sharedLevelUpDialogSabiMessage,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.85),
                        fontSize: 12,
                        height: 1.5,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // 【BUG-66 v2】Consumer は leaf widget だけ局所化（v1 の Column ラップは
                  // outer Column の Flexible 制約を壊し layout overflow を起こした）。
                  // 配置: Flexible は outer Column 直下に戻し（MaxHeight 制約を継承）、
                  // provider 依存の `_StatAllocationSection` と `ElevatedButton` のみを
                  // 個別 Consumer で包む。dialog dispose 時は Consumer が先に unmount
                  // → dependency 解除 → 外側 Element に provider 通知が届かない設計。
                  Flexible(
                    child: SingleChildScrollView(
                      physics: const BouncingScrollPhysics(),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // 自動配分サマリーパネル（スクロール対象に移動）
                          if (widget.autoAllocations.isNotEmpty) ...[
                            _AutoAllocationsPanel(
                                allocations: widget.autoAllocations),
                            const SizedBox(height: 12),
                          ],
                          // 【FEAT-379】結晶獲得演出パネル
                          if (widget.crystalsAwarded.isNotEmpty) ...[
                            _CrystalAwardPanel(
                                crystalsAwarded: widget.crystalsAwarded),
                            const SizedBox(height: 12),
                          ],
                          // ステータスポイント配分セクション
                          // 【BUG-66】provider 依存箇所を Consumer 局所化
                          Consumer(
                            builder: (context, ref, _) {
                              final statsAsync = ref.watch(statsNotifierProvider);
                              final allocatable = ref
                                      .watch(playerNotifierProvider)
                                      .whenOrNull(data: (p) => p.allocatablePoints) ??
                                  0;
                              return _StatAllocationSection(
                                statsAsync: statsAsync,
                                allocatable: allocatable,
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 12),
                  // ── FEAT-118 / BUG-65: ステータスについてリンク ─────────────────
                  // 【BUG-65】dialog 内 navigation を廃止し、caller (home_page) に判断を委譲する
                  // 標準パターンへ書き換え（BUG-61 outerContext + BUG-64 Future.microtask は
                  // いずれも freeze 再発したため）。pop(true) で「ユーザーがステータス画面を見たい」
                  // を caller に伝え、caller が `await showDialog<bool>` 完了後に push を実行する。
                  GestureDetector(
                    onTap: () =>
                        Navigator.of(context, rootNavigator: true).pop(true),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.info_outline,
                            size: 13,
                            color: Colors.white.withValues(alpha: 0.38),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            l10n.sharedLevelUpDialogAboutStatusLink,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.38),
                              fontSize: 12,
                              decoration: TextDecoration.underline,
                              decorationColor:
                                  Colors.white.withValues(alpha: 0.38),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // ── 固定: 続けるボタン ────────────────────────────────
                  // 【BUG-66】provider 依存（allocatable）箇所を Consumer 局所化
                  Consumer(
                    builder: (context, ref, _) {
                      final allocatable = ref
                              .watch(playerNotifierProvider)
                              .whenOrNull(data: (p) => p.allocatablePoints) ??
                          0;
                      return SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          // 【BUG-65】pop(false) で「stats 画面に行かない」を明示。
                          onPressed: () =>
                              Navigator.of(context, rootNavigator: true).pop(false),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: allocatable > 0
                                ? AppTheme.gold.withValues(alpha: 0.75)
                                : AppTheme.gold,
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: Text(
                            allocatable > 0 ? l10n.sharedLevelUpDialogSkipContinue : l10n.sharedLevelUpDialogContinue,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 16),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StatAllocationSection extends ConsumerWidget {
  final AsyncValue<List<CharacterStat>> statsAsync;
  final int allocatable;

  const _StatAllocationSection({
    required this.statsAsync,
    required this.allocatable,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                l10n.sharedLevelUpDialogStatAllocTitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 6),
              _RemainingBadge(remaining: allocatable),
            ],
          ),
          const SizedBox(height: 12),
          statsAsync.when(
            data: (stats) {
              const order = ['運動力', '学習力', '精神力', '健康力'];
              final sorted = [...stats]
                ..sort((a, b) {
                  final ai = order.indexOf(a.name);
                  final bi = order.indexOf(b.name);
                  return (ai < 0 ? 999 : ai).compareTo(bi < 0 ? 999 : bi);
                });
              return Column(
                children: sorted
                    .map((s) => _StatRow(
                          stat: s,
                          canAllocate: allocatable > 0,
                          onAllocate: () =>
                              ref.read(statsNotifierProvider.notifier).allocate(s.id),
                        ))
                    .toList(),
              );
            },
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.gold),
              ),
            ),
            // P0-2: ステータス取得に失敗した時はダイアログ内で静かに通知する
            error: (_, __) => SabiErrorChip(
              message: l10n.sharedLevelUpDialogStatLoadError,
            ),
          ),
        ],
      ),
    );
  }
}

class _RemainingBadge extends StatelessWidget {
  final int remaining;
  const _RemainingBadge({required this.remaining});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      child: Container(
        key: ValueKey(remaining),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: remaining > 0
              ? Colors.orange.withValues(alpha: 0.85)
              : Colors.green.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          remaining > 0 ? l10n.sharedLevelUpDialogRemainingPt(remaining) : l10n.sharedLevelUpDialogAllocDone,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

class _StatRow extends StatefulWidget {
  final CharacterStat stat;
  final bool canAllocate;
  final Future<void> Function() onAllocate;
  const _StatRow({required this.stat, required this.canAllocate, required this.onAllocate});

  @override
  State<_StatRow> createState() => _StatRowState();
}

class _StatRowState extends State<_StatRow> {
  bool _loading = false;

  // FEAT-119: EXP バーアニメーション用の前回値
  double _prevExpRate = 0.0;

  // ── 長押し加速配分 ────────────────────────────────────────────
  Timer?    _longPressTimer;
  bool      _isLongPressing     = false;
  bool      _isLongPressCalling  = false;
  Duration  _currentInterval    = const Duration(milliseconds: 200);
  DateTime? _longPressStartTime;
  bool      _isHolding          = false; // FEAT-110: 長押し視覚フィードバック用

  // FEAT-119: EXP バーアニメーション — 前回値を保存して補間の起点にする
  @override
  void didUpdateWidget(_StatRow old) {
    super.didUpdateWidget(old);
    if (old.stat.expRate != widget.stat.expRate) {
      _prevExpRate = old.stat.expRate;
    }
  }

  /// 長押し開始: 初回配分を即時実行し、以降は加速スケジュールでリスケ
  void _startLongPress() {
    _isLongPressing = true;
    _longPressStartTime = DateTime.now();
    // FEAT-110: ハプティックフィードバック
    HapticFeedback.lightImpact();
    _doLongPressAllocate(); // 即時 1 回
    _scheduleNext();
  }

  /// 次の配分を現在の interval でスケジュール
  void _scheduleNext() {
    if (!_isLongPressing || !widget.canAllocate || !mounted) {
      _stopLongPress();
      return;
    }
    _longPressTimer = Timer(_currentInterval, () async {
      await _doLongPressAllocate();
      if (_isLongPressing && widget.canAllocate && mounted) {
        _accelerate();
        _scheduleNext();
      } else {
        _stopLongPress();
      }
    });
  }

  /// 保持時間に応じて interval を短縮する（0.8s ごとに 40ms 短縮、下限 60ms）
  void _accelerate() {
    if (_longPressStartTime == null) return;
    final elapsed = DateTime.now().difference(_longPressStartTime!).inMilliseconds;
    // 0.8s ごとに段階を上げる（最大 4 段階: 200→160→120→80→60ms）
    final stage = (elapsed ~/ 800).clamp(0, 4);
    final targetMs = 200 - stage * 40;
    _currentInterval = Duration(milliseconds: targetMs.clamp(60, 200));
  }

  /// 実際の配分呼び出し（並行呼び出し防止付き）
  Future<void> _doLongPressAllocate() async {
    // BUG-44: ポイントがない or ウィジェット破棄済み → 長押しを終了
    if (!widget.canAllocate || !mounted) {
      _stopLongPress();
      return;
    }
    // BUG-44: 前の API 呼び出しが完了していない → このティックをスキップ（長押しは継続）
    // _stopLongPress() を呼ばないことで _isLongPressing = true を維持し、
    // タイマーコールバックが _scheduleNext() を再スケジュールできるようにする。
    // 旧実装は _isLongPressCalling==true 時にも _stopLongPress を呼んでいたため、
    // API 応答 (300〜600ms) > タイマー間隔 (200ms) の関係で 2 回目のティックで
    // 必ず長押しが終了し、結果として「1 回しか割り振られない」体感になっていた。
    if (_isLongPressCalling) return;

    _isLongPressCalling = true;
    await widget.onAllocate();
    if (mounted) _isLongPressCalling = false;
  }

  /// 長押し終了: タイマーを止めてフィールドをリセット
  void _stopLongPress() {
    _isLongPressing = false;
    _longPressTimer?.cancel();
    _longPressTimer = null;
    _currentInterval = const Duration(milliseconds: 200); // 次回のために初期値に戻す
    _longPressStartTime = null;
    // FEAT-110: 保持中ビジュアルをリセット
    if (mounted) setState(() => _isHolding = false);
  }

  @override
  void dispose() {
    // 【BUG-66 v3】dispose 中に `_stopLongPress()` を呼ぶと `setState()` 経由で
    // markNeedsBuild が走り、defunct Element assertion を発火する（Flutter の
    // `StatefulElement.unmount` は `state.dispose()` → `_element = null` の順で
    // 実行するため、dispose 実行中も `State.mounted` は true を返す。`if (mounted)`
    // ガードが効かない既知の Flutter 落とし穴）。
    // widget 破棄と同時に State 変数も消えるため、Timer のキャンセルだけ直接行えば
    // 十分（_isLongPressing / _currentInterval / _isHolding のリセットは不要）。
    _longPressTimer?.cancel();
    _longPressTimer = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final meta = _statMeta[widget.stat.name];
    final icon = meta?.$1 ?? '⭐';
    final color = meta?.$2 ?? AppTheme.primary;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Text(icon, style: const TextStyle(fontSize: 20)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      StatHexagonChart.fullNameFor(
                          AppLocalizations.of(context)!, widget.stat.name),
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                    Text(
                      'Lv.${widget.stat.level}',
                      style: TextStyle(
                        color: color,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                // FEAT-119: TweenAnimationBuilder で EXP バーを滑らかにアニメーション。
                // 長押し中の連続割り振りでも各更新ごとに 250ms easeOut が走り、
                // 流れるような増加感が生まれる。
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: TweenAnimationBuilder<double>(
                    tween: Tween<double>(
                      begin: _prevExpRate,
                      end: widget.stat.expRate,
                    ),
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOut,
                    builder: (_, value, __) => LinearProgressIndicator(
                      value: value,
                      minHeight: 4,
                      backgroundColor: Colors.white.withValues(alpha: 0.1),
                      valueColor: AlwaysStoppedAnimation<Color>(color),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 40,
            height: 34,
            child: widget.canAllocate
                ? _loading
                    ? const Center(
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.orange,
                          ),
                        ),
                      )
                    : GestureDetector(
                        // FEAT-110: 短押し → ElevatedButton の onPressed 競合を避けるため
                        // onTap で処理（長押し認識前に発火する tap を正しくハンドル）
                        onTap: () async {
                          if (_isLongPressing) return; // 長押し中は短押し無効
                          setState(() => _loading = true);
                          await widget.onAllocate();
                          if (mounted) setState(() => _loading = false);
                        },
                        // FEAT-110: 指を置いた瞬間（500ms 前）にボタン外観を変える
                        onLongPressDown: (_) {
                          // BUG-41: ダイアログ closing 中の遅延配信に備えて mounted ガード
                          if (mounted) setState(() => _isHolding = true);
                        },
                        // FEAT-110: 長押し認識完了 → 連続配分開始 + ハプティック
                        onLongPressStart: (_) => _startLongPress(),
                        onLongPressEnd: (_) => _stopLongPress(),
                        onLongPressCancel: () {
                          // BUG-41: ポイント枯渇で自動 close する瞬間に発火する経路あり
                          if (mounted) setState(() => _isHolding = false);
                          _stopLongPress();
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 100),
                          width: 40,
                          height: 34,
                          decoration: BoxDecoration(
                            // FEAT-110: 保持中は少し暗く（視覚フィードバック）
                            color: _isHolding
                                ? Colors.deepOrange.shade700
                                : Colors.orange,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          transform: _isHolding
                              ? (Matrix4.identity()..scale(0.92))
                              : Matrix4.identity(),
                          transformAlignment: Alignment.center,
                          child: const Center(
                            child: Text(
                              '+',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 自動配分サマリーパネル（達成比率連動 10pt 自動付与の通知）
// ─────────────────────────────────────────────────────────────────────────────

class _AutoAllocationsPanel extends StatelessWidget {
  final Map<String, int> allocations;
  const _AutoAllocationsPanel({required this.allocations});

  // BUG-38: 旧実装はここで _icons を独立定義していたが、ファイル冒頭の
  // _statMeta と同じ値の重複だったため削除し、_statMeta に一本化する。
  static const _order = ['運動力', '学習力', '精神力', '健康力', '創造力', '貢献力']; // FEAT-171

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final sorted = _order
        .where((n) => allocations.containsKey(n))
        .map((n) => (n, allocations[n]!))
        .toList();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.tealAccent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.tealAccent.withValues(alpha: 0.30)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ヘッダー
          Row(
            children: [
              const Text('✨', style: TextStyle(fontSize: 13)),
              const SizedBox(width: 6),
              Text(
                l10n.sharedLevelUpDialogAutoAllocHeader,
                style: TextStyle(
                  color: Colors.tealAccent.withValues(alpha: 0.9),
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 各 stat の配分行
          ...sorted.map((entry) {
            final (name, pts) = entry;
            // BUG-38: _icons → _statMeta に切り替えて色定義を統一
            final meta  = _statMeta[name];
            final icon  = meta?.$1 ?? '⭐';
            final color = meta?.$2 ?? AppTheme.primary;
            return Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Text(icon, style: const TextStyle(fontSize: 13)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      StatHexagonChart.fullNameFor(l10n, name),
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                      ),
                    ),
                  ),
                  // EXP バー（pt を視覚化）
                  SizedBox(
                    width: 60,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: pts / 10,
                        minHeight: 4,
                        backgroundColor: Colors.white.withValues(alpha: 0.1),
                        valueColor: AlwaysStoppedAnimation<Color>(color),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '+${pts}pt',
                    style: TextStyle(
                      color: color,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            );
          }),
          const SizedBox(height: 4),
          Text(
            l10n.sharedLevelUpDialogAutoAllocNote,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.35),
              fontSize: 9,
            ),
          ),
        ],
      ),
    );
  }
}


// ─────────────────────────────────────────────────────────────────────────────
// 【FEAT-379 (2026-05-29)】結晶獲得演出パネル
// ─────────────────────────────────────────────────────────────────────────────

class _CrystalAwardPanel extends ConsumerWidget {
  final Map<String, int> crystalsAwarded;
  const _CrystalAwardPanel({required this.crystalsAwarded});

  static String _crystalName(AppLocalizations l10n, String key) {
    return switch (key) {
      'exercise'     => l10n.gamifStatsCrystalExercise,
      'learning'     => l10n.gamifStatsCrystalStudy,
      'health'       => l10n.gamifStatsCrystalHealth,
      'mental'       => l10n.gamifStatsCrystalMental,
      'creation'     => l10n.gamifStatsCrystalCreativity,
      'contribution' => l10n.gamifStatsCrystalContribution,
      _              => key,
    };
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n   = AppLocalizations.of(context)!;
    final player = ref.watch(playerNotifierProvider).valueOrNull;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.lightBlue.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.lightBlue.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('💎', style: TextStyle(fontSize: 16)),
              const SizedBox(width: 6),
              Text(l10n.gamifCrystalAwardedHeader,
                  style: const TextStyle(
                    color: Colors.lightBlueAccent,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  )),
            ],
          ),
          const SizedBox(height: 8),
          ...crystalsAwarded.entries
              .where((e) => e.value > 0)
              .map((entry) {
            final total = player?.crystals[entry.key] ?? 0;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  const Text('  ✨', style: TextStyle(fontSize: 12)),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      '${_crystalName(l10n, entry.key)} +${entry.value}',
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ),
                  if (total > 0)
                    Text(l10n.gamifCrystalTotalCount(total),
                        style: const TextStyle(color: Colors.white38, fontSize: 11)),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}
