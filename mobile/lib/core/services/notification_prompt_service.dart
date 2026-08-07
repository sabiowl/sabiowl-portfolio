import 'package:shared_preferences/shared_preferences.dart';

/// 通知ソフトプロンプトの表示履歴を管理するサービス。
///
/// SharedPreferences にフラグを保存し、
/// 一度表示済みのプロンプトを再表示しないように制御する。
class NotificationPromptService {
  static const _promptShownKey    = 'notification_prompt_shown';
  static const _repromptShownKey  = 'notification_reprompt_shown';

  /// ソフトプロンプトを表示すべきか（まだ一度も表示していない場合 true）
  static Future<bool> shouldShowPrompt() async {
    final prefs = await SharedPreferences.getInstance();
    return !(prefs.getBool(_promptShownKey) ?? false);
  }

  /// ソフトプロンプトを表示済みとしてマーク
  static Future<void> markPromptShown() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_promptShownKey, true);
  }

  /// 再プロンプト（設定アプリ誘導）を表示すべきか
  static Future<bool> shouldShowReprompt() async {
    final prefs = await SharedPreferences.getInstance();
    return !(prefs.getBool(_repromptShownKey) ?? false);
  }

  /// 再プロンプトを表示済みとしてマーク
  static Future<void> markRepromptShown() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_repromptShownKey, true);
  }
}
