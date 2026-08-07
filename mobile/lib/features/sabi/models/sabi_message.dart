import '../../../shared/widgets/sabi_icon.dart';

/// Sabi メッセージ API の完全レスポンスモデル。
///
/// [message]   : サビのセリフ本文
/// [isRestDay] : 今日が休息日として登録済みか
/// [context]   : メッセージのコンテキスト種別（'achievement', 'streak', 'default' 等）
/// [emotion]   : 感情タグ（[SabiEmotion] にマップされる）
class SabiMessage {
  final String message;
  final bool isRestDay;
  final String context;
  final SabiEmotion emotion;

  const SabiMessage({
    required this.message,
    required this.isRestDay,
    required this.context,
    required this.emotion,
  });

  factory SabiMessage.fromJson(Map<String, dynamic> json) {
    return SabiMessage(
      message:   json['message']    as String? ?? '…。',
      isRestDay: json['is_rest_day'] as bool?  ?? false,
      context:   json['context']    as String? ?? 'default',
      emotion:   _parseEmotion(json['emotion'] as String? ?? 'normal'),
    );
  }

  /// 感情文字列 → [SabiEmotion] 変換。不明な値は [SabiEmotion.normal] にフォールバック。
  static SabiEmotion _parseEmotion(String value) {
    return SabiEmotion.values.firstWhere(
      (e) => e.name == value,
      orElse: () => SabiEmotion.normal,
    );
  }
}
