import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/character_asset.dart';  // 【2026-06-14】キャラ画像表示
import '../../habits/providers/habits_provider.dart'
    show playerNotifierProvider;  // 【FEAT-523 Phase 3】交換ピース残高
import '../constants/exchange_piece_constants.dart';  // 【FEAT-523 Phase 3】
import '../models/gamification_models.dart';
// 【BUG-124 (2026-06-14)】FEAT-374 redo 用 gamification_provider import を撤去。
import '../providers/pending_reward_provider.dart';

// ─────────────────────────────────────────────────
// ステートマシン enum
// ─────────────────────────────────────────────────
enum _GachaTapState { tap1, tap2, tap3, revealing, done }

// ─────────────────────────────────────────────────
// レアリティカラー定数
// ─────────────────────────────────────────────────
const Map<String, Color> _rarityColors = {
  'N':   Color(0xFF9E9E9E),
  'R':   Color(0xFF42A5F5),
  'SR':  AppTheme.rarityPurple,
  'SSR': AppTheme.gold,
};

const Map<String, Color> _rarityGlowColors = {
  'N':   Color(0x339E9E9E),
  'R':   Color(0x5542A5F5),
  'SR':  Color(0x779C27B0),
  'SSR': Color(0xAAFFD700),
};

// ─────────────────────────────────────────────────
// 星パーティクル
// ─────────────────────────────────────────────────
class _StarParticle {
  final double x;
  final double startY;
  final double speed;
  final double size;
  final double wobble;
  final double wobbleSpeed;

  _StarParticle({
    required this.x,
    required this.startY,
    required this.speed,
    required this.size,
    required this.wobble,
    required this.wobbleSpeed,
  });
}

class _StarParticlePainter extends CustomPainter {
  final Animation<double> animation;
  final List<_StarParticle> particles;
  final Color color;

  _StarParticlePainter({
    required this.animation,
    required this.particles,
    required this.color,
  }) : super(repaint: animation);

  @override
  void paint(Canvas canvas, Size size) {
    final t     = animation.value;
    final paint = Paint()..style = PaintingStyle.fill;

    for (final p in particles) {
      final progress = ((t * p.speed) % 1.0);
      final y        = (p.startY + progress) % 1.0;
      final x        = p.x * size.width +
          p.wobble * math.sin(t * math.pi * 2 * p.wobbleSpeed);
      final opacity  = (1.0 - progress).clamp(0.0, 1.0);

      paint.color = color.withValues(alpha: opacity * 0.85);
      final half = p.size / 2;
      final path = Path()
        ..moveTo(x, y * size.height - half)
        ..lineTo(x + half * 0.4, y * size.height)
        ..lineTo(x, y * size.height + half)
        ..lineTo(x - half * 0.4, y * size.height)
        ..close();
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_StarParticlePainter _) => true;
}

List<_StarParticle> _generateParticles({
  required int count,
  required double minSize,
  required double maxSize,
}) {
  final rng = math.Random();
  return List.generate(count, (_) => _StarParticle(
    x:           rng.nextDouble(),
    startY:      -rng.nextDouble() * 0.5,
    speed:       0.3 + rng.nextDouble() * 0.5,
    size:        minSize + rng.nextDouble() * (maxSize - minSize),
    wobble:      (rng.nextDouble() - 0.5) * 60,
    wobbleSpeed: 1.0 + rng.nextDouble() * 2.0,
  ));
}

// ─────────────────────────────────────────────────
// GachaSummonPage（召喚専用画面）
// ─────────────────────────────────────────────────
class GachaSummonPage extends ConsumerStatefulWidget {
  final Future<GachaReward?> pullFuture;
  final String ticketType;
  final VoidCallback onCompleted;

  const GachaSummonPage({
    super.key,
    required this.pullFuture,
    required this.ticketType,
    required this.onCompleted,
  });

  @override
  ConsumerState<GachaSummonPage> createState() => _GachaSummonPageState();
}

class _GachaSummonPageState extends ConsumerState<GachaSummonPage>
    with TickerProviderStateMixin {

  _GachaTapState _tapState    = _GachaTapState.tap1;
  bool _introComplete          = false;
  GachaReward? _pendingReward;
  GachaReward? _lastReward;
  // 【BUG-124 (2026-06-14)】FEAT-374 もう 1 度引く廃止により _redoAvailable /
  // _redoLoading フィールドを撤去。
  List<_StarParticle> _particles = [];
  Color _particleColor = Colors.purple;
  Color _flashColor    = Colors.white;

  // ── AnimationController 群 ───────────────────────────────────
  late AnimationController _introController;     // 水晶登場スケールアップ
  late Animation<double>   _introScale;

  late AnimationController _floatController;     // アイドルフローティング
  late Animation<double>   _floatOffset;

  late AnimationController _loadingController;   // ローディング脈動
  late Animation<double>   _loadingScale;
  late Animation<double>   _loadingOpacity;

  late AnimationController _shakeController;     // シェイク
  late Animation<double>   _shakeOffset;

  late AnimationController _flashController;     // フラッシュ
  late Animation<double>   _flashOpacity;

  late AnimationController _cardController;      // 結果カードスライドイン
  late Animation<Offset>   _cardSlide;
  late Animation<double>   _cardFade;

  late AnimationController _particleController;  // パーティクル
  late AnimationController _glowController;      // カードグロー
  late Animation<double>   _glowPulse;

  // ─── セットアップ ──────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _setupAnimations();
    _startIntroAnimation();
  }

  void _setupAnimations() {
    // 水晶登場（500ms, elasticOut）
    _introController = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 500));
    _introScale = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _introController, curve: Curves.elasticOut));

    // フローティング（2s ±8px）
    _floatController = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2000));
    _floatOffset = Tween<double>(begin: -8, end: 8).animate(
      CurvedAnimation(parent: _floatController, curve: Curves.easeInOut));

    // ローディング脈動（800ms ループ）
    _loadingController = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 800));
    _loadingScale = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.15), weight: 50),
      TweenSequenceItem(tween: Tween(begin: 1.15, end: 1.0), weight: 50),
    ]).animate(CurvedAnimation(parent: _loadingController, curve: Curves.easeInOut));
    _loadingOpacity = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.7, end: 1.0), weight: 50),
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.7), weight: 50),
    ]).animate(_loadingController);

    // シェイク（400ms）
    _shakeController = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 400));
    _shakeOffset = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.0,   end: -12.0), weight: 10),
      TweenSequenceItem(tween: Tween(begin: -12.0, end:  12.0), weight: 20),
      TweenSequenceItem(tween: Tween(begin:  12.0, end:  -8.0), weight: 20),
      TweenSequenceItem(tween: Tween(begin:  -8.0, end:   8.0), weight: 20),
      TweenSequenceItem(tween: Tween(begin:   8.0, end:   0.0), weight: 30),
    ]).animate(_shakeController);

    // フラッシュ（500ms）
    _flashController = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 500));
    _flashOpacity = Tween<double>(begin: 0.85, end: 0.0).animate(
      CurvedAnimation(parent: _flashController, curve: Curves.easeOut));

    // カードスライドイン（600ms）
    _cardController = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 600));
    _cardSlide = Tween<Offset>(
      begin: const Offset(0, 0.4), end: Offset.zero,
    ).animate(CurvedAnimation(parent: _cardController, curve: Curves.easeOutCubic));
    _cardFade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _cardController, curve: Curves.easeIn));

    // パーティクル（2s）
    _particleController = AnimationController(
      vsync: this, duration: const Duration(seconds: 2));

    // グロー（1.2s ループ）
    _glowController = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1200));
    _glowPulse = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _glowController, curve: Curves.easeInOut));
  }

  void _startIntroAnimation() {
    _introController.forward().then((_) {
      if (!mounted) return;
      setState(() => _introComplete = true);
      _floatController.repeat(reverse: true);
      _loadingController.repeat();
    });
  }

  @override
  void dispose() {
    _introController.dispose();
    _floatController.dispose();
    _loadingController.dispose();
    _shakeController.dispose();
    _flashController.dispose();
    _cardController.dispose();
    _particleController.dispose();
    _glowController.dispose();
    super.dispose();
  }

  // ─── ハプティクス ────────────────────────────────────────────
  Future<void> _hapticForRarity(String rarity) async {
    switch (rarity) {
      case 'SSR':
        await HapticFeedback.vibrate();
        await Future.delayed(const Duration(milliseconds: 150));
        await HapticFeedback.vibrate();
        await Future.delayed(const Duration(milliseconds: 150));
        await HapticFeedback.vibrate();
      case 'SR':
        await HapticFeedback.heavyImpact();
      default:
        await HapticFeedback.lightImpact();
    }
  }

  // ─── タップハンドラ ──────────────────────────────────────────
  Future<void> _onGachaTap() async {
    // Tap1 → Tap2: シェイク
    if (_tapState == _GachaTapState.tap1) {
      HapticFeedback.lightImpact();
      setState(() => _tapState = _GachaTapState.tap2);
      _shakeController.forward(from: 0);
      return;
    }

    // Tap2 → Tap3: API 待機 → レアリティグロー
    if (_tapState == _GachaTapState.tap2) {
      try {
        final reward = await widget.pullFuture;
        if (!mounted) return;
        if (reward == null) throw Exception('報酬がありませんでした');
        _pendingReward = reward;
        HapticFeedback.mediumImpact();
        setState(() => _tapState = _GachaTapState.tap3);
      } catch (_) {
        if (!mounted) return;
        _handlePullError();
      }
      return;
    }

    // Tap3 → Revealing: 演出開始
    if (_tapState == _GachaTapState.tap3) {
      if (_pendingReward == null) return;
      setState(() => _tapState = _GachaTapState.revealing);
      _loadingController.stop();
      HapticFeedback.heavyImpact();
      await _runRevealSequence(_pendingReward!);
    }
  }

  void _handlePullError() {
    // pop 直後の dispose() 後に呼ばれた場合に setState / ScaffoldMessenger
    // でクラッシュしないようガード。
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() => _tapState = _GachaTapState.done);
    _loadingController.stop();
    // BUG-O: サーバ側でチケット消費・履歴作成は完了しているが、レスポンスがロストした
    // ケースに備えて「履歴を確認してね」を案内する。再引きでチケット不足になる体感バグを回避。
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.gamifGachaSummonNetworkErrorSabi_message),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 5),
      ),
    );
  }

  // ─── SSR/SR カットイン ────────────────────────────────────────
  Future<void> _showSsrCutIn() async {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.transparent,
      builder: (_) => const _SsrCutInDialog(),
    );
    await Future.delayed(const Duration(milliseconds: 1500));
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
  }

  Future<void> _showSrCutIn() async {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.transparent,
      builder: (_) => const _SrCutInDialog(),
    );
    await Future.delayed(const Duration(milliseconds: 900));
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
  }

  // ─── 演出シーケンス ──────────────────────────────────────────
  Future<void> _runRevealSequence(GachaReward reward) async {
    if (reward.rarity == 'SSR') {
      await _showSsrCutIn();
      if (!mounted) return;
    } else if (reward.rarity == 'SR') {
      await _showSrCutIn();
      if (!mounted) return;
    }

    _flashColor = switch (reward.rarity) {
      'SSR' => AppTheme.gold,
      'SR'  => AppTheme.rarityPurple,
      _     => Colors.white,
    };
    _flashController.reset();
    _flashController.forward();
    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;

    if (reward.rarity == 'SR' || reward.rarity == 'SSR') {
      final isSSR  = reward.rarity == 'SSR';
      _particleColor = isSSR ? AppTheme.gold : AppTheme.rarityPurple;
      _particles     = _generateParticles(
        count:   isSSR ? 50 : 25,
        minSize: isSSR ? 6.0 : 4.0,
        maxSize: isSSR ? 12.0 : 8.0,
      );
      _particleController.reset();
      _particleController.forward();
    } else {
      _particles = [];
    }

    setState(() {
      _tapState   = _GachaTapState.done;
      _lastReward = reward;
      // 【BUG-124】FEAT-374 redo ボタンは廃止 (_redoAvailable 撤去)
    });
    _cardController.reset();
    _cardController.forward();
    _glowController.repeat(reverse: true);

    await _hapticForRarity(reward.rarity);
  }

  // ─── ヒントテキスト ──────────────────────────────────────────
  String _hintText(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return switch (_tapState) {
      _GachaTapState.tap1      => _introComplete ? l10n.gamifGachaSummonOpenHintSabi_message : '',
      _GachaTapState.tap2      => '...',
      _GachaTapState.tap3      => l10n.gamifGachaSummonOpenButton,
      _GachaTapState.revealing => '',
      _GachaTapState.done      => '',
    };
  }

  // ─── build ───────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PopScope(
      canPop: _tapState == _GachaTapState.done,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) widget.onCompleted();
      },
      child: Scaffold(
        backgroundColor: AppTheme.surface,
        body: Stack(
          children: [
            // 背景グロー（intro に連動）
            AnimatedBuilder(
              animation: _introController,
              builder: (_, __) => Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      colors: [
                        AppTheme.primary.withValues(
                            alpha: 0.4 * _introController.value),
                        Colors.transparent,
                      ],
                      radius: 0.5,
                    ),
                  ),
                ),
              ),
            ),

            // メインコンテンツ
            SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      l10n.gamifGachaSummonningLabel,
                      style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 16,
                          letterSpacing: 2),
                    ),
                  ),
                  Expanded(child: _buildMainArea(context)),
                ],
              ),
            ),

            // パーティクルレイヤー
            if (_particles.isNotEmpty)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _StarParticlePainter(
                      animation: _particleController,
                      particles: _particles,
                      color: _particleColor,
                    ),
                  ),
                ),
              ),

            // フラッシュオーバーレイ
            AnimatedBuilder(
              animation: _flashOpacity,
              builder: (_, __) {
                if (_flashController.status == AnimationStatus.dismissed) {
                  return const SizedBox.shrink();
                }
                return Positioned.fill(
                  child: IgnorePointer(
                    child: Container(
                      color: _flashColor
                          .withValues(alpha: _flashOpacity.value),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // ─── メインエリア切り替え ────────────────────────────────────
  Widget _buildMainArea(BuildContext context) {
    if (_tapState == _GachaTapState.done && _lastReward != null) {
      return _buildRewardArea(context);
    }
    return _buildCrystalArea(context);
  }

  // ─── 水晶エリア（tap1〜revealing）────────────────────────────
  Widget _buildCrystalArea(BuildContext context) {
    final isRevealing = _tapState == _GachaTapState.revealing;
    final glowBase    = _tapState == _GachaTapState.tap3 && _pendingReward != null
        ? (_rarityColors[_pendingReward!.rarity] ?? AppTheme.primary)
        : AppTheme.primary;

    return GestureDetector(
      onTap: (_introComplete && !isRevealing) ? _onGachaTap : null,
      behavior: HitTestBehavior.opaque,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 水晶
            AnimatedBuilder(
              animation: Listenable.merge([
                _introController, _floatController,
                _loadingController, _shakeController,
              ]),
              builder: (_, __) {
                final showGlow = _tapState == _GachaTapState.tap3 &&
                    _pendingReward != null;
                return Transform.translate(
                  offset: Offset(
                    _shakeOffset.value,
                    _introComplete ? _floatOffset.value : 0.0,
                  ),
                  child: Transform.scale(
                    scale: _introScale.value * _loadingScale.value,
                    child: Opacity(
                      opacity: _loadingOpacity.value,
                      child: Container(
                        decoration: showGlow
                            ? BoxDecoration(
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: glowBase
                                        .withValues(alpha: 0.60),
                                    blurRadius: 40,
                                    spreadRadius: 10,
                                  ),
                                  BoxShadow(
                                    color: glowBase
                                        .withValues(alpha: 0.30),
                                    blurRadius: 80,
                                    spreadRadius: 4,
                                  ),
                                ],
                              )
                            : null,
                        child: const Text('🔮',
                            style: TextStyle(fontSize: 120)),
                      ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 16),

            // ヒントテキスト
            AnimatedOpacity(
              opacity: _hintText(context).isEmpty ? 0.0 : 1.0,
              duration: const Duration(milliseconds: 300),
              child: Text(
                _hintText(context),
                style: TextStyle(
                  color: _tapState == _GachaTapState.tap3 &&
                          _pendingReward != null
                      ? glowBase
                      : Colors.white54,
                  fontSize: 14,
                  fontWeight: _tapState == _GachaTapState.tap3
                      ? FontWeight.bold
                      : FontWeight.normal,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 【BUG-124 (2026-06-14)】FEAT-374「もう 1 度引く」機能を廃止 (PM 判断、必要性低)。
  // _onRedoTap / _redoAvailable / _redoLoading 一式を撤去。
  // Backend GachaRedoView endpoint + svc.redoLastPull() は backward compat のため残置
  // (旧 APK が叩いても 200 で処理可能、新規 Mobile からは呼ばない dead path)。

  // ─── 報酬エリア（done）──────────────────────────────────────
  Widget _buildRewardArea(BuildContext context) {
    final l10n  = AppLocalizations.of(context)!;
    final reward = _lastReward!;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      child: Column(
        children: [
          _buildRewardCard(reward),
          // 【FEAT-427 (2026-06-11)】マンスリー天井到達 → キャラ交換券 +1 を案内。
          if (reward.characterExchangeTicketAwarded) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: AppTheme.gold.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.gold.withValues(alpha: 0.5)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('🎟️', style: TextStyle(fontSize: 18)),
                  const SizedBox(width: 8),
                  Text(
                    l10n.gamifGachaSummonExchangeTicketToast,
                    style: const TextStyle(
                      color: AppTheme.gold,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          if (reward.isDuplicate && reward.pendingRewardId != null)
            _DuplicateRewardSelector(
              pendingRewardId: reward.pendingRewardId!,
              onExchanged: () {
                if (mounted) Navigator.of(context).pop();
              },
            )
          else
            // 【BUG-124 (2026-06-14)】「もう 1 度引く」廃止 (PM 判断、必要性低)。
            // 旧: FEAT-374 daily/weekly のみ表示 + monthly 非表示の if 分岐
            // 新: 全 ticket_type で非表示、「閉じる」のみ残す。
            // Backend GachaRedoView endpoint は backward compat のため残置
            // (旧 APK が叩いても 200 で処理可能、新規 Mobile からは呼ばない)。
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.gamifGachaSummonCloseButton,
                  style: const TextStyle(color: Colors.white38)),
            ),
        ],
      ),
    );
  }

  // ─── 結果カード ──────────────────────────────────────────────
  Widget _buildRewardCard(GachaReward reward) {
    final color         = _rarityColors[reward.rarity]     ?? const Color(0xFF9E9E9E);
    final glowColor     = _rarityGlowColors[reward.rarity] ?? const Color(0x339E9E9E);
    // 【FEAT-421 (2026-06-10)】container ラベル (🔮 魔法石 / 📦 宝箱) を廃止。
    // ユーザー報告「使い道が分からない」(2026-06-10) を受けて、世界観 flavor として
    // 配置していた container 概念ごと UI から削除。Backend の reward.container は
    // 既存データ保持のため温存 (将来 v1.1+ で再活用するなら復活可能)。

    return AnimatedBuilder(
      animation: _glowPulse,
      builder: (_, __) {
        final pulse = _glowPulse.value;
        return SlideTransition(
          position: _cardSlide,
          child: FadeTransition(
            opacity: _cardFade,
            child: Container(
              width: double.infinity,
              constraints: const BoxConstraints(minHeight: 220),
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  colors: [
                    color.withValues(alpha: 0.35),
                    AppTheme.cardBackground,
                  ],
                ),
                borderRadius: BorderRadius.circular(20),
                border:
                    Border.all(color: color.withValues(alpha: 0.7), width: 2),
                boxShadow: [
                  BoxShadow(
                      color: glowColor,
                      blurRadius: 24 * pulse,
                      spreadRadius: 4 * pulse),
                  BoxShadow(
                      color: glowColor,
                      blurRadius: 48 * pulse,
                      spreadRadius: 2 * pulse),
                ],
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // 【FEAT-421 (2026-06-10)】container ラベル Row を削除済。
                  const SizedBox(height: 24),
                  // 【2026-06-14】キャラ排出時はキャラ画像、それ以外は icon 表示。
                  // reward.character (= GrantedCharacterInfo) が非 null なら
                  // CharacterAsset.circleWidget で sprite 表示。
                  if (reward.character != null)
                    CharacterAsset.circleWidget(
                      identifier: reward.character!.imagePath,
                      keyFallback: reward.character!.imagePath,
                      size: 88,
                    )
                  else
                    Text(reward.icon, style: const TextStyle(fontSize: 52)),
                  const SizedBox(height: 8),
                  // 【2026-06-14】バッジの視認性改善: 旧 (背景 alpha 0.2 + 文字色
                  // 同色) は周囲 glow と同化して「SSR」が見えない問題があった。
                  // 背景を黒半透明にしてコントラスト確保、文字色は rarity color
                  // を維持して色味演出も両立。
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: color.withValues(alpha: 0.9), width: 1.2),
                      boxShadow: [
                        BoxShadow(
                            color: glowColor,
                            blurRadius: 8 * pulse,
                            spreadRadius: 1),
                      ],
                    ),
                    child: Text(reward.rarity,
                        style: TextStyle(
                            color: color,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            letterSpacing: 0.5)),
                  ),
                  const SizedBox(height: 8),
                  // 【2026-06-14】キャラ排出時は「キャラ名 (SSR)」、それ以外は
                  // 既存 reward.name (例: 「ダイヤ × 500」) 表示。
                  Text(
                    reward.character != null
                        ? '${reward.character!.name} (${reward.rarity})'
                        : reward.name,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 18),
                  ),
                  const SizedBox(height: 4),
                  // 【2026-06-14】キャラ排出時は detail (= 「未開放キャラから1体」)
                  // 非表示、それ以外は既存 detail (例: 「× 500」) 表示。
                  if (reward.character == null)
                    Text(reward.detail,
                        style: const TextStyle(
                            color: Colors.white60, fontSize: 12)),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────
// SSR カットインダイアログ
// ─────────────────────────────────────────────────
class _SsrCutInDialog extends StatefulWidget {
  const _SsrCutInDialog();

  @override
  State<_SsrCutInDialog> createState() => _SsrCutInDialogState();
}

class _SsrCutInDialogState extends State<_SsrCutInDialog>
    with TickerProviderStateMixin {
  late AnimationController _bgController;
  late Animation<double>   _bgOpacity;
  late AnimationController _textController;
  late Animation<double>   _textScale;
  late Animation<double>   _textOpacity;
  late AnimationController _pulseController;
  late Animation<double>   _pulseScale;

  @override
  void initState() {
    super.initState();
    _bgController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 400));
    _bgOpacity = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _bgController, curve: Curves.easeIn));

    _textController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 500));
    _textScale = Tween<double>(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(parent: _textController, curve: Curves.elasticOut));
    _textOpacity = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _textController, curve: Curves.easeIn));

    _pulseController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 500))
      ..repeat(reverse: true);
    _pulseScale = Tween<double>(begin: 0.97, end: 1.03).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut));

    _bgController.forward().then((_) {
      if (mounted) _textController.forward();
    });
  }

  @override
  void dispose() {
    _bgController.dispose();
    _textController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black,
      child: AnimatedBuilder(
        animation: Listenable.merge(
            [_bgController, _textController, _pulseController]),
        builder: (_, __) => Stack(
          alignment: Alignment.center,
          children: [
            Opacity(
              opacity: _bgOpacity.value,
              child: Container(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    colors: [
                      AppTheme.gold.withValues(alpha: 0.8),
                      const Color(0xFFFFA000).withValues(alpha: 0.4),
                      Colors.black,
                    ],
                    stops: const [0.0, 0.35, 0.8],
                    radius: 0.7,
                  ),
                ),
              ),
            ),
            Opacity(
              opacity: _textOpacity.value,
              child: Transform.scale(
                scale: _textScale.value * _pulseScale.value,
                child: const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('✨', style: TextStyle(fontSize: 56)),
                    SizedBox(height: 10),
                    Text(
                      'S  S  R',
                      style: TextStyle(
                        color: AppTheme.gold,
                        fontSize: 52,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 10,
                        shadows: [
                          Shadow(color: AppTheme.gold, blurRadius: 24),
                          Shadow(color: Colors.white, blurRadius: 8),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────
// SR カットインダイアログ
// ─────────────────────────────────────────────────
class _SrCutInDialog extends StatefulWidget {
  const _SrCutInDialog();

  @override
  State<_SrCutInDialog> createState() => _SrCutInDialogState();
}

class _SrCutInDialogState extends State<_SrCutInDialog>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double>   _scale;
  late Animation<double>   _opacity;
  late Animation<double>   _bgOpacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 700));
    _scale = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.elasticOut));
    _opacity = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeIn));
    _bgOpacity = Tween<double>(begin: 0, end: 0.7).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeIn));
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (_, __) => Stack(
          alignment: Alignment.center,
          children: [
            Opacity(
              opacity: _bgOpacity.value,
              child: Container(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    colors: [
                      AppTheme.rarityPurple.withValues(alpha: 0.8),
                      Colors.black,
                    ],
                    stops: const [0.0, 0.75],
                    radius: 0.65,
                  ),
                ),
              ),
            ),
            Opacity(
              opacity: _opacity.value,
              child: Transform.scale(
                scale: _scale.value,
                child: const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('💫', style: TextStyle(fontSize: 56)),
                    SizedBox(height: 10),
                    Text(
                      'S  R',
                      style: TextStyle(
                        color: Color(0xFFCE93D8),
                        fontSize: 52,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 10,
                        shadows: [
                          Shadow(
                              color: AppTheme.rarityPurple, blurRadius: 24),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────
// 重複報酬セレクター（done 状態で重複時に表示）
// ─────────────────────────────────────────────────
class _DuplicateRewardSelector extends ConsumerStatefulWidget {
  final int pendingRewardId;
  final VoidCallback onExchanged;

  const _DuplicateRewardSelector({
    required this.pendingRewardId,
    required this.onExchanged,
  });

  @override
  ConsumerState<_DuplicateRewardSelector> createState() =>
      _DuplicateRewardSelectorState();
}

class _DuplicateRewardSelectorState
    extends ConsumerState<_DuplicateRewardSelector> {
  bool _loading = false;

  /// 【FEAT-523 Phase 3】交換ピースの現在地を 1 行で返す。
  ///
  /// 残高は `playerNotifierProvider.exchangePieces` から取れるので、
  /// **新しい API も state も要らない** (ショップも同じ経路で読んでいる)。
  /// 到達済みならサビ口調の 1 行に切り替える。
  String _pieceProgressLabel(AppLocalizations l10n) {
    final pieces = ref.watch(playerNotifierProvider).valueOrNull?.exchangePieces ?? 0;
    final remaining = ExchangePieceConstants.remainingToTicket(pieces);
    if (remaining == 0) return l10n.gamifPieceReadyForTicketSabi_message;
    return '${l10n.gamifShopPieceBalance(pieces)} / '
        '${l10n.gamifPieceProgressToTicket(remaining)}';
  }

  Future<void> _exchange(String exchangeType) async {
    if (_loading) return;
    setState(() => _loading = true);
    final ok = await ref
        .read(pendingRewardsProvider.notifier)
        .exchange(widget.pendingRewardId, exchangeType);
    if (!mounted) return;
    setState(() => _loading = false);
    if (ok) {
      // 【FEAT-497 (2026-08-04)】pieces 経路を復活させたので、選んだ経路で
      // 文言を出し分ける。旧実装は 1 択前提で toast を固定していた。
      final l10n = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(exchangeType == 'pieces'
              ? l10n.gamifGachaPieceToast
              : l10n.gamifGachaStatPointToast),
          backgroundColor: AppTheme.primary,
        ),
      );
      widget.onExchanged();
    } else {
      final l10n = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.gamifGachaExchangeErrorSabi_message),
          backgroundColor: Colors.red.shade700,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // 【FEAT-497 (2026-08-04)】「交換ピース × 100」ボタンを復活。
    // v1.0 で撤去した理由は「dead currency = backend に消費経路ゼロ」だった。
    // Shop に消費先 3 種を用意したので、選ぶ意味のある 2 択に戻る。
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: Colors.orange.withValues(alpha: 0.4), width: 1.5),
      ),
      child: _loading
          ? const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : Column(
              children: [
                Text(
                  l10n.gamifGachaSummonDuplicateSabi_message,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.75),
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                _ExchangeOptionButton(
                  emoji: '⚡',
                  label: l10n.gamifGachaStatPointLabel,
                  onTap: () => _exchange('stat_points'),
                ),
                const SizedBox(height: 10),
                // 【FEAT-523 Phase 3】ピース側にだけ積み上げの現在地を添える。
                //
                // 重複時の 2 択には判断材料が 1 つも無く、しかも **数字の大きさが
                // 価値と逆向きに見える** — 「ステータスポイント × 5」と
                // 「交換ピース × 100」が並ぶと 100 の方が大きく見えるが、
                // 実際には 100 ピース = 交換券 1 枚 (500) の 1/5。
                // FEAT-497 は「重複 5 回で交換券 1 枚」という長期の積み上げ設計なのに、
                // **アプリで最も積み上げ的な選択肢が、唯一まったく積み上げを
                // 見せない画面で提示されている**状態だった。
                //
                // 文言はショップのピースタブと **同じ ARB キー**を使う (Pre-mortem #4)。
                _ExchangeOptionButton(
                  emoji: '🧩',
                  label: l10n.gamifGachaPieceLabel,
                  subLabel: _pieceProgressLabel(l10n),
                  onTap: () => _exchange('pieces'),
                ),
              ],
            ),
    );
  }
}

// ─────────────────────────────────────────────────
// 交換オプションボタン
// ─────────────────────────────────────────────────
class _ExchangeOptionButton extends StatelessWidget {
  final String emoji;
  final String label;

  /// 【FEAT-523 Phase 3】ラベルの下に添える補足 (交換ピースの現在地)。
  /// null なら従来どおり 1 行だけ描く。
  final String? subLabel;
  final VoidCallback onTap;

  const _ExchangeOptionButton({
    required this.emoji,
    required this.label,
    required this.onTap,
    this.subLabel,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          side: BorderSide(
              color: AppTheme.primary.withValues(alpha: 0.6)),
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(emoji, style: const TextStyle(fontSize: 18)),
                const SizedBox(width: 8),
                Text(label,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 13)),
              ],
            ),
            if (subLabel != null) ...[
              const SizedBox(height: 2),
              Text(
                subLabel!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6),
                  fontSize: 11,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
