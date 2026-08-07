import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../l10n/app_localizations.dart';

/// 【2026-07-02】ゲスト → 既存ユーザー衝突確認ダイアログ (FEAT-189 系)。
///
/// ゲストで積み上げたユーザーが Google / Apple アカウント連携を試みたとき、
/// そのアカウントが既に別ユーザーに紐付いていた場合の 2 択ダイアログ:
///   ・「切り替える」= 今のゲストデータを CASCADE 削除して既存アカウントへ合流
///   ・「ゲストを続ける」= ゲスト状態を保ったまま、別アカウントで再連携できる
///
/// 【共通化の背景】
/// 本ダイアログは以前 auth_page.dart (`_showPromoteConfirmDialog`) と
/// settings_page.dart (`_handleGuestPromoteConflict`) に **独立実装** されていた:
///   - AuthPage 経路: ゲストで始めた直後の Google/Apple サインイン試行 → 衝突
///   - 設定画面経路: 設定 → アカウント連携 → Google/Apple 選択 → 衝突
///
/// 2026-07-02 の赤字強調対応 (誤操作防止) で片方だけ修正して同期漏れが発生、
/// これを機に本 widget として抽出し、単一真実値化。今後の文言変更や配色変更は
/// 本ファイル 1 箇所の編集で 2 経路に反映される。
///
/// 【誤操作防止】
/// 「今のゲストデータは破棄され、既存アカウントでログインします。」の 1 行だけ
/// `AppTheme.danger (0xFFEF4444)` + `FontWeight.bold` で赤字強調し、視認性を
/// 高めて誤タップを抑止する。ダイアログ全体は AppTheme.card + rounded corner の
/// Sabiowl 標準アピアランス。ボタン配置は Cancel 左 / Action 右 (BUG-138 準拠)。
class GuestPromoteConflictDialog {
  GuestPromoteConflictDialog._();

  /// ダイアログを表示し、ユーザーの選択を返す。
  ///
  /// - [existingProvider]: `'google'` / `'apple'` / null。null または未知値は
  ///   Google 表記にフォールバックする (Backend 契約上 apple 以外は google と
  ///   同等の扱いのため)。
  /// - [existingUserName]: 衝突相手のユーザー名。空 / null なら「その」fallback。
  ///
  /// Returns:
  ///   - true : 「切り替える」を選択 → caller は `confirmPromote()` を実行
  ///   - false: 「ゲストを続ける」or barrier dismiss (barrierDismissible=false
  ///     なので事実上ボタン以外では閉じない) → caller はキャンセル処理
  static Future<bool> show({
    required BuildContext context,
    required String? existingProvider,
    required String? existingUserName,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final providerLabel = existingProvider == 'apple' ? 'Apple' : 'Google';
    // 【FEAT-489 (2026-08-06)】囲み文字を arb へ移した。
    //
    // 旧実装は `'「$existingUserName」'` と **日本語の鉤括弧を直書き**しており、
    // 英語 UI でも `linked to 「suzuki-taro」.` と表示されていた。
    // 囲み文字は locale ごとに違う (ja =「」/ en = curly quotes) ので、
    // Dart 側で組まず arb に持たせる。
    final existing = (existingUserName?.isNotEmpty ?? false)
        ? l10n.sharedGuestPromoteConflictDialogExistingName(existingUserName!)
        : l10n.sharedGuestPromoteConflictDialogExistingFallback;

    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        title: Text(
          l10n.sharedGuestPromoteConflictDialogTitle,
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
        content: Text.rich(
          TextSpan(
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 13,
              height: 1.5,
            ),
            children: [
              TextSpan(
                text: l10n.sharedGuestPromoteConflictDialogBodyIntro(providerLabel, existing),
              ),
              TextSpan(
                text: l10n.sharedGuestPromoteConflictDialogBodyWarning,
                style: const TextStyle(
                  color: AppTheme.danger,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const TextSpan(text: '\n'),
              TextSpan(
                text: l10n.sharedGuestPromoteConflictDialogBodyNote,
              ),
            ],
          ),
        ),
        // 【BUG-138 (2026-06-17)】Cancel 左 / Action 右の配置統一。
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              l10n.sharedGuestPromoteConflictDialogCancelButton,
              style: const TextStyle(color: Colors.white60),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.primary),
            child: Text(l10n.sharedGuestPromoteConflictDialogConfirmButton),
          ),
        ],
      ),
    );
    return ok == true;
  }
}
