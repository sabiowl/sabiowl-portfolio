// サビの ToDo 関連セリフ定数。
// _TodoItem や TodoSection のサビヒント表示に使用する。
// 【FEAT-489 Phase 2A】const List<String> → AppLocalizations 関数に変換 (ARB 化)。

import '../../../l10n/app_localizations.dart';

/// ToDo 完了時のサビメッセージ一覧を返す。
/// context からロケールを解決するため AppLocalizations を受け取る。
List<String> sabiTodoDoneMessages(AppLocalizations l10n) => [
  l10n.sabiTodoDone1Sabi_message,
  l10n.sabiTodoDone2Sabi_message,
  l10n.sabiTodoDone3Sabi_message,
  l10n.sabiTodoDone4Sabi_message,
];

/// 持ち越し ToDo 時のサビメッセージ一覧を返す。
List<String> sabiTodoCarryoverMessages(AppLocalizations l10n) => [
  l10n.sabiTodoCarryover1Sabi_message,
  l10n.sabiTodoCarryover2Sabi_message,
  l10n.sabiTodoCarryover3Sabi_message,
  l10n.sabiTodoCarryover4Sabi_message,
];
