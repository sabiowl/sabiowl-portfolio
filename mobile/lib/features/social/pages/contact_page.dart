import 'dart:io' show File;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart'; // FEAT-440: FAQ 誘導

import '../../../core/constants/app_urls.dart';  // 【FEAT-463】URL 定数集約
import '../../../core/services/toast_center.dart'; // FEAT-440: launchUrl 失敗時
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../providers/social_provider.dart';

/// 【FEAT-366】お問い合わせ添付の枚数上限 (Backend と同期、case CONTACT_ATTACHMENT_MAX_COUNT)。
const _kMaxAttachments = 5;

/// 【FEAT-366】添付画像 1 枚あたりのサイズ上限 (Backend と同期、case CONTACT_ATTACHMENT_MAX_BYTES)。
const _kMaxAttachmentBytes = 2 * 1024 * 1024;

class ContactPage extends ConsumerStatefulWidget {
  const ContactPage({super.key});

  @override
  ConsumerState<ContactPage> createState() => _ContactPageState();
}

class _ContactPageState extends ConsumerState<ContactPage> {
  String _category = 'bug';
  final _titleController   = TextEditingController();
  final _contentController = TextEditingController();
  final _emailController   = TextEditingController();
  final _emailFocusNode    = FocusNode();
  bool _sending = false;
  bool _sent    = false;

  /// 【FEAT-366】添付画像リスト (最大 5 枚、`_kMaxAttachments`)。
  /// XFile は image_picker から返るクロスプラットフォーム抽象、path で `File` を得る。
  final List<XFile> _attachments = [];
  final _picker = ImagePicker();

  // Category keys with icons only; labels are resolved via _localizedCategoryLabel().
  static const _categories = [
    ('bug',     Icons.bug_report_outlined),
    ('feature', Icons.lightbulb_outlined),
    ('account', Icons.account_circle_outlined),
    ('other',   Icons.help_outline),
  ];

  /// Returns the localized display label for a category key.
  String _localizedCategoryLabel(String key, AppLocalizations l10n) {
    switch (key) {
      case 'bug':     return l10n.socialContactPageCategoryBugLabel;
      case 'feature': return l10n.socialContactPageCategoryFeatureLabel;
      case 'account': return l10n.socialContactPageCategoryAccountLabel;
      case 'other':   return l10n.socialContactPageCategoryOtherLabel;
      default:        return key;
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    _emailController.dispose();
    _emailFocusNode.dispose();
    super.dispose();
  }

  /// 【FEAT-440 (2026-06-17)】FAQ ページを OS 標準ブラウザで開く。
  Future<void> _openFaqExternally() async {
    final l10n = AppLocalizations.of(context)!;
    final uri = Uri.parse(kSabiowlFaqUrl);
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) {
        ToastCenter.showWarning(l10n.socialContactPageFaqOpenErrorSabi_message);
      }
    } catch (e) {
      debugPrint('[FEAT-440] launchUrl failed: $e');
      ToastCenter.showWarning(l10n.socialContactPageFaqOpenErrorSabi_message);
    }
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context)!;
    final content = _contentController.text.trim();
    final title   = _titleController.text.trim();
    final email   = _emailController.text.trim();

    if (content.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.socialContactPageContentEmptyError)));
      return;
    }

    // メール未入力の場合: ポップアップで連携を促す
    if (email.isEmpty) {
      final proceed = await _showEmailMissingDialog();
      if (!proceed) return;
    }

    // 【FEAT-435 (2026-06-17)】送信前確認ダイアログ。入力内容のプレビュー +
    // 規約違反コンテンツに関する注意書きを表示し、ユーザーの最終意思確認を取る。
    // 実際のフィルタリングは v1.1+ で Backend 実装予定、本 v1.0 では UI のみ。
    if (!mounted) return;
    final confirmed = await _showConfirmSendDialog(
      content: content,
      title: title.isNotEmpty ? title : null,
      email: email.isNotEmpty ? email : null,
      attachmentCount: _attachments.length,
    );
    if (!confirmed || !mounted) return;

    setState(() => _sending = true);
    try {
      await ref.read(socialServiceProvider).submitContact(
            _category,
            content,
            title: title,
            email: email,
            attachments: _attachments.isEmpty ? null : _attachments,
          );
      if (!mounted) return;
      setState(() {
        _sending = false;
        _sent    = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.socialContactPageSendErrorSabi_message)));
    }
  }

  /// 【FEAT-366】画像追加。pickMultiImage で複数選択可、imageQuality=85 で
  /// HEIC 自動 JPEG/PNG 変換 (Q2 案 Z)。5 枚上限に達したらこのボタン自体が disabled、
  /// この関数は呼ばれない設計だが、UI race の二重防御で remaining 計算してから add。
  Future<void> _pickImages() async {
    final l10n = AppLocalizations.of(context)!;
    final remaining = _kMaxAttachments - _attachments.length;
    if (remaining <= 0) return;
    try {
      final picked = await _picker.pickMultiImage(
        imageQuality: 85, // HEIC → JPEG 自動変換 + 品質ロスレス相当
      );
      if (picked.isEmpty) return;

      // 残スロット数で trim、超過分は破棄 (ユーザーに通知)
      final List<XFile> accepted = [];
      final List<String> rejected = [];
      int countAdd = 0;
      for (final f in picked) {
        if (countAdd >= remaining) {
          rejected.add(
              l10n.socialContactPageAttachmentRejectedSlotLimit(f.name));
          continue;
        }
        // サイズ検査 (Backend と同期、二重防御)
        final size = await File(f.path).length();
        if (size > _kMaxAttachmentBytes) {
          rejected.add(
              l10n.socialContactPageAttachmentRejectedTooLarge(f.name));
          continue;
        }
        accepted.add(f);
        countAdd++;
      }

      if (!mounted) return;
      setState(() => _attachments.addAll(accepted));

      if (rejected.isNotEmpty) {
        final msg = l10n.socialContactPageAttachmentPartialErrorSabi_message(rejected.join(', '));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg)),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.socialContactPageAttachmentPickErrorSabi_message)),
      );
    }
  }

  /// 【FEAT-366】添付画像 1 枚削除。
  void _removeAttachment(int index) {
    setState(() => _attachments.removeAt(index));
  }

  /// メールアドレス未入力時のダイアログ
  /// 戻り値: true = メールなしで送信する, false = キャンセルまたはメール入力画面へ
  Future<bool> _showEmailMissingDialog() async {
    final l10n = AppLocalizations.of(context)!;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        title: Text(l10n.socialContactPageEmailMissingDialogTitle,
            style: const TextStyle(color: Colors.white, fontSize: 16)),
        content: Text(
          l10n.socialContactPageEmailMissingDialogBody,
          style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: Text(l10n.commonCancel,
                style: const TextStyle(color: Colors.white38)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'skip'),
            child: Text(l10n.socialContactPageEmailMissingDialogSkipButton,
                style: const TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'set_email'),
            child: Text(l10n.socialContactPageEmailMissingDialogSetEmailButton,
                style: TextStyle(color: AppTheme.primary)),
          ),
        ],
      ),
    );

    if (!mounted) return false;

    switch (result) {
      case 'set_email':
        // メールアドレス欄にフォーカスを移す
        FocusScope.of(context).requestFocus(_emailFocusNode);
        return false;
      case 'skip':
        // メールなしで送信続行。focus を完全解除 (送信中はキーボード非表示が UX 標準)。
        // previouslyFocusedChild 指定で scope の focus memory もクリアし、
        // FocusTraversalPolicy による「次の focusable widget」への自動 focus を防ぐ。
        FocusScope.of(context).unfocus(
          disposition: UnfocusDisposition.previouslyFocusedChild,
        );
        return true;
      default:
        // キャンセル / ダイアログ外タップ: focus を完全解除してキーボードを閉じる。
        // Flutter のデフォルト UnfocusDisposition.scope では scope に focus が残り、
        // FocusTraversalPolicy が「scope 内最初の focusable widget = タイトル
        // TextField」に auto focus してしまうため、previouslyFocusedChild で
        // memory ごとクリアする (scope に focus を残さない)。
        FocusScope.of(context).unfocus(
          disposition: UnfocusDisposition.previouslyFocusedChild,
        );
        return false;
    }
  }

  /// 【FEAT-435 (2026-06-17)】送信前確認ダイアログ。
  ///
  /// 入力内容のプレビュー (カテゴリ / タイトル / 内容 / 返信先 / 添付枚数) と、
  /// 規約違反コンテンツに関する注意書き (橙色 InfoCard) を表示する。実際の
  /// フィルタリング処理は v1.1+ で Backend 実装予定、本 v1.0 では UI のみ。
  ///
  /// 戻り値: true = 送信続行、false = やめる / 外部タップで dismiss。
  /// ダイアログ Navigator.pop は dialogContext (= `ctx`) で実施 (FEAT-215 遵守)。
  Future<bool> _showConfirmSendDialog({
    required String content,
    required String? title,
    required String? email,
    required int attachmentCount,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    // カテゴリ key → label 変換 (例: 'bug' → 'バグ報告')
    final categoryLabel = _localizedCategoryLabel(_category, l10n);

    // 本文プレビュー: 200 文字までで truncate (長文 dialog overflow 回避)
    final contentPreview = content.length > 200
        ? '${content.substring(0, 200)}…'
        : content;

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        title: Text(l10n.socialContactPageConfirmDialogTitle,
            style: const TextStyle(color: Colors.white, fontSize: 16)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _reviewRow(l10n.socialContactPageConfirmDialogCategoryLabel, categoryLabel),
              if (title != null && title.isNotEmpty)
                _reviewRow(l10n.socialContactPageConfirmDialogTitleLabel, title),
              _reviewRow(l10n.socialContactPageConfirmDialogContentLabel, contentPreview),
              if (email != null && email.isNotEmpty)
                _reviewRow(l10n.socialContactPageConfirmDialogEmailLabel, email),
              if (attachmentCount > 0)
                _reviewRow(
                  l10n.socialContactPageConfirmDialogAttachmentRowLabel,
                  l10n.socialContactPageConfirmDialogAttachmentCountValue(attachmentCount),
                ),
              const SizedBox(height: 12),
              const Divider(color: Colors.white12, height: 1),
              const SizedBox(height: 12),
              // 規約違反の注意書き (橙色 InfoCard、v1.1+ で実フィルタが入る予告)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Colors.orange.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.info_outline,
                        color: Colors.orange, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l10n.socialContactPageConfirmDialogPolicyWarning,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.socialContactPageConfirmDialogCancelButton,
                style: const TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.primary),
            child: Text(l10n.socialContactPageSendButton),
          ),
        ],
      ),
    );

    return result == true;
  }

  /// 【FEAT-435 (2026-06-17)】送信前確認ダイアログ内の「ラベル + 値」行。
  /// 灰色の小さいラベル (11px) + 白い本文 (13px) の 2 段表示。
  Widget _reviewRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Colors.white38,
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (_sent) return _buildSuccess();

    return Scaffold(
      appBar: AppBar(title: Text(l10n.socialContactPageTitle)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 【FEAT-440 (2026-06-17)】FAQ 誘導バナー。お問い合わせ前に同じ質問が
            // 既に FAQ にあれば、先にそちらをご覧いただく動線を提供する。
            // 結果的に PM への問い合わせ流入を減らし、ユーザーも即時解決可能。
            _FaqInlineHint(onTap: _openFaqExternally),
            const SizedBox(height: 16),

            // ── カテゴリー選択 ─────────────────────────────
            Text(l10n.socialContactPageCategorySectionLabel,
                style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: _categories.map((c) {
                final (value, icon) = c;
                final label = _localizedCategoryLabel(value, l10n);
                final selected = _category == value;
                return GestureDetector(
                  onTap: () => setState(() => _category = value),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: selected
                          ? AppTheme.primary.withValues(alpha: 0.2)
                          : AppTheme.surface,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: selected
                            ? AppTheme.primary
                            : Colors.white.withValues(alpha: 0.1),
                        width: selected ? 1.5 : 1,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(icon,
                            size: 16,
                            color: selected
                                ? AppTheme.primary
                                : Colors.white38),
                        const SizedBox(width: 6),
                        Text(label,
                            style: TextStyle(
                                color: selected
                                    ? AppTheme.primary
                                    : Colors.white60,
                                fontSize: 13,
                                fontWeight: selected
                                    ? FontWeight.bold
                                    : FontWeight.normal)),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 24),

            // ── タイトル（任意）────────────────────────────
            Text(l10n.socialContactPageTitleSectionLabel,
                style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1)),
            const SizedBox(height: 10),
            TextField(
              controller: _titleController,
              maxLength: 100,
              decoration: InputDecoration(
                hintText: l10n.socialContactPageTitleHint,
                filled: true,
                // 【FEAT-293】AppTheme.surface (0xFF16213E) は Scaffold 背景
                // (0xFF1A1A2E) と近似色で Android では背景同化。friend_add_page
                // と同パターンで半透明白 tint に統一し、可視性を確保。
                fillColor: Colors.white.withValues(alpha: 0.06),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  // 【FEAT-293】枠線 alpha 0.1 → 0.20 で暗背景での視認性確保
                  borderSide:
                      BorderSide(color: Colors.white.withValues(alpha: 0.20)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(
                      color: AppTheme.primary, width: 2),
                ),
                counterStyle: const TextStyle(color: Colors.white38),
              ),
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
            const SizedBox(height: 24),

            // ── お問い合わせ内容 ───────────────────────────
            Text(l10n.socialContactPageContentSectionLabel,
                style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1)),
            const SizedBox(height: 10),
            TextField(
              controller: _contentController,
              maxLines: 8,
              maxLength: 1000,
              decoration: InputDecoration(
                hintText: l10n.socialContactPageContentHint,
                filled: true,
                // 【FEAT-293】AppTheme.surface (0xFF16213E) は Scaffold 背景
                // (0xFF1A1A2E) と近似色で Android では背景同化。friend_add_page
                // と同パターンで半透明白 tint に統一し、可視性を確保。
                fillColor: Colors.white.withValues(alpha: 0.06),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  // 【FEAT-293】枠線 alpha 0.1 → 0.20 で暗背景での視認性確保
                  borderSide:
                      BorderSide(color: Colors.white.withValues(alpha: 0.20)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(
                      color: AppTheme.primary, width: 2),
                ),
                counterStyle: const TextStyle(color: Colors.white38),
              ),
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
            const SizedBox(height: 24),

            // ── 添付画像（任意、最大 5 枚 / 2MB / 枚）────
            // 【FEAT-366】スクリーンショット添付で問題報告の精度を上げる。
            // image_picker.pickMultiImage() で複数選択 + サムネ表示 + 削除可能。
            _buildAttachmentSection(),
            const SizedBox(height: 24),

            // ── 返信先メールアドレス（任意）────────────────
            Text(l10n.socialContactPageEmailSectionLabel,
                style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1)),
            const SizedBox(height: 4),
            Text(
              l10n.socialContactPageEmailHint,
              style: const TextStyle(color: Colors.white30, fontSize: 11),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _emailController,
              focusNode: _emailFocusNode,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                hintText: 'example@email.com',
                prefixIcon:
                    const Icon(Icons.mail_outline, size: 18, color: Colors.white38),
                filled: true,
                // 【FEAT-293】AppTheme.surface (0xFF16213E) は Scaffold 背景
                // (0xFF1A1A2E) と近似色で Android では背景同化。friend_add_page
                // と同パターンで半透明白 tint に統一し、可視性を確保。
                fillColor: Colors.white.withValues(alpha: 0.06),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  // 【FEAT-293】枠線 alpha 0.1 → 0.20 で暗背景での視認性確保
                  borderSide:
                      BorderSide(color: Colors.white.withValues(alpha: 0.20)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(
                      color: AppTheme.primary, width: 2),
                ),
              ),
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
            const SizedBox(height: 32),

            // ── 送信ボタン ─────────────────────────────────
            ElevatedButton.icon(
              onPressed: _sending ? null : _submit,
              icon: _sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.send),
              label: Text(_sending ? l10n.socialContactPageSendingButton : l10n.socialContactPageSendButton),
              style: ElevatedButton.styleFrom(
                // 【FEAT-293】Size.fromHeight(50) = Size(∞, 50) を自己説明化。
                // Column 最下段の full-width 送信ボタンとして意図通り。
                minimumSize: const Size(double.infinity, 50),
              ),
            ),
            SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
          ],
        ),
      ),
    );
  }

  /// 【FEAT-366】添付画像セクション。
  /// 上段: 「画像 (N/5)」ラベル + 「画像を追加」ボタン (5 枚到達で disabled)。
  /// 下段: 選択済画像のサムネ Wrap、各サムネ右上に削除 × ボタン。
  Widget _buildAttachmentSection() {
    final l10n = AppLocalizations.of(context)!;
    final count = _attachments.length;
    final canAddMore = count < _kMaxAttachments;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              l10n.socialContactPageAttachmentSectionLabel(count, _kMaxAttachments),
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
            const Spacer(),
            // 5 枚到達時は disabled + 半透明
            TextButton.icon(
              onPressed: canAddMore ? _pickImages : null,
              icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
              label: Text(canAddMore
                  ? l10n.socialContactPageAttachmentAddButton
                  : l10n.socialContactPageAttachmentLimitButton),
              style: TextButton.styleFrom(
                foregroundColor: canAddMore ? AppTheme.primary : Colors.white24,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          l10n.socialContactPageAttachmentHint,
          style: const TextStyle(color: Colors.white30, fontSize: 11),
        ),
        if (_attachments.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (int i = 0; i < _attachments.length; i++)
                _buildAttachmentThumbnail(i, _attachments[i]),
            ],
          ),
        ],
      ],
    );
  }

  /// 【FEAT-366】サムネ 1 枚 + 削除 × ボタン (右上)。
  Widget _buildAttachmentThumbnail(int index, XFile file) {
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.file(
            File(file.path),
            width: 72,
            height: 72,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(
              width: 72,
              height: 72,
              color: AppTheme.surface,
              child: const Icon(Icons.broken_image_outlined,
                  color: Colors.white38),
            ),
          ),
        ),
        Positioned(
          top: 2,
          right: 2,
          child: GestureDetector(
            onTap: () => _removeAttachment(index),
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: const BoxDecoration(
                color: Colors.black54,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.close, size: 14, color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSuccess() {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.socialContactPageTitle)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: AppTheme.expColor.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.check_circle_outline,
                    size: 40, color: AppTheme.expColor),
              ),
              const SizedBox(height: 16),
              Text(l10n.socialContactPageSuccessTitle,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(
                l10n.socialContactPageSuccessBody,
                style: const TextStyle(color: Colors.white54, fontSize: 14),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(l10n.commonClose),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 【FEAT-440 (2026-06-17)】お問い合わせ画面トップに表示する FAQ 誘導バナー。
///
/// 「同じ質問が FAQ にあるかも知れません」とユーザーへ案内し、問い合わせ前に
/// 自己解決していただく動線を提供する。サビ口調 + 控えめなトーンで強要しない。
class _FaqInlineHint extends StatelessWidget {
  const _FaqInlineHint({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.primary.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: AppTheme.primary.withValues(alpha: 0.40),
            ),
          ),
          child: Row(
            children: [
              const Icon(Icons.help_outline,
                  size: 18, color: AppTheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  l10n.socialContactPageFaqHintSabi_message,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.open_in_new,
                  size: 14, color: AppTheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}
