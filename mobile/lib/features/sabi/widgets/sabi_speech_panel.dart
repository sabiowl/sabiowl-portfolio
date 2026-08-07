import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../providers/sabi_provider.dart';

/// 【2026-06-27】ホーム画面 AppBar 左上のサビセリフトグルパネル。
///
/// 表示位置: home_page の Stack 配下、`Positioned(top: 0)` の Column 内で
/// PlayerStatusFrame の **直下** に配置される。`_statusFrameOpen` が同時に
/// true でもステータス枠の下に並ぶため、構造的に重ならない設計。
///
/// 開閉: home_page の `_sabiPopoverOpen` state でトグル。AnimatedSize +
/// AnimatedOpacity で滑らかに開閉する。`onCloseTap` でユーザーが × タップで
/// 閉じる経路を提供 (再度サビアイコンタップでも閉じる)。
///
/// セリフ取得: 既存 `sabiMessageProvider` (sabi_provider.dart) を watch。
/// 読み込み中はサビアイコン + ローディング、エラーは fallback メッセージ。
class SabiSpeechPanel extends ConsumerWidget {
  final bool open;
  final VoidCallback onCloseTap;

  const SabiSpeechPanel({
    super.key,
    required this.open,
    required this.onCloseTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // open=false 時も AnimatedSize で 0 高さまで畳まれるよう IgnorePointer + opacity 0 で描画
    return IgnorePointer(
      ignoring: !open,
      child: AnimatedSize(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          opacity: open ? 1.0 : 0.0,
          child: open ? _buildPanel(context, ref) : const SizedBox.shrink(),
        ),
      ),
    );
  }

  /// 【2026-06-27】ネットワーク失敗時の世界観 fallback メッセージ。
  /// サビ口調統一原則 (CLAUDE.md): 二人称「あなた」省略、感嘆符なし、🪶 マーカー、
  /// 「ですね」「しましょうか」を採用。「電波が繋がらない」ような技術的表現を
  /// 避け、サビが「遠くから見ている」という世界観で穏やかに伝える。
  /// 【FEAT-489 Phase 2A】const から l10n 経由に変更 (ARB key: sabiSpeechPanelFallbackSabi_message)
  static String _fallbackMessage(BuildContext ctx) =>
      AppLocalizations.of(ctx)!.sabiSpeechPanelFallbackSabi_message;

  Widget _buildPanel(BuildContext context, WidgetRef ref) {
    final messageAsync = ref.watch(sabiMessageProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppTheme.primary.withValues(alpha: 0.28)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.20),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // サビ本体イラスト (sabi_unified.png) を円形にトリミング表示。
            // 【2026-06-27 ユーザー要望】左上 AppBar アイコンは silhouette を使い、
            // パネル内の「メッセージを話すサビ」はキャラ性のある sabi_unified を
            // 使う。同じシルエットだと「同じものを 2 回見せている」印象になるため。
            ClipOval(
              child: Container(
                width: 36,
                height: 36,
                color: AppTheme.primary.withValues(alpha: 0.18),
                child: Image.asset(
                  'assets/images/sabi/sabi_unified.webp',
                  width: 36,
                  height: 36,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const Icon(
                    Icons.pets,
                    color: AppTheme.primary,
                    size: 20,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            // セリフ本文 (loading / error / data の 3 状態)
            // 【2026-06-27】UX 改善:
            // - loading: 「メッセージを準備しています」を撤去 (ホーム画面側で
            //   ref.watch による prefetch 済のため、本来はここに来ない想定)。
            //   万一来ても fallback メッセージで世界観を壊さないようにする。
            // - error: 「もう一度試してみてください」のような技術的表現を撤回し、
            //   _kFallbackMessage (世界観準拠) に統一。
            // 【2026-07-05】pull-to-refresh flicker 修正:
            // 旧実装は reload 中 (sabiRefreshCounterProvider 変更で再フェッチ中)
            // にも messageAsync.when の loading コールバックが発火し、fallback
            // メッセージが一瞬表示されて「通常 → 遠いところに... → 通常」の
            // 3 段階 flicker が発生していた (ユーザー報告 2026-07-05)。
            // AsyncValue.when(skipLoadingOnReload: true) で reload 中は前回 data
            // を維持し、真に失敗した (error 到達) 場合のみ fallback を出す。
            // 60 秒タイムアウト後の error は「一定時間通信ができない」= ユーザーが
            // 望む fallback 表示条件と自然に一致する。
            // skipLoadingOnRefresh も同時に true にすることで、明示的な
            // ref.refresh(sabiMessageProvider) 経由でも同じ挙動になる (default true)。
            Expanded(
              child: messageAsync.when(
                skipLoadingOnReload:  true,
                skipLoadingOnRefresh: true,
                data: (msg) => Text(
                  msg.message,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
                // 初回コールドキャッシュ時のみ経由 (skipLoadingOnReload により
                // reload 中はスキップされ、前回 data が表示される)。
                loading: () => Text(
                  _fallbackMessage(context),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
                // 【2026-06-27】ネットワーク失敗時 (60 秒タイムアウト等)。
                // 世界観準拠のサビ fallback。
                error: (_, __) => Text(
                  _fallbackMessage(context),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            // 閉じる × ボタン
            InkResponse(
              onTap: onCloseTap,
              radius: 16,
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(
                  Icons.close,
                  size: 16,
                  color: Colors.white54,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
