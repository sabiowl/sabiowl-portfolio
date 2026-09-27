// 【FEAT-525 (2026-08-21)】チェックリスト項目の並び替え — 画面通しの検証。
//
// 「習慣を編集」画面でドラッグハンドルが出ているのに並び替えられない、という
// 報告への対応。ハンドルは UX-F08 でホーム画面から見た目だけ流用されており、
// `onReorder` は一度も存在していなかった。
//
// 本テストは **実際の画面 + 実際の Service + 実際の Dio** を通し、
// fake HttpClientAdapter が受けた PATCH / POST の body を検査する。
// (`onboarding_page_flow_test.dart` と同じ構成。)
//
// 縛る契約 (§5 Flutter):
//   A. `onReorder` が draft リストを並べ替える
//   B. 保存 body の `set_checklist_items` が **表示順どおり**
//   C. × で消した項目が body に含まれない
//   D. 新規項目が `id` なしで、**差し込んだ位置**に入っている
//   E. 🔴 旧 `add_/delete_checklist_items` を **併送しない** (backend が 400 にする)
//   F. 新規作成画面でも並び替えられる (`checklist_items` の配列順)
//   G. Pre-mortem #4: 項目 11 件でも例外なく描画できる
//      (`shrinkWrap` / `physics` を忘れると unbounded height で落ちる)

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sabiowl/core/api/api_client.dart';
import 'package:sabiowl/core/cache/cache_service.dart';
import 'package:sabiowl/features/habits/pages/add_habit_page.dart';
import 'package:sabiowl/features/habits/pages/edit_habit_page.dart';
import 'package:sabiowl/l10n/app_localizations.dart';

// ─────────────────────────────────────────────────────────────────────────────
// fake adapter — オフラインで Dio を回し、送信 body を記録する
// ─────────────────────────────────────────────────────────────────────────────

Map<String, dynamic> _habitJson(List<Map<String, dynamic>> items) => {
      'id': 1,
      'name': '朝の支度',
      'category': '健康',
      'frequency': 'daily',
      'reset_cycle': 'daily',
      'habit_type': 'checklist',
      'difficulty': 'normal',
      'order': 0,
      'streak': 0,
      'best_streak': 0,
      'total_count': 0,
      'total_exp': 0,
      'created_at': '2026-08-01',
      'is_active': true,
      'memo': '',
      'is_public': true,
      'priority': 'medium',
      'due_date': null,
      'today_log': null,
      'history': <String, dynamic>{},
      'checklist_items': items,
      'shield_active': false,
      'period_progress': null,
      'month_rates': <dynamic>[],
    };

List<Map<String, dynamic>> _items(List<String> texts) => [
      for (var i = 0; i < texts.length; i++)
        {'id': i + 1, 'text': texts[i], 'order': i, 'is_done': false},
    ];

class _RecordingAdapter implements HttpClientAdapter {
  final List<({String method, String path, dynamic data})> requests = [];
  List<Map<String, dynamic>> checklistItems = _items(['A', 'B', 'C']);

  Map<String, dynamic>? bodyOf(String method, String path) {
    for (final r in requests.reversed) {
      if (r.method == method && r.path == path) {
        final data = r.data;
        if (data is Map<String, dynamic>) return data;
        if (data is String) return jsonDecode(data) as Map<String, dynamic>;
      }
    }
    return null;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<dynamic>? cancelFuture,
  ) async {
    requests.add((method: options.method, path: options.path, data: options.data));
    final headers = {
      'content-type': ['application/json'],
    };

    if (options.path == '/habits/categories/') {
      return ResponseBody.fromString(
          jsonEncode(['運動', '学習', '健康', '精神']), 200, headers: headers);
    }
    if (options.path == '/habits/' && options.method == 'GET') {
      return ResponseBody.fromString(
          jsonEncode({'results': <dynamic>[], 'next_cursor': '', 'has_more': false}),
          200,
          headers: headers);
    }
    if (options.path == '/habits/' && options.method == 'POST') {
      return ResponseBody.fromString(
          jsonEncode(_habitJson(checklistItems)), 201, headers: headers);
    }
    if (options.path == '/habits/1/') {
      return ResponseBody.fromString(
          jsonEncode(_habitJson(checklistItems)), 200, headers: headers);
    }
    // それ以外 (SWR キャッシュ invalidate 等) は空 200 で吸収する
    return ResponseBody.fromString('{}', 200, headers: headers);
  }

  @override
  void close({bool force = false}) {}
}


// ── secure storage の in-memory mock ─────────────────────────────────────
//
// `ApiClient` は `FlutterSecureStorage` を直接持つので MethodChannel を差し替える。
// **mock しないと token 読み出しが解決せず、ページが loading のまま
// `pumpAndSettle` がタイムアウトする。**
void _installSecureStorageMock() {
  final values = <String, String>{};
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (call) async {
      final args = (call.arguments as Map?) ?? {};
      final key = args['key'] as String?;
      switch (call.method) {
        case 'read':
          return key == null ? null : values[key];
        case 'write':
          if (key != null) values[key] = args['value'] as String? ?? '';
          return null;
        case 'delete':
          if (key != null) values.remove(key);
          return null;
        case 'readAll':
          return Map<String, String>.from(values);
        case 'deleteAll':
          values.clear();
          return null;
        case 'containsKey':
          return key != null && values.containsKey(key);
        default:
          return null;
      }
    },
  );
}

({Widget widget, _RecordingAdapter adapter}) _buildApp(
  Widget page,
  SharedPreferences prefs,
) {
  final adapter = _RecordingAdapter();
  return (
    widget: ProviderScope(
      overrides: [
        apiClientProvider.overrideWith((ref) {
          final client = ApiClient(ref);
          client.dio.httpClientAdapter = adapter;
          return client;
        }),
        // 保存後の SWR キャッシュ invalidate が通る経路。未注入だと
        // `UnimplementedError` が飛び、保存そのものは成功しているのに
        // テストが赤くなる。
        cacheServiceProvider.overrideWithValue(CacheService(prefs)),
      ],
      child: MaterialApp(
        home: page,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('ja'),
      ),
    ),
    adapter: adapter,
  );
}


/// 「変更を保存する」ボタン (編集画面)。外側 `ListView` の下端にあるので
/// `ensureVisible` してから押す。
final _saveButton = find.text('変更を保存する');

/// チェックリスト項目の入力欄。
final _itemInput = find.widgetWithText(TextFormField, '項目を追加');

Future<void> _tapSave(WidgetTester tester) async {
  expect(_saveButton, findsOneWidget, reason: '保存ボタンが tree に無い');
  await tester.tap(_saveButton);
  await tester.pumpAndSettle();
}

/// `fromIndex` 行のハンドルを掴んで `toIndex` 行の位置まで運ぶ。
///
/// `ReorderableDragStartListener` 経由なので長押しは不要 (即ドラッグ開始)。
/// **一気に `moveBy` してはいけない。** `ReorderableListView` はドラッグ中に
/// 随時 drop 位置を再評価するので、実際の指の動きに近い小刻みな `moveTo` で
/// 運ばないと着地点がずれる。
Future<void> _dragHandleTo(WidgetTester tester, int fromIndex, int toIndex) async {
  final handles = find.byIcon(Icons.drag_indicator);
  expect(handles, findsWidgets, reason: 'ドラッグハンドルが描画されていない');
  final start = tester.getCenter(handles.at(fromIndex));
  final target = tester.getCenter(find.byType(ListTile).at(toIndex));

  final gesture = await tester.startGesture(start);
  await tester.pump(const Duration(milliseconds: 100));
  const steps = 12;
  for (var i = 1; i <= steps; i++) {
    await gesture.moveTo(
      Offset(start.dx, start.dy + (target.dy - start.dy) * i / steps),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await tester.pumpAndSettle();
}

// ─────────────────────────────────────────────────────────────────────────────
// テスト本体
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;

  setUp(() async {
    _installSecureStorageMock();
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  /// 縦に長い viewport にして、フォーム全体 (項目 11 件 + 保存ボタン) を
  /// 一度に build させる。既定の 800x600 だと外側 `ListView` の遅延生成で
  /// 保存ボタンが tree に存在せず、テストがスクロール操作の都合に振り回される。
  void useTallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  group('FEAT-525 編集画面 — 並び替えと保存 body', () {
    testWidgets('A/B: ハンドルをドラッグすると順序が変わり、その順で保存される',
        (tester) async {
      useTallViewport(tester);
      final built = _buildApp(const EditHabitPage(habitId: 1), prefs);
      await tester.pumpWidget(built.widget);
      await tester.pumpAndSettle();

      expect(find.text('A'), findsOneWidget);
      expect(find.text('C'), findsOneWidget);

      // A (index 0) を末尾 (index 2) へ
      await _dragHandleTo(tester, 0, 2);

      await _tapSave(tester);
      await tester.pumpAndSettle();

      final body = built.adapter.bodyOf('PATCH', '/habits/1/');
      expect(body, isNotNull, reason: 'PATCH が飛んでいない');
      final sent = (body!['set_checklist_items'] as List).cast<Map>();
      expect(sent.map((e) => e['text']).toList(), ['B', 'C', 'A'],
          reason: '表示順どおりに送られていない');
      expect(sent.map((e) => e['id']).toList(), [2, 3, 1]);
    });

    testWidgets('C: × で消した項目は body に含まれない', (tester) async {
      useTallViewport(tester);
      final built = _buildApp(const EditHabitPage(habitId: 1), prefs);
      await tester.pumpWidget(built.widget);
      await tester.pumpAndSettle();

      // B の行の × を押す
      final bRow = find.ancestor(
        of: find.text('B'),
        matching: find.byType(ListTile),
      );
      await tester.tap(find.descendant(of: bRow, matching: find.byIcon(Icons.close)));
      await tester.pumpAndSettle();
      expect(find.text('B'), findsNothing);

      await _tapSave(tester);
      await tester.pumpAndSettle();

      final sent = (built.adapter.bodyOf('PATCH', '/habits/1/')!['set_checklist_items']
              as List)
          .cast<Map>();
      expect(sent.map((e) => e['text']).toList(), ['A', 'C']);
      expect(sent.any((e) => e['id'] == 2), isFalse);
    });

    testWidgets('D: 新規項目は id なしで、差し込んだ位置に入る', (tester) async {
      useTallViewport(tester);
      final built = _buildApp(const EditHabitPage(habitId: 1), prefs);
      await tester.pumpWidget(built.widget);
      await tester.pumpAndSettle();

      await tester.enterText(
          _itemInput, '新しい項目');
      await tester.tap(find.byIcon(Icons.add_circle));
      await tester.pumpAndSettle();
      expect(find.text('新しい項目'), findsOneWidget);

      // 末尾 (index 3) に入った新規項目を先頭 (index 0) へ
      await _dragHandleTo(tester, 3, 0);

      await _tapSave(tester);
      await tester.pumpAndSettle();

      final sent = (built.adapter.bodyOf('PATCH', '/habits/1/')!['set_checklist_items']
              as List)
          .cast<Map>();
      expect(sent.map((e) => e['text']).toList(), ['新しい項目', 'A', 'B', 'C']);
      expect(sent.first.containsKey('id'), isFalse,
          reason: '新規項目に id を付けてはいけない');
      expect(sent.skip(1).map((e) => e['id']).toList(), [1, 2, 3]);
    });

    testWidgets('E: 🔴 旧 add_/delete_checklist_items を併送しない', (tester) async {
      // 併送すると backend が habit_update_checklist_payload_conflict で 400 を返す。
      // 旧フィールドは**後方互換のために残っている**だけで、新クライアントは使わない。
      useTallViewport(tester);
      final built = _buildApp(const EditHabitPage(habitId: 1), prefs);
      await tester.pumpWidget(built.widget);
      await tester.pumpAndSettle();

      final bRow = find.ancestor(
        of: find.text('B'),
        matching: find.byType(ListTile),
      );
      await tester.tap(find.descendant(of: bRow, matching: find.byIcon(Icons.close)));
      await tester.pumpAndSettle();
      await tester.enterText(
          _itemInput, '追加分');
      await tester.tap(find.byIcon(Icons.add_circle));
      await tester.pumpAndSettle();

      await _tapSave(tester);
      await tester.pumpAndSettle();

      final body = built.adapter.bodyOf('PATCH', '/habits/1/')!;
      expect(body.containsKey('set_checklist_items'), isTrue);
      expect(body.containsKey('add_checklist_items'), isFalse);
      expect(body.containsKey('delete_checklist_items'), isFalse);
    });

    testWidgets('G: Pre-mortem #4 — 項目 11 件でも例外を出さずに描画できる',
        (tester) async {
      // `shrinkWrap: true` / `NeverScrollableScrollPhysics` を忘れると
      // `Vertical viewport was given unbounded height` で落ちる。
      // 報告時点で 11 件あり、画面に収まらない件数は普通に発生する。
      useTallViewport(tester);
      final built = _buildApp(const EditHabitPage(habitId: 1), prefs);
      built.adapter.checklistItems = _items(
        List.generate(11, (i) => '項目 ${i + 1}'),
      );
      await tester.pumpWidget(built.widget);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.drag_indicator), findsNWidgets(11));

      // 11 件でも並び替えて保存できる (順序が全件揃って送られる)
      await _dragHandleTo(tester, 0, 1);
      await _tapSave(tester);
      await tester.pumpAndSettle();

      final sent = (built.adapter.bodyOf('PATCH', '/habits/1/')!['set_checklist_items']
              as List)
          .cast<Map>();
      expect(sent.length, 11);
      expect(sent.map((e) => e['text']).take(3).toList(),
          ['項目 2', '項目 1', '項目 3']);
    });
  });

  group('FEAT-525 新規作成画面 — 並び替え', () {
    testWidgets('F: 並べ替えた順序が checklist_items の配列順として POST される',
        (tester) async {
      useTallViewport(tester);
      final built = _buildApp(const AddHabitPage(initialTitle: '朝の支度'), prefs);
      await tester.pumpWidget(built.widget);
      await tester.pumpAndSettle();

      // チェックリスト型に切り替え
      await tester.tap(find.text('チェックリスト'));
      await tester.pumpAndSettle();

      for (final text in ['A', 'B', 'C']) {
        await tester.enterText(
            _itemInput, text);
        await tester.tap(find.byIcon(Icons.add_circle));
        await tester.pumpAndSettle();
      }
      expect(find.byIcon(Icons.drag_indicator), findsNWidgets(3));

      // C を先頭 (index 0) へ
      await _dragHandleTo(tester, 2, 0);

      final submit = find.text('習慣を刻む 🌱');
      expect(submit, findsOneWidget);
      await tester.tap(submit);
      await tester.pumpAndSettle();

      final body = built.adapter.bodyOf('POST', '/habits/');
      expect(body, isNotNull, reason: 'POST が飛んでいない');
      // POST の `checklist_items` は文字列配列。**配列順がそのまま `order`** に
      // なるので (backend の `order=idx`)、順序だけ確かめれば十分。
      expect((body!['checklist_items'] as List).cast<String>(), ['C', 'A', 'B']);
    });
  });
}
