import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../l10n/app_localizations.dart';
// timeline_models.dart は timeline_provider.dart から re-export されるため直接 import 不要
import '../providers/timeline_provider.dart';
import '../../habits/providers/apply_completion_result.dart';
import '../../habits/providers/habits_provider.dart'
    show playerNotifierProvider;
import '../../habits/providers/completion_effect_provider.dart';
import '../../../core/services/notification_service.dart';  // 【FEAT-273】完了時の通知キャンセル
import '../../calendar/providers/calendar_provider.dart'
    show googleEventCompletionServiceProvider;  // 【FEAT-426】

/// タイムラインの 1 イベントカード。
///
/// 左にレーン（時刻 + ノード円 + 点線）、右にカード本体。
/// タップで楽観的 UI による完了トグル、長押しで編集シートを開く。
class TimelineEventCard extends ConsumerStatefulWidget {
  const TimelineEventCard({
    super.key,
    required this.event,
    required this.isLast,
    required this.onLongPress,
  });

  final TimelineEvent event;
  final bool          isLast;
  final VoidCallback  onLongPress;

  @override
  ConsumerState<TimelineEventCard> createState() => _TimelineEventCardState();
}

class _TimelineEventCardState extends ConsumerState<TimelineEventCard>
    with SingleTickerProviderStateMixin {

  // ── 楽観的 UI ────────────────────────────────────────────
  bool _optimisticCompleted = false;

  // ── 長押しプログレスアニメーション（ステータスカードと同一 500ms）──
  late final AnimationController _pressController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  );

  bool _pressed            = false;
  bool _longPressActivated = false;

  // BUG-F: 連打ガード — complete / uncomplete API が走行中なら次のタップを無視。
  // 並列リクエストにより楽観的状態とサーバー実体が乖離するのを防ぐ。
  bool _toggleInFlight     = false;

  @override
  void initState() {
    super.initState();
    _optimisticCompleted = widget.event.isCompleted;
  }

  @override
  void didUpdateWidget(TimelineEventCard old) {
    super.didUpdateWidget(old);
    // API 更新が反映されたら楽観的状態を同期
    if (old.event.isCompleted != widget.event.isCompleted) {
      _optimisticCompleted = widget.event.isCompleted;
    }
  }

  @override
  void dispose() {
    _pressController.dispose();
    super.dispose();
  }

  // ── ジェスチャーハンドラー ────────────────────────────────

  void _onTapDown(TapDownDetails details) {
    _longPressActivated = false;
    HapticFeedback.lightImpact();
    _pressController.forward(from: 0.0);
    setState(() => _pressed = true);
    // ── 光エフェクト用: タップ座標を保存 ──────────────────────────────────
    // rewardToastProvider がセットされたとき home_page.dart のリスナーが
    // この座標を読み取り LightBeamOverlay を起動する（FEAT-44 の仕組みを流用）。
    ref.read(completionTapPositionProvider.notifier).state = details.globalPosition;
  }

  void _onTapUp(TapUpDetails _) {
    if (!_longPressActivated) {
      _toggleCompletion();
    }
    _resetPressState();
  }

  void _onTapCancel() => _resetPressState();

  void _onLongPress() {
    _longPressActivated = true;
    HapticFeedback.mediumImpact();
    widget.onLongPress();
    _resetPressState();
  }

  void _onLongPressCancel() => _resetPressState();

  void _resetPressState() {
    _pressController.reverse();
    if (mounted) setState(() => _pressed = false);
  }

  // ── 楽観的 UI + 完了トグル ────────────────────────────────

  Future<void> _toggleCompletion() async {
    // BUG-F: 走行中は無視 — 連打で complete / uncomplete が交互発火するのを防ぐ。
    if (_toggleInFlight) return;
    _toggleInFlight = true;

    final completing = !_optimisticCompleted;

    // 即座に UI を更新（楽観的）
    setState(() => _optimisticCompleted = completing);

    // 完了時は強め、取り消し時は弱め — 差をつけて「達成」の特別感を演出
    if (completing) {
      HapticFeedback.mediumImpact();
    } else {
      HapticFeedback.selectionClick();
    }

    // API 更新（バックグラウンド）
    try {
      // 【FEAT-426】Google カレンダー由来のイベントは GoogleEventCompletionService
      // 経由で google_event_id ベースの完了状態を更新する（実 Backend PK が無いため）。
      if (widget.event.isGoogleOrigin) {
        final googleEventId = widget.event.googleEventId!;
        final completionService = ref.read(googleEventCompletionServiceProvider);
        if (completing) {
          final result = await completionService.complete(
            googleEventId,
            widget.event.date,
            widget.event.startTime,
          );
          if (mounted) {
            final l10n = AppLocalizations.of(context)!;
            final message = result.onTimeBonusAwarded
                ? l10n.timelineEventCardOnTimeBonusSnackbarSabi_message(result.onTimeBonusCoin)
                : l10n.timelineEventCardCompletedSnackbarSabi_message;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(message),
                behavior: SnackBarBehavior.floating,
                duration: const Duration(seconds: 2),
              ),
            );
            if (result.onTimeBonusAwarded) {
              ref.invalidate(playerNotifierProvider);
            }
          }
        } else {
          await completionService.uncomplete(googleEventId);
        }
        ref.invalidate(timelineEventsProvider(widget.event.date));
        return;
      }

      final service = ref.read(timelineServiceProvider);
      if (completing) {
        // 未完了 → 完了: 専用エンドポイントで EXP・ダイヤを受け取る
        final reward = await service.completeEventWithReward(widget.event.id);
        // 【BUG-150 (2026-08-29)】レスポンス → provider の配線は共有関数 1 箇所。
        // この経路は元々 4 つとも拾えていた**唯一の正しい実装**だったが、
        // 同じ配線がカレンダー側に不完全な形で複製されていたため、
        // 両方を apply_completion_result.dart に寄せた。
        applyTimelineReward(ref.read, reward);
        if (reward.expGain > 0) {
          // BUG-19: EXP バー・レベル表示を更新（habits_provider.incrementCount と同等）
          ref.invalidate(playerNotifierProvider);
        }
        // 【FEAT-419 (2026-06-10)】予定時刻 ±15 分以内ボーナスの SnackBar 通知
        if (mounted) {
          final l10n = AppLocalizations.of(context)!;
          final message = reward.onTimeBonusAwarded
              ? l10n.timelineEventCardOnTimeBonusSnackbarSabi_message(reward.onTimeBonusCoin)
              : l10n.timelineEventCardCompletedSnackbarSabi_message;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(message),
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 2),
            ),
          );
          if (reward.onTimeBonusAwarded) {
            ref.invalidate(playerNotifierProvider);
          }
        }
        // 【FEAT-273】完了マークと同時に +15 分未完了リマインダーをキャンセル
        // （「完了でキャンセル → 未完了なら発火」を構造的に成立させる中核経路）。
        // 既存の開始時刻通知 (FEAT-226) は予定時刻 = 完了マーク後の過去になる
        // ため発火しないが、明示性のため合わせてキャンセルする。
        await NotificationService.cancelTimelineEventNotification(widget.event.id);
        await NotificationService.cancelTimelineUncompletedReminder(widget.event.id);
      } else {
        // 完了 → 未完了: 専用エンドポイント（EXP 変動なし・冪等）
        // BUG-B: 旧来の PATCH は read_only で silently 無視されていた。
        await service.uncompleteEvent(widget.event.id);
        // 【FEAT-273】完了取消で再度通知をスケジュール（未来予定 + ユーザー設定 ON 時）。
        // timeline_page.dart の ref.listen 経由で scheduleTodayTimelineNotifications が
        // 走るためここでは再スケジュール不要、invalidate に任せる。
      }
      ref.invalidate(timelineEventsProvider(widget.event.date));
    } catch (_) {
      // 失敗したら楽観的状態を元に戻す
      if (mounted) {
        setState(() => _optimisticCompleted = !completing);
        HapticFeedback.mediumImpact(); // エラー触感
      }
    } finally {
      _toggleInFlight = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = kTimelineCardColors[widget.event.category] ?? const Color(0xFF78909C);
    final icon  = kTimelineIconMap[widget.event.iconKey]    ?? Icons.event_outlined;

    return GestureDetector(
      onTapDown:         _onTapDown,
      onTapUp:           _onTapUp,
      onTapCancel:       _onTapCancel,
      onLongPress:       _onLongPress,
      onLongPressCancel: _onLongPressCancel,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── 左: タイムラインレーン ─────────────────────
            SizedBox(
              width: 52,
              child: Column(
                children: [
                  // 時刻ラベル
                  Text(
                    widget.event.startTime != null
                        ? _formatTime(widget.event.startTime!)
                        : '--:--',
                    style: const TextStyle(
                      color:      Colors.white38,
                      fontSize:   10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  // ノード円（楽観的状態に基づいてリアルタイム更新）
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width:  10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape:  BoxShape.circle,
                      color:  _optimisticCompleted ? color : Colors.transparent,
                      border: Border.all(color: color, width: 2),
                    ),
                  ),
                  // 垂直点線（最後のカード以外）
                  if (!widget.isLast)
                    Expanded(
                      child: CustomPaint(
                        painter: _DashedLinePainter(
                          color: color.withValues(alpha: 0.3),
                        ),
                      ),
                    ),
                ],
              ),
            ),

            const SizedBox(width: 8),

            // ── 右: カード本体（スケール + プログレスボーダー）──
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: AnimatedScale(
                  scale:    _pressed ? 0.97 : 1.0,
                  duration: const Duration(milliseconds: 100),
                  curve:    Curves.easeOut,
                  child: Stack(
                    children: [

                      // ① カード本体
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          color: color.withValues(
                              alpha: _optimisticCompleted ? 0.06 : 0.14),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: color.withValues(
                                alpha: _optimisticCompleted ? 0.18 : 0.35),
                          ),
                        ),
                        child: Row(
                          children: [
                            // カテゴリアイコン
                            Icon(icon, color: color, size: 20),
                            const SizedBox(width: 10),

                            // タイトル + 時刻
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize:       MainAxisSize.min,
                                children: [
                                  Text(
                                    widget.event.title,
                                    style: TextStyle(
                                      color: _optimisticCompleted
                                          ? Colors.white38
                                          : Colors.white,
                                      fontSize:        14,
                                      fontWeight:      FontWeight.bold,
                                      decoration: _optimisticCompleted
                                          ? TextDecoration.lineThrough
                                          : TextDecoration.none,
                                      decorationColor: Colors.white38,
                                    ),
                                  ),
                                  if (widget.event.endTime != null) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      widget.event.timeRangeLabel,
                                      style: const TextStyle(
                                        color:    Colors.white38,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),

                            // 完了インジケーター（AnimatedSwitcher でポップイン）
                            AnimatedSwitcher(
                              duration: const Duration(milliseconds: 200),
                              transitionBuilder: (child, animation) =>
                                  ScaleTransition(scale: animation, child: child),
                              child: _optimisticCompleted
                                  ? Icon(
                                      Icons.check_circle,
                                      key:   const ValueKey(true),
                                      size:  18,
                                      color: color.withValues(alpha: 0.85),
                                    )
                                  : Icon(
                                      Icons.radio_button_unchecked,
                                      key:   const ValueKey(false),
                                      size:  18,
                                      color: color.withValues(alpha: 0.35),
                                    ),
                            ),
                          ],
                        ),
                      ),

                      // ② 長押しプログレスボーダーオーバーレイ
                      Positioned.fill(
                        child: AnimatedBuilder(
                          animation: _pressController,
                          builder: (_, __) => CustomPaint(
                            painter: _EventBorderProgressPainter(
                              progress:     _pressController.value,
                              color:        color,
                              borderRadius: 14,
                            ),
                          ),
                        ),
                      ),

                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

// ── 垂直点線 CustomPainter ───────────────────────────────────────────────────

class _DashedLinePainter extends CustomPainter {
  const _DashedLinePainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const dashHeight = 4.0;
    const dashGap    = 3.0;
    final paint = Paint()
      ..color      = color
      ..strokeWidth = 1.5;

    double y = 0;
    while (y < size.height) {
      canvas.drawLine(
        Offset(size.width / 2, y),
        Offset(size.width / 2, y + dashHeight),
        paint,
      );
      y += dashHeight + dashGap;
    }
  }

  @override
  bool shouldRepaint(_DashedLinePainter old) => old.color != color;
}

// ── カード縁プログレスペインター ─────────────────────────────────────────────

/// カード縁に沿ってプログレスアークを描画する。
/// [home_page.dart] の _CardBorderProgressPainter と同一ロジック。
/// カテゴリカラーで光が滲んで見える（MaskFilter.blur によるグロー）。
class _EventBorderProgressPainter extends CustomPainter {
  const _EventBorderProgressPainter({
    required this.progress,
    required this.color,
    required this.borderRadius,
  });

  final double progress;
  final Color  color;
  final double borderRadius;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;

    final paint = Paint()
      ..color       = color.withValues(alpha: 0.85)
      ..strokeWidth = 2.5
      ..style       = PaintingStyle.stroke
      ..strokeCap   = StrokeCap.round
      ..maskFilter  = const MaskFilter.blur(BlurStyle.normal, 3);

    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Radius.circular(borderRadius),
    );
    final path    = Path()..addRRect(rect);
    final metrics = path.computeMetrics();
    for (final metric in metrics) {
      canvas.drawPath(metric.extractPath(0, metric.length * progress), paint);
    }
  }

  @override
  bool shouldRepaint(_EventBorderProgressPainter old) =>
      old.progress != progress || old.color != color;
}
