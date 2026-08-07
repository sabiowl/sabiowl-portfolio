import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/task_suggestion.dart';

/// 【2026-07-07】端末ローカル (SharedPreferences) にユーザーが「新規追加」した
/// タスクタイトル候補を保存する service。
///
/// ## 責務
///
/// `add_event_page` / `add_todo_page` / `add_habit_page` の **保存成功後** に、
/// 該当 form state (title + category + type 固有 field) を SharedPreferences に
/// persist する。次回同じ端末で検索するとカスタム候補として master data と
/// 一緒に表示される + 選択時に form 自動入力される。
///
/// **他ユーザーには露出しない**: Backend API に一切送信しない。DB 保存も無い。
///
/// ## Storage 仕様
///
/// - Key: `custom_suggestions_<type>_v1` (type = 'event' / 'todo' / 'habit')
/// - Value: `List<TaskSuggestion>` を JSON 文字列にエンコードして保存
/// - Cap: [_kMax] = 100 件 (端末容量保護、100 件を超えたら古いものを drop)
/// - Dedup: 大文字小文字を無視して同一 title は 1 件のみ (新規追加が最新扱い =
///   list の先頭に来る)
///
/// ## 冪等性
///
/// - 同一 title 再追加: 既存を削除して先頭に挿入 (最新扱い、form state 上書き)
/// - Cap 超過: `take(_kMax)` で古いものから自動 drop
/// - JSON parse 失敗: 空 list を返す (graceful degrade、破損したデータは無視)
///
/// ## 前回 hotfix からの差分 (2026-07-07)
///
/// 旧: `add(String type, String title)` — 「新規追加」ボタン押下時に title のみ保存
/// 新: `upsert(TaskSuggestion suggestion)` — 各 add page の **保存成功後** に
///     full form state で upsert。title のみの旧 entry (category='' 等) は次回
///     同 title を保存すれば full state で自動上書きされる = 自然に負債解消。
///
/// ## 将来拡張の余地 (v1.1+)
///
/// - Long-press で削除 UI (現状は追加のみ、UX 要望が来たら追加)
/// - export/import (端末移行対応)
class CustomSuggestionStore {
  CustomSuggestionStore._();

  static const int _kMax = 100;

  static String _key(String type) => 'custom_suggestions_${type}_v1';

  /// 指定 type のカスタム候補を JSON list から復元して返す。
  ///
  /// - key 未存在 → 空 list
  /// - JSON parse 失敗 → 空 list (破損データは silent skip)
  /// - 個別 entry の parse 失敗 → 当該 entry のみ skip
  static Future<List<TaskSuggestion>> load(String type) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(type));
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      final result = <TaskSuggestion>[];
      for (final e in decoded) {
        try {
          result.add(TaskSuggestion.fromJson(e as Map<String, dynamic>));
        } catch (_) {
          // 個別 entry 破損は skip (defensive)
        }
      }
      return result;
    } catch (_) {
      return const [];
    }
  }

  /// full form state 付き TaskSuggestion をカスタム候補として upsert。
  ///
  /// - `suggestion.title` が空文字なら no-op
  /// - 大文字小文字を無視した同一 title 既存 → 既存を削除して先頭に挿入
  ///   (最新扱い、form state を新しい値で上書き = "覚え直す" 挙動)
  /// - 100 件 cap 超過 → 古いものから drop
  ///
  /// 呼出側 (add_event_page 等) は master data に無い title のみを渡す想定
  /// (master 存在チェックは caller の責務)。fire-and-forget で呼び出し、
  /// 失敗しても save flow は継続 (try/catch で吞み込み)。
  static Future<void> upsert(TaskSuggestion suggestion) async {
    final trimmed = suggestion.title.trim();
    if (trimmed.isEmpty) return;

    final existing = await load(suggestion.type);
    // 大文字小文字を無視して dedup
    final normalized = trimmed.toLowerCase();
    final filtered = existing
        .where((s) => s.title.toLowerCase() != normalized)
        .toList();
    // 新規追加を先頭に (最新扱い = 最近覚え直したものが先頭に見える)
    filtered.insert(0, suggestion);
    // Cap
    final capped =
        filtered.length > _kMax ? filtered.sublist(0, _kMax) : filtered;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key(suggestion.type),
      jsonEncode(capped.map((e) => e.toJson()).toList()),
    );
  }

  /// テスト用: 指定 type のカスタム候補を全消去。v1.1+ の「全カスタム削除」
  /// 設定 UI 追加時に露出予定。
  static Future<void> clear(String type) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(type));
  }
}
