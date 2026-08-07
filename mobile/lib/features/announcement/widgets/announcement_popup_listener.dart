import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';  // 【2026-06-27】キャラ画面へ遷移

import '../../../core/router/app_router.dart';   // 【2026-06-27】AppRoutes.character
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/character_asset.dart';  // 【2026-06-27】キャラ画像描画
import '../../../l10n/app_localizations.dart';
import '../models/announcement.dart';
import '../providers/announcement_provider.dart';

/// 【FEAT-458 (2026-06-21)】お知らせ popup listener (ホーム画面用)。
///
/// 設計:
///  - ホーム表示時に `unreadAnnouncementProvider` を watch、non-null なら
///    showDialog で popup 表示。
///  - popup 内: タイトル + 本文 + 「☐ 確認した」チェックボックス + 閉じるボタン。
///  - チェック → markRead API → ref.invalidate(unreadAnnouncementProvider)
///    → 次回ホーム再描画時には null returned (= popup 出ない)。
///  - 「閉じる」(チェックなし) はチェック未設定のまま閉じる = 次回ホーム再描画
///    時にも popup 出る (確認したと記録されないため)。
///  - 通知画面のお知らせタブからは引き続き再閲覧可能。
///
/// 【2026-06-27】新キャラ追加機能 (Gemini 要件) の拡張:
///  - linkCharacter (FK Character) 設定時、popup 本文上に「新キャラ プレビュー」
///    (画像 + 名前 + tagline) を表示
///  - 「詳細を見る」ボタンを追加、tap で markRead + popup close + AppRoutes.character へ push
///  - linkCharacter なし時は従来通り (チェックボックス + 閉じる/OK の 2 アクション)
///
/// 配置: home_page.dart の Stack 配下に const Positioned(top: 0, left: 0,
/// child: AnnouncementPopupListener()) で挿入する (FEAT-454 と同パターン)。
/// SizedBox.shrink を返すため UI には何も描画しない (純粋 listener)。
///
/// 二重発火防止:
///  - _showing フラグで同 instance 内の二重 showDialog を抑止。
///  - markRead API 成功で provider invalidate → null になるため次回も発火せず。
class AnnouncementPopupListener extends ConsumerStatefulWidget {
  const AnnouncementPopupListener({super.key});

  @override
  ConsumerState<AnnouncementPopupListener> createState() =>
      _AnnouncementPopupListenerState();
}

/// 【2026-06-27】popup の閉じる結果。
/// - confirmCheckbox = 「確認した」チェック付き OK → markRead のみ
/// - viewCharacterDetail = 「詳細を見る」tap → markRead + AppRoutes.character へ push
/// - dismissNoAction = 閉じる (チェックなし) → 何もしない
enum _AnnouncementPopupResult {
  confirmCheckbox,
  viewCharacterDetail,
  dismissNoAction,
}

class _AnnouncementPopupListenerState
    extends ConsumerState<AnnouncementPopupListener> {
  bool _showing = false;

  @override
  Widget build(BuildContext context) {
    // ホーム表示時に unread を watch。non-null になったら popup 発火。
    ref.listen<AsyncValue<Announcement?>>(unreadAnnouncementProvider,
        (prev, next) {
      final announcement = next.valueOrNull;
      if (announcement == null) return;
      if (_showing) return;
      _showPopup(context, announcement);
    });
    // 初回フェッチも明示的に watch (initState 代替、Riverpod 慣用パターン)
    ref.watch(unreadAnnouncementProvider);
    return const SizedBox.shrink();
  }

  Future<void> _showPopup(BuildContext context, Announcement announcement) async {
    _showing = true;
    // 【FEAT-489 Phase 2E】await をまたぐので l10n は先に capture する。
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);

    final result = await showDialog<_AnnouncementPopupResult>(
      context: context,
      barrierDismissible: false,  // 誤タップで閉じない (重要なお知らせを保護)
      builder: (ctx) => _AnnouncementDialog(announcement: announcement),
    );

    // 【2026-07-03 hotfix】旧実装は close 直後に _showing=false → markRead await
    // していたが、invalidate 発火時の再フェッチ中は AsyncValue が
    // `AsyncLoading(previous: 旧 Announcement)` になり `valueOrNull` が旧値を
    // 返すため、ref.listen callback が旧 announcement で再発火 → popup が
    // 「OK 押した直後にまた表示される」不具合になっていた。
    // 対策: markRead → invalidate → 再フェッチ完了 (AsyncData(null 等) が
    // 確定) するまで _showing=true を維持し、listen の再発火を構造的に抑止する。
    if (!mounted) {
      _showing = false;
      return;
    }

    final shouldMarkRead = result == _AnnouncementPopupResult.confirmCheckbox ||
        result == _AnnouncementPopupResult.viewCharacterDetail;

    if (shouldMarkRead) {
      try {
        await ref.read(announcementServiceProvider).markRead(announcement.id);
        if (!mounted) {
          _showing = false;
          return;
        }
        ref.invalidate(unreadAnnouncementProvider);
        // 再フェッチが確定するまで待機 (AsyncLoading の間 valueOrNull が旧値を
        // 返すことによる listen 再発火を防ぐ)。失敗しても以降の flow は継続。
        try {
          await ref.read(unreadAnnouncementProvider.future);
        } catch (_) {
          // 再フェッチエラーは既読化自体には影響なし、silent に握りつぶす。
        }
      } catch (e) {
        if (!mounted) {
          _showing = false;
          return;
        }
        messenger.showSnackBar(
          SnackBar(
            content: Text(l10n.announcementPopupMarkReadErrorSabi_message),
            backgroundColor: Colors.red,
          ),
        );
      }
    }

    // 【重要】ここで初めて _showing 解除。markRead → invalidate → 再フェッチ完了の
    // 後なので、この時点で AsyncData(null or 別 announcement) が確定しており、
    // listen が再発火しても旧 announcement では popup 出ない (要件通り)。
    _showing = false;

    if (!mounted) return;

    // 「詳細を見る」経路は markRead 完了を待ってからキャラ画面へ push
    // (popup の close → markRead → push の順序、provider invalidate が UI に
    // 反映されてから遷移するため stale state 表示を回避)。
    if (result == _AnnouncementPopupResult.viewCharacterDetail) {
      router.push(AppRoutes.character);
    }
  }
}

/// お知らせ popup ダイアログ本体。StatefulWidget で checkbox 状態を保持。
class _AnnouncementDialog extends StatefulWidget {
  const _AnnouncementDialog({required this.announcement});
  final Announcement announcement;

  @override
  State<_AnnouncementDialog> createState() => _AnnouncementDialogState();
}

class _AnnouncementDialogState extends State<_AnnouncementDialog> {
  bool _confirmed = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final a = widget.announcement;
    final link = a.linkCharacter;
    return AlertDialog(
      backgroundColor: AppTheme.surface,
      title: Row(
        children: [
          const Icon(Icons.campaign_outlined,
              color: AppTheme.primary, size: 24),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              a.title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 【2026-06-27】キャラ紐付き時は本文上にプレビューカード
            if (link != null) ...[
              _LinkCharacterPreview(link: link),
              const SizedBox(height: 12),
            ],
            // 【2026-06-27】お知らせ画像 (任意)。本文の上に大きく表示。
            // 旧 Backend (image_url=null) では非表示で safely fallback。
            // ローディング失敗時も errorBuilder で無表示にして popup 破壊回避。
            if (a.imageUrl != null && a.imageUrl!.isNotEmpty) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  a.imageUrl!,
                  fit: BoxFit.cover,
                  width: double.infinity,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
              const SizedBox(height: 12),
            ],
            Text(
              a.body,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              l10n.announcementPopupPublishedDate(
                a.publishedAt.year,
                a.publishedAt.month,
                a.publishedAt.day,
              ),
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
            const SizedBox(height: 12),
            // 「確認した」チェックボックス (タップで toggle)
            InkWell(
              onTap: () => setState(() => _confirmed = !_confirmed),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 22, height: 22,
                      child: Checkbox(
                        value: _confirmed,
                        onChanged: (v) =>
                            setState(() => _confirmed = v ?? false),
                        activeColor: AppTheme.primary,
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      l10n.announcementPopupConfirmCheckbox,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      // 【BUG-138 (2026-06-17)】Cancel 左 / Action 右の配置統一。
      // 【2026-06-27】link キャラあり時は「詳細を見る」を主動作として追加。
      // 「詳細を見る」tap は markRead を兼ねるため、チェックボックスの有無に関わらず
      // 常に有効化 (popup を再表示する意味がない)。
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.pop(context, _AnnouncementPopupResult.dismissNoAction),
          child: Text(l10n.announcementPopupCloseButton,
              style: const TextStyle(color: Colors.white54)),
        ),
        if (link != null)
          TextButton(
            onPressed: () => Navigator.pop(
                context, _AnnouncementPopupResult.viewCharacterDetail),
            style: TextButton.styleFrom(foregroundColor: AppTheme.primary),
            child: Text(l10n.announcementPopupViewDetailButton),
          )
        else
          TextButton(
            onPressed: _confirmed
                ? () => Navigator.pop(
                    context, _AnnouncementPopupResult.confirmCheckbox)
                : null,
            style: TextButton.styleFrom(
              foregroundColor: _confirmed ? AppTheme.primary : Colors.white24,
            ),
            child: const Text('OK'),
          ),
      ],
    );
  }
}

/// 【2026-06-27】linkCharacter 設定時に本文上に表示するプレビューカード。
/// 画像 + 名前 + tagline で「新キャラ ○○」をアピール、ユーザーに「詳細を見る」を
/// 押させる動線を作る。
class _LinkCharacterPreview extends StatelessWidget {
  const _LinkCharacterPreview({required this.link});
  final AnnouncementLinkCharacter link;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          // 円形キャラ画像 (CharacterAsset 経由で解決)
          ClipOval(
            child: CharacterAsset.circleWidget(
              identifier: link.imagePath,
              keyFallback: link.key,
              size: 56,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // 「NEW」バッジ + キャラ名
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                            color: Colors.orange.withValues(alpha: 0.6)),
                      ),
                      child: const Text(
                        'NEW',
                        style: TextStyle(
                          color: Colors.orange,
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        link.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                // tagline (空文字なら非表示)
                if (link.tagline.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    link.tagline,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 11,
                      height: 1.4,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
