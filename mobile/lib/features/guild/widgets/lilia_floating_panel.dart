import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// 【FEAT-315】ホーム画面下部からスライド表示するリリアの吹き出しパネル。
///
/// 用途は **バトル勝利直後のホーム画面遷移時** に「お見事です!」表示する
/// Comeback Ceremony 形式。`OverlayEntry` ベースで描画し、`duration` 経過後に
/// 自動でフェードアウト + 自己 remove する（caller は lifecycle を意識不要）。
///
/// CLAUDE.md「リリアの口調ルール」契約:
/// - 「あなた様 / お客様」二人称、明朗、状況連動絵文字（🗡️ / ⚔️ / 🛡️ / 🌸 等）
/// - 感嘆符 OK（サビとの対比軸、サビ専用 🪶 は使わない）
///
/// 設計判断 (FEAT-315 §設計判断、CLAUDE.md「サビとリリアの絶対に出会わない保証」表
/// 拡張): リリアは原則ギルド画面のみだが、本パネルは「バトル勝利直後 3 秒のみ」
/// = ギルドからの業務帰路として例外的に許容。サビ聖域との接触は時間軸で分離。
class LiliaFloatingPanel extends StatefulWidget {
  const LiliaFloatingPanel({
    super.key,
    required this.message,
    this.duration = const Duration(seconds: 3),
  });

  final String   message;
  final Duration duration;

  /// Overlay 経由で表示する静的ヘルパー。caller は OverlayEntry の lifecycle
  /// を意識不要 (Pre-mortem #1 二重 remove は try/catch で許容)。
  ///
  /// Pre-mortem #3 対策: `rootOverlay: true` で **root overlay** に insert。
  /// ShellRoute のネストナビゲータに insert すると別シーン跨ぎで残るため。
  static OverlayEntry show(
    BuildContext context, {
    required String message,
    Duration duration = const Duration(seconds: 3),
  }) {
    final entry = OverlayEntry(
      builder: (_) => LiliaFloatingPanel(message: message, duration: duration),
    );
    Overlay.of(context, rootOverlay: true).insert(entry);
    // duration + フェードアウト 250ms 後に自動 remove。
    // try/catch で二重 remove (caller が手動 remove した等) を許容。
    Future.delayed(duration + const Duration(milliseconds: 250), () {
      try {
        entry.remove();
      } catch (_) {
        // 既に remove 済 / 未 mount の場合は無視（Pre-mortem #1）
      }
    });
    return entry;
  }

  @override
  State<LiliaFloatingPanel> createState() => _LiliaFloatingPanelState();
}

class _LiliaFloatingPanelState extends State<LiliaFloatingPanel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<Offset>   _slide;
  late final Animation<double>   _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _slide = Tween<Offset>(
      begin: const Offset(0, 1.0),  // 画面下から
      end:   Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));
    _opacity = Tween<double>(begin: 0, end: 1).animate(_ctrl);
    _ctrl.forward();

    // duration 経過後にフェードアウト (reverse で _slide / _opacity 両方戻る)。
    Future.delayed(widget.duration, () {
      if (!mounted) return;
      _ctrl.reverse();
    });
  }

  @override
  void dispose() {
    // CLAUDE.md BUG-66 v3: dispose 内 setState/Future 起動禁止、controller の
    // dispose のみ実行 (定数 dispose は internal の race を起こさない安全策)。
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return Positioned(
      left:   16,
      right:  16,
      bottom: bottomInset + 80,  // BottomNavigationBar (高さ ~56) の上に乗せる
      child: SlideTransition(
        position: _slide,
        child: FadeTransition(
          opacity: _opacity,
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: AppTheme.card,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppTheme.primary.withValues(alpha: 0.4)),
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.primary.withValues(alpha: 0.3),
                    blurRadius: 16,
                  ),
                ],
              ),
              child: Row(
                children: [
                  // リリアアイコン (Phase 3: assets/images/guild/lilia_dot_48.webp が
                  // 未配置でも errorBuilder の 🌸 fallback で初期リリース可、
                  // Pre-mortem #4 アセット不在許容)。
                  ClipOval(
                    child: Image.asset(
                      'assets/images/guild/lilia_dot_48.webp',
                      width:  40,
                      height: 40,
                      fit:    BoxFit.cover,
                      filterQuality: FilterQuality.none,
                      errorBuilder: (_, __, ___) => Container(
                        width: 40,
                        height: 40,
                        color: AppTheme.primary.withValues(alpha: 0.2),
                        alignment: Alignment.center,
                        child: const Text('🌸', style: TextStyle(fontSize: 22)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.message,
                      style: const TextStyle(
                        color:    Colors.white,
                        fontSize: 14,
                        height:   1.4,
                      ),
                    ),
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
