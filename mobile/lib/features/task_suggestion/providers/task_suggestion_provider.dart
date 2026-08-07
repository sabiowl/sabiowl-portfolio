import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_client.dart';
import '../models/task_suggestion.dart';
import '../services/custom_suggestion_store.dart';  // 【2026-07-07】
import '../services/task_suggestion_service.dart';

/// 【FEAT-467 (2026-07-02)】タスク候補プロバイダー。
/// 手動プロバイダーパターン (CLAUDE.md「既存の手動プロバイダー feature は移行しない」)。

final taskSuggestionServiceProvider = Provider<TaskSuggestionService>((ref) {
  return TaskSuggestionService(ref.watch(apiClientProvider));
});

/// [type] = 'event' / 'todo' / 'habit'
/// ネットワーク失敗時は [] を返す (graceful degrade)。
///
/// 【2026-07-02 codebase_review 対応】旧 `FutureProvider.autoDispose.family` を
/// `FutureProvider.family` に変更。旧実装は popup 閉じるたびに provider 破棄 →
/// 再度開くたびに新規 HTTP 往復が発生し、予定 / ToDo / 習慣の追加コアループで
/// 「タップ → 往復待ち → 候補表示」の摩擦が毎回発生していた。
/// TaskSuggestion は admin が能動的に編集しない限り不変 (125 件、JSON で数十 KB)
/// のため、セッション中の常駐コストは小さく実質的な負荷はない。
/// これで「毎回」→「セッション中 1 回」に fetch 頻度を縮小、popup 再オープンは
/// 瞬時表示に戻る。
final taskSuggestionsProvider =
    FutureProvider.family<List<TaskSuggestion>, String>((ref, type) async {
  try {
    return await ref.watch(taskSuggestionServiceProvider).fetchSuggestions(type);
  } catch (_) {
    return const [];
  }
});

/// 【2026-07-07】端末ローカル (SharedPreferences) のカスタム候補一覧。
///
/// ユーザーが `TaskTitleSearchSheet` の「〜として新規追加」ボタンで追加した
/// タイトルを type ごとに保存 / 読出する。他ユーザーには一切露出しない
/// (Backend 送信ゼロ、DB 保存ゼロ)。
///
/// autoDispose = 検索 sheet を閉じた後 provider 破棄 → 次回開く時に SharedPreferences
/// から再 load。カスタム追加後の invalidate 不要 = 自然に最新化される。
///
/// 呼出側は `taskSuggestionsProvider` (master data) と本 provider の 2 つを watch
/// し、`TaskTitleSearchSheet._buildList` 内で merge (master 優先で dedup、custom
/// を bottom 追加) する。
final customSuggestionsProvider =
    FutureProvider.autoDispose.family<List<TaskSuggestion>, String>(
  (ref, type) async {
    return CustomSuggestionStore.load(type);
  },
);
