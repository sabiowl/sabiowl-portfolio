// 【FEAT-500 レビュー §C1 (2026-07-26)】メモ編集モーダル (Full screen bottom sheet)。
// memo_page.dart から分離、責務単一化 (~1600 行の巨大 file を 4 分割の 1 つ)。
//
// メモカードタップで起動、TextField に現 text を pre-fill。
// 保存 → callback で親の updateMemo 呼出、キャンセル → dismiss。
import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../models/free_memo.dart';

class MemoEditSheet extends StatefulWidget {
  final FreeMemo memo;
  final Future<void> Function(String newText) onSave;

  const MemoEditSheet({super.key, required this.memo, required this.onSave});

  @override
  State<MemoEditSheet> createState() => _MemoEditSheetState();
}

class _MemoEditSheetState extends State<MemoEditSheet> {
  late final TextEditingController _ctrl;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.memo.text);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _handleSave() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    if (text == widget.memo.text) {
      // 変更なしなら即閉じる (API 呼び出し不要)
      Navigator.pop(context);
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.onSave(text);
      // 成功時は親側で Navigator.pop 済 (onSave 内で対応)
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    return SafeArea(
      child: SizedBox(
        // full screen bottom sheet として画面の 75% を占める
        height: MediaQuery.of(context).size.height * 0.75 + viewInsets,
        child: Column(
          children: [
            // ── ヘッダー (キャンセル / タイトル / 保存) ──
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              decoration: const BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: Colors.white12),
                ),
              ),
              child: Row(
                children: [
                  TextButton(
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    child: Text(
                      l10n.commonCancel,
                      style: const TextStyle(color: Colors.white54),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    l10n.freeMemoEditSheetTitle,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: _saving ? null : _handleSave,
                    style:
                        TextButton.styleFrom(foregroundColor: AppTheme.primary),
                    child: _saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppTheme.primary,
                            ),
                          )
                        : Text(
                            l10n.freeMemoEditSheetSaveButton,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                  ),
                ],
              ),
            ),
            // ── TextField (multi-line 編集エリア) ──
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(
                  left: 16,
                  right: 16,
                  top: 16,
                  bottom: viewInsets + 16,
                ),
                child: TextField(
                  controller: _ctrl,
                  autofocus: true,
                  maxLength: 500,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  keyboardType: TextInputType.multiline,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    height: 1.5,
                  ),
                  decoration: InputDecoration(
                    hintText: l10n.freeMemoEditSheetTitle,
                    hintStyle: const TextStyle(color: Colors.white38),
                    border: InputBorder.none,
                    counterStyle: const TextStyle(color: Colors.white38),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
