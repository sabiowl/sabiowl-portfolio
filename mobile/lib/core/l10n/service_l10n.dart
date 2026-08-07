/// 【FEAT-489 Phase 2D (2026-08-02)】BuildContext を持たない層から
/// [AppLocalizations] を参照するための単一アクセスポイント。
///
/// ## なぜ必要か
///
/// Phase 2A-2C で ARB 化した UI 層は `AppLocalizations.of(context)!` を使えるが、
/// 以下の層は BuildContext を持たないため同じ経路を使えず、Phase 2D に defer していた:
///
/// - `core/services/notification_service.dart` — Android 通知チャンネル名 / 通知本文
///   (`main()` の `runApp` 前に初期化される)
/// - `core/services/maintenance_service.dart` — `MaintenanceStatus.placeholderOn`
/// - `core/api/error_formatter.dart` / `dio_error_helper.dart` — API エラー fallback
///   (6 ファイル / 十数箇所から呼ばれる純粋関数)
/// - `core/services/iap_service.dart` — Exception の `toString()`
/// - `features/challenge/services/challenge_notification_service.dart`
///
/// これらすべてに `String` 引数を追加して呼び出し元から l10n 文字列を渡す案
/// (doc/dev/develop.md §Phase 2D option 1) は、`formatApiError` のように
/// 呼び出し箇所が多い純粋関数で churn が大きく、`static const` な通知チャンネル
/// 定義では構造的に成立しない。そこで **現在 locale の [AppLocalizations] を
/// 1 箇所に保持し、MaterialApp から同期する** 方式を採る。
///
/// ## ライフサイクル
///
/// 1. 初期値は **ja** (`lookupAppLocalizations(Locale('ja'))`)。
///    `main.dart` は BUG-27 対策で `locale: Locale('ja', 'JP')` 固定のため、
///    `runApp` 前に走る `NotificationService.initialize()` でもこれが正となる。
/// 2. `MaterialApp.router` の `builder` で [syncFrom] が毎 build 呼ばれ、
///    実際に解決された locale の [AppLocalizations] に更新される。
///    Phase 5 で言語切替 UI が入っても追加対応不要。
///
/// ## テスト
///
/// [debugSetLocale] で任意 locale を注入できる。`tearDown` で
/// `debugSetLocale(const Locale('ja'))` に戻すこと。
library;

import 'package:flutter/widgets.dart';

import '../../l10n/app_localizations.dart';

/// service 層 / const 定義から参照する [AppLocalizations] のホルダー。
class ServiceL10n {
  ServiceL10n._();

  static AppLocalizations _current = lookupAppLocalizations(const Locale('ja'));

  /// 現在 locale の [AppLocalizations]。BuildContext 不要。
  ///
  /// UI 層 (BuildContext を持つ widget) では **本 getter ではなく**
  /// `AppLocalizations.of(context)!` を使うこと。widget が Localizations の
  /// 変更で rebuild されなくなるため。
  static AppLocalizations get current => _current;

  /// MaterialApp 配下の context から現在 locale を同期する。
  ///
  /// `main.dart` の `MaterialApp.router` `builder` から呼ぶ。builder の context は
  /// Localizations の子孫 (公式仕様) なので `AppLocalizations.of` が解決できる。
  /// 万一解決できない場合は既存値を維持する (起動直後に null を掴まないための防御)。
  static void syncFrom(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (l10n != null) _current = l10n;
  }

  /// テスト用に locale を差し替える。
  @visibleForTesting
  static void debugSetLocale(Locale locale) {
    _current = lookupAppLocalizations(locale);
  }
}
