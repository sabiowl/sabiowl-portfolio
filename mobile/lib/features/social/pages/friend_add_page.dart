import 'package:flutter/material.dart';
import 'package:flutter/services.dart';  // 【FEAT-292】Clipboard / HapticFeedback
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/character_asset.dart';   // 【BUG-100】設定キャラアバター描画
import '../../../core/utils/friend_id_formatter.dart';  // 【2026-07-02】12 桁化 + 4-4-4 表示
import '../../../l10n/app_localizations.dart';
import '../../habits/models/player.dart';            // 【FEAT-292】Player モデル
import '../../habits/providers/habits_provider.dart'; // 【FEAT-292】playerNotifierProvider
import '../models/social_models.dart';
import '../providers/social_provider.dart';

class FriendAddPage extends ConsumerStatefulWidget {
  const FriendAddPage({super.key});

  @override
  ConsumerState<FriendAddPage> createState() => _FriendAddPageState();
}

class _FriendAddPageState extends ConsumerState<FriendAddPage> {
  final _controller = TextEditingController();
  SearchResult? _result;
  bool _loading = false;
  String? _error;
  bool _sending = false;
  bool _sent = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    // 【2026-07-02】ユーザー入力に `-` が混ざっていても清書して送信 (二重防御)。
    final id = stripFriendIdSeparators(_controller.text.trim());
    if (id.isEmpty) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _loading = true;
      _error = null;
      _result = null;
      _sent = false;
    });
    try {
      final result = await ref.read(socialServiceProvider).searchByFriendId(id);
      setState(() {
        _result = result;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = l10n.socialFriendAddPageNotFoundError;
        _loading = false;
      });
    }
  }

  Future<void> _sendRequest() async {
    // NEW-11: 関数冒頭で _sending もガード。
    if (_sending || _result == null) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() => _sending = true);
    try {
      await ref
          .read(socialServiceProvider)
          .sendFriendRequest(_result!.player.friendId);
      setState(() {
        _sending = false;
        _sent = true;
      });
      ref.invalidate(friendListProvider);
    } catch (e) {
      setState(() => _sending = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.socialFriendAddPageSendErrorSabi_message)),
        );
      }
    }
  }

  /// 【FEAT-292】自分のフレンドIDをクリップボードへコピー。
  void _copyMyFriendId(String friendId) {
    final l10n = AppLocalizations.of(context)!;
    HapticFeedback.lightImpact();
    Clipboard.setData(ClipboardData(text: stripFriendIdSeparators(friendId)));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(l10n.socialFriendAddPageCopySuccessSabi_message),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // 【FEAT-292】自分のフレンドIDを表示する用 (profile_edit_page と同パターン)
    final playerAsync = ref.watch(playerNotifierProvider);
    final me = playerAsync.valueOrNull;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.socialFriendAddPageTitle)),
      // 【FEAT-292】SafeArea で Android の edge-to-edge + iOS のノッチ両対応。
      // SingleChildScrollView でキーボード出現時のオーバーフロー対策。
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── 自分のフレンドID（FEAT-292）──────────────────
              if (me != null) ...[
                _buildMyFriendIdCard(me),
                const SizedBox(height: 28),
              ],

              // ── 説明 ──────────────────────────────────────
              Text(
                l10n.socialFriendAddPageSearchSectionLabel,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(
                l10n.socialFriendAddPageSearchHint1,
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
              const SizedBox(height: 4),
              // 【2026-07-02】12 桁化に伴い注意書きを追加。
              Text(
                l10n.socialFriendAddPageSearchHint2,
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
              const SizedBox(height: 16),

              // ── 検索フォーム ───────────────────────────────
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      // 【FEAT-423 (2026-06-10) → 2026-07-02】8 → 12 桁数字。
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(12),
                      ],
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        hintText: l10n.socialFriendAddPageSearchFieldHint,
                        hintStyle: TextStyle(
                          color: Colors.white.withValues(alpha: 0.35),
                        ),
                        prefixIcon: const Icon(Icons.search,
                            color: Colors.white54),
                        filled: true,
                        // 【FEAT-292】fillColor を AppTheme.surface から半透明白 tint に変更。
                        fillColor: Colors.white.withValues(alpha: 0.06),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 14),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                              color: Colors.white.withValues(alpha: 0.20)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(
                              color: AppTheme.primary, width: 2),
                        ),
                      ),
                      style: const TextStyle(color: Colors.white),
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _search(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton(
                    onPressed: _loading ? null : _search,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primary,
                      foregroundColor: Colors.white,
                      // 【FEAT-292 critical fix】Row 内で local override。
                      minimumSize: const Size(0, 48),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: _loading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : Text(l10n.socialFriendAddPageSearchButton),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // ── 検索結果 ───────────────────────────────────
              if (_error != null)
                Center(
                  child: Text(_error!,
                      style: const TextStyle(color: AppTheme.danger)),
                ),
              if (_result != null) _buildResult(_result!, l10n),
            ],
          ),
        ),
      ),
    );
  }

  /// 【FEAT-292】自分のフレンドIDカード（コピー導線つき）。
  Widget _buildMyFriendIdCard(Player me) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.30)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── セクションヘッダー ────────────────────────────
          Row(
            children: [
              const Icon(Icons.badge_outlined,
                  color: AppTheme.primary, size: 16),
              const SizedBox(width: 6),
              Text(
                l10n.socialFriendAddPageMyIdSectionLabel,
                style: const TextStyle(
                  color: AppTheme.primary,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            l10n.socialFriendAddPageMyIdHint,
            style: const TextStyle(color: Colors.white54, fontSize: 11),
          ),
          const SizedBox(height: 12),

          // ── ID + コピーボタン ───────────────────────────
          InkWell(
            onTap: () => _copyMyFriendId(me.friendId),
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(10),
                border:
                    Border.all(color: Colors.white.withValues(alpha: 0.10)),
              ),
              child: Row(
                children: [
                  Expanded(
                    // 【2026-07-02】12 桁化に伴い 4-4-4 (「0000-0000-0000」) 表示。
                    child: Text(
                      formatFriendId(me.friendId),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontFamily: 'monospace',
                        letterSpacing: 1.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.copy,
                      size: 20, color: AppTheme.primary),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResult(SearchResult result, AppLocalizations l10n) {
    final p = result.player;
    final relation = result.relation;

    Widget actionWidget;
    switch (relation) {
      case 'self':
        actionWidget = Text(l10n.socialFriendAddPageRelationSelf,
            style: const TextStyle(color: Colors.white38, fontSize: 13));
      case 'friend':
        actionWidget = Text(l10n.socialFriendAddPageRelationFriend,
            style: const TextStyle(color: Colors.green, fontSize: 13));
      case 'sent':
        actionWidget = Text(l10n.socialFriendAddPageRelationSent,
            style: const TextStyle(color: Colors.orange, fontSize: 13));
      case 'received':
        actionWidget = Text(l10n.socialFriendAddPageRelationReceived,
            style: const TextStyle(color: AppTheme.primary, fontSize: 13));
      default: // 'none'
        actionWidget = _sent
            ? Text(l10n.socialFriendAddPageRelationRequestSent,
                style: const TextStyle(color: Colors.green, fontSize: 13))
            : ElevatedButton.icon(
                onPressed: _sending ? null : _sendRequest,
                // 【BUG-100 (2026-06-14)】Size(0, 48) で local override。
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(0, 48),
                ),
                icon: _sending
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.person_add, size: 16),
                label: Text(l10n.socialFriendAddPageSendRequestButton),
              );
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        // 【FEAT-292】AppTheme.card で十分なコントラストを確保。
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
      ),
      child: Row(
        children: [
          // 【BUG-100 (2026-06-14)】設定キャラ画像で表示。
          CharacterAsset.circleWidget(
            identifier: p.activeCharacterImagePath,
            keyFallback: p.activeCharacterKey,
            size: 56,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p.name,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 15)),
                const SizedBox(height: 2),
                Text('Lv.${p.level}  ID: ${formatFriendId(p.friendId)}',
                    style: const TextStyle(
                        color: Colors.white38, fontSize: 12)),
                if (p.title != null)
                  Text(p.title!,
                      style: const TextStyle(
                          color: Colors.orange, fontSize: 11)),
              ],
            ),
          ),
          actionWidget,
        ],
      ),
    );
  }
}
