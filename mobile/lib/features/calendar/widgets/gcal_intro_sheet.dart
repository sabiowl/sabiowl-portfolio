import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/sabi_icon.dart';  // 【FEAT-415 (2026-06-01)】sabi_unified.png 統一

/// FEAT-254 / FEAT-373: Google カレンダー連携 (v1.0 では取り込み専用) の事前説明シート用 SharedPreferences ヘルパー。
///
/// FEAT-244 で OAuth scope を `calendar.readonly` → `calendar.events` に拡張したため、
/// 既存連携ユーザー（readonly 承諾済）が同期する瞬間に Google の権限追加ダイアログ
/// が出る。初回のみサビ口調で事前説明を挟むことで「突然の権限要求」による
/// 信頼コストを軽減する。
///
/// 【FEAT-373 (2026-05-29)】v1.0 で push (Sabiowl → Google) 機能を構造的に廃止し、
/// 片方向同期 (Google → Sabiowl 取り込みのみ) に方針変更。シートの本文も「双方向同期」
/// 表現から「取り込み機能 + scope に書き込み権限が含まれるが Sabiowl からの書き込みは
/// 行わない」明示形式に書き換え済。v1.1+ で push 再開時にシート本文も再改訂する。
class GcalIntroPrefs {
  GcalIntroPrefs._();

  static const String _shownKey = 'gcal_bidirectional_intro_shown';

  /// 説明シートを既に表示済みなら true。`SharedPreferences` から読み出す。
  static Future<bool> hasBeenShown() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_shownKey) ?? false;
  }

  /// 説明シートを「表示済み」としてマークする。承諾画面へ進んだ場合のみ呼ぶ。
  static Future<void> markShown() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_shownKey, true);
  }
}

/// Google カレンダー連携 (v1.0: 取り込み専用、FEAT-373) の事前説明シート（FEAT-254）。
///
/// `showModalBottomSheet` 経由で表示し、ユーザーが「承諾画面へ進む」を選んだら
/// `true`、「今はやめておく」または背景タップで閉じたら `false / null` を返す。
/// caller 側が結果を見て同期実行を分岐する（CLAUDE.md「dialog 内 navigation 禁止」
/// パターンに準拠）。
///
/// サビ口調契約:
/// - 「あなた」二人称、「〜ますよ」「〜いただくと」紳士的トーン
/// - 感嘆符なし、文末 🪶 マーカー（タイトル横）
/// - 背景 / 主要ボタンは `AppTheme.primary`（`Colors.redAccent` 等の機械色は不使用）
class GcalIntroSheet extends StatelessWidget {
  const GcalIntroSheet({super.key});

  /// シートを表示し、ユーザーの選択結果を返す。
  ///
  /// 戻り値:
  /// - `true`  : 「承諾画面へ進む」 → 呼び出し側で同期実行
  /// - `false` : 「今はやめておく」 → 同期中止
  /// - `null`  : 背景タップ等で閉じた  → 同期中止
  static Future<bool?> show(BuildContext context) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.sheetBackground,
      // FEAT-254 hotfix: 小型画面でも 80% までシートが伸ばせるように上限緩和
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.8,
      ),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => const GcalIntroSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // FEAT-254 hotfix: 内部を SingleChildScrollView でラップして小型画面で
    // ボタン部分まで到達できるようにする。SafeArea で system nav bar 領域も回避。
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          left:   24,
          right:  24,
          top:    24,
          bottom: MediaQuery.of(context).viewInsets.bottom + 24,
        ),
        child: Column(
          mainAxisSize:       MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          // ── ヘッダー（サビの 🪶 マーカー + タイトル） ────────────────────
          // 【FEAT-415 (2026-06-01)】絵文字 🪶 → sabi_unified.png に統一。
          // SabiEmotion.wise (賢者) = 「Google カレンダー連携の説明、教えますね」の意味。
          Row(
            children: [
              const SabiIcon(emotion: SabiEmotion.wise, size: 32),
              const SizedBox(width: 12),
              Text(
                l10n.calendarGcalIntroTitle,
                style: const TextStyle(
                  fontSize:   20,
                  fontWeight: FontWeight.w600,
                  color:      Colors.white,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // ── 本文 1: 取り込み機能の説明 (FEAT-373 で双方向 → 片方向に改訂) ──
          Text(
            l10n.calendarGcalIntroBody1,
            style: const TextStyle(fontSize: 15, height: 1.6, color: Colors.white70),
          ),
          const SizedBox(height: 16),

          // ── 本文 2: 次に起こることの予告（信頼コスト軽減） ──────────────
          Text(
            l10n.calendarGcalIntroBody2,
            style: const TextStyle(fontSize: 15, height: 1.6, color: Colors.white70),
          ),
          const SizedBox(height: 16),

          // ── 本文 3: scope 注記 (FEAT-373 で必須化、法務文書整合性) ──────
          Text(
            l10n.calendarGcalIntroBody3,
            style: const TextStyle(fontSize: 12, height: 1.5, color: Colors.white54),
          ),
          const SizedBox(height: 28),

          // ── アクション（やめる / 進む） ────────────────────────────────
          Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    foregroundColor: Colors.white60,
                  ),
                  child: Text(l10n.calendarGcalIntroDismiss),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primary,
                    foregroundColor: Colors.white,
                    padding:         const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: Text(l10n.calendarGcalIntroAccept),
                ),
              ),
            ],
          ),
          ],
        ),
      ),
    );
  }
}
