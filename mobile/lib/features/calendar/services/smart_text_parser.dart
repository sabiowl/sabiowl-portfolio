import 'package:flutter/material.dart' show TimeOfDay;

/// QuickAdd テキスト入力から日付・優先度を自動抽出するパーサー（CAL-01）。
///
/// 例:
///   "明日までにレポート提出 #high"  → name="レポート提出", date=tomorrow, priority='high'
///   "来週月曜 読書 30分"            → name="読書 30分", date=next Monday
///   "今日中に買い物"                → name="買い物", date=today
class SmartTextParser {
  /// テキストを解析して [ParsedTask] を返す。
  static ParsedTask parse(String raw) {
    String text = raw.trim();

    // 1. 優先度タグを抽出（#high / #medium / #low）
    String priority = 'medium';
    text = text.replaceAllMapped(
      RegExp(r'#(high|medium|low|高|中|低)', caseSensitive: false),
      (m) {
        final tag = m.group(1)!.toLowerCase();
        priority = _normalizePriority(tag);
        return '';
      },
    ).trim();

    // 1.5. 時刻キーワードを抽出（優先度タグ削除後に処理）
    TimeOfDay? time;

    // 「HH:MM」
    final hhmm = RegExp(r'(\d{1,2}):(\d{2})').firstMatch(text);
    if (hhmm != null) {
      final h = int.tryParse(hhmm.group(1)!);
      final m = int.tryParse(hhmm.group(2)!);
      if (h != null && m != null && h < 24 && m < 60) {
        time = TimeOfDay(hour: h, minute: m);
        text = text.replaceAll(hhmm.group(0)!, '').trim();
      }
    } else {
      // 「HH時MM分」「HH時」
      final hourKana = RegExp(r'(\d{1,2})時((\d{1,2})分)?').firstMatch(text);
      if (hourKana != null) {
        final h = int.tryParse(hourKana.group(1)!);
        final m = int.tryParse(hourKana.group(3) ?? '0') ?? 0;
        if (h != null && h < 24) {
          time = TimeOfDay(hour: h, minute: m);
          text = text.replaceAll(hourKana.group(0)!, '').trim();
        }
      }
    }

    // 「午前HH時」「午後HH時」
    final ampm = RegExp(r'(午前|午後)(\d{1,2})時').firstMatch(text);
    if (time == null && ampm != null) {
      var h = int.tryParse(ampm.group(2)!) ?? 0;
      if (ampm.group(1) == '午後' && h < 12) h += 12;
      if (ampm.group(1) == '午前' && h == 12) h = 0;
      time = TimeOfDay(hour: h, minute: 0);
      text = text.replaceAll(ampm.group(0)!, '').trim();
    }

    // 時間帯キーワード（「朝」「昼」「夜」「深夜」）
    if (time == null) {
      if (RegExp(r'深夜|夜中').hasMatch(text)) {
        time = const TimeOfDay(hour: 23, minute: 0);
        text = text.replaceAll(RegExp(r'深夜|夜中'), '').trim();
      } else if (RegExp(r'夜').hasMatch(text)) {
        time = const TimeOfDay(hour: 20, minute: 0);
        text = text.replaceAll('夜', '').trim();
      } else if (RegExp(r'昼').hasMatch(text)) {
        time = const TimeOfDay(hour: 12, minute: 0);
        text = text.replaceAll('昼', '').trim();
      } else if (RegExp(r'朝').hasMatch(text)) {
        time = const TimeOfDay(hour: 9, minute: 0);
        text = text.replaceAll('朝', '').trim();
      }
    }

    // 2. 日付キーワードを抽出
    DateTime? date;
    final today = DateTime.now();
    final todayDate = DateTime(today.year, today.month, today.day);

    // 「今日」「本日」
    if (RegExp(r'今日|本日|今日中').hasMatch(text)) {
      date = todayDate;
      text = text.replaceAll(RegExp(r'今日中?に?|本日に?'), '').trim();
    }
    // 「明日」
    else if (RegExp(r'明日').hasMatch(text)) {
      date = todayDate.add(const Duration(days: 1));
      text = text.replaceAll(RegExp(r'明日(まで(に)?)?'), '').trim();
    }
    // 「明後日」
    else if (RegExp(r'明後日').hasMatch(text)) {
      date = todayDate.add(const Duration(days: 2));
      text = text.replaceAll(RegExp(r'明後日(まで(に)?)?'), '').trim();
    }
    // 「来週 + 曜日」
    else if (RegExp(r'来週').hasMatch(text)) {
      final dow = _extractDow(text);
      if (dow != null) {
        date = _nextWeekDow(todayDate, dow);
        text = text.replaceAll(RegExp(r'来週\s*[月火水木金土日]曜?'), '').trim();
      } else {
        date = todayDate.add(const Duration(days: 7));
        text = text.replaceAll('来週', '').trim();
      }
    }
    // 「今週 + 曜日」
    else if (RegExp(r'今週').hasMatch(text)) {
      final dow = _extractDow(text);
      if (dow != null) {
        date = _thisWeekDow(todayDate, dow);
        text = text.replaceAll(RegExp(r'今週\s*[月火水木金土日]曜?'), '').trim();
      }
    }
    // 単独の曜日（今週内）
    else {
      final dow = _extractDow(text);
      if (dow != null) {
        date = _thisWeekDow(todayDate, dow);
        text = text.replaceAll(RegExp(r'[月火水木金土日]曜?'), '').trim();
      }
    }

    // 「N日後」
    final daysLater = RegExp(r'(\d+)日後').firstMatch(text);
    if (daysLater != null) {
      final n = int.tryParse(daysLater.group(1)!);
      if (n != null) {
        date = todayDate.add(Duration(days: n));
        text = text.replaceAll(RegExp(r'\d+日後'), '').trim();
      }
    }

    // 「MM/DD」「M月D日」形式
    final mdSlash = RegExp(r'(\d{1,2})/(\d{1,2})').firstMatch(text);
    if (date == null && mdSlash != null) {
      final m = int.tryParse(mdSlash.group(1)!);
      final d = int.tryParse(mdSlash.group(2)!);
      if (m != null && d != null) {
        date = DateTime(todayDate.year, m, d);
        if (date.isBefore(todayDate)) {
          date = DateTime(todayDate.year + 1, m, d);
        }
        text = text.replaceAll(mdSlash.group(0)!, '').trim();
      }
    }
    final mdJp = RegExp(r'(\d{1,2})月(\d{1,2})日').firstMatch(text);
    if (date == null && mdJp != null) {
      final m = int.tryParse(mdJp.group(1)!);
      final d = int.tryParse(mdJp.group(2)!);
      if (m != null && d != null) {
        date = DateTime(todayDate.year, m, d);
        if (date.isBefore(todayDate)) {
          date = DateTime(todayDate.year + 1, m, d);
        }
        text = text.replaceAll(mdJp.group(0)!, '').trim();
      }
    }

    // 余分な助詞をトリム
    text = text.replaceAll(RegExp(r'^(に|で|を|は|が)\s*'), '').trim();
    text = text.replaceAll(RegExp(r'\s*(に|まで)\s*$'), '').trim();

    return ParsedTask(
      name:     text.isEmpty ? raw.trim() : text,
      date:     date,
      priority: priority,
      time:     time,
    );
  }

  // ── ヘルパー ──────────────────────────────────────────────────────────────

  static String _normalizePriority(String tag) {
    switch (tag) {
      case 'high':
      case '高':
        return 'high';
      case 'low':
      case '低':
        return 'low';
      default:
        return 'medium';
    }
  }

  /// テキスト中の曜日を抽出（0=月〜6=日）
  static int? _extractDow(String text) {
    const map = {'月': 0, '火': 1, '水': 2, '木': 3, '金': 4, '土': 5, '日': 6};
    for (final entry in map.entries) {
      if (RegExp('${entry.key}曜?').hasMatch(text)) return entry.value;
    }
    return null;
  }

  /// 今週の指定曜日（今日より先、なければ来週）
  static DateTime _thisWeekDow(DateTime today, int dow) {
    // Flutter: weekday 1=月…7=日。ここでは dow 0=月…6=日
    for (var i = 1; i <= 7; i++) {
      final d = today.add(Duration(days: i));
      if ((d.weekday - 1) % 7 == dow) return d;
    }
    return today.add(Duration(days: dow - today.weekday + 1 + 7));
  }

  /// 来週の指定曜日
  static DateTime _nextWeekDow(DateTime today, int dow) {
    final startOfNextWeek = today.add(Duration(days: 7 - today.weekday + 1));
    return startOfNextWeek.add(Duration(days: dow));
  }
}

/// [SmartTextParser.parse] の戻り値
class ParsedTask {
  final String     name;
  final DateTime?  date;
  final String     priority;  // 'high'|'medium'|'low'
  final TimeOfDay? time;       // 抽出された時刻（null = 未設定）

  const ParsedTask({
    required this.name,
    required this.date,
    required this.priority,
    this.time,
  });
}
