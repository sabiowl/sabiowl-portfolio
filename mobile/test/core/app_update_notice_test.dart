import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sabiowl/core/constants/app_urls.dart';
import 'package:sabiowl/core/constants/preferences_keys.dart';
import 'package:sabiowl/core/providers/app_update_provider.dart';
import 'package:sabiowl/core/providers/app_version_provider.dart';
import 'package:sabiowl/core/services/app_update_service.dart';
import 'package:sabiowl/core/widgets/app_update_overlay.dart';
import 'package:sabiowl/l10n/app_localizations.dart';

/// 【FEAT-543 (2026-09-23)】バージョンアップ告知。
///
/// ## 🔴 空振り検出が本体である
///
/// 「更新ありで出る」だけを縛ると**常に出す実装**でも緑になり、
/// 「更新なしで出ない」だけを縛ると**常に出さない実装**でも緑になる。
/// **両方を対で書く。**
///
/// ## 🔴 「呼んだこと」ではなく「見えたこと」を見る
///
/// BUG-164 / BUG-165 は、どちらも**呼び出しは正しいのに画面に出ない**形だった。
/// overlay のテストは `find` で実際に描画されたものを見る。

class _FakeAppUpdateService extends AppUpdateService {
  _FakeAppUpdateService(this._status) : super(Dio());
  final AppUpdateStatus _status;

  @override
  Future<AppUpdateStatus> fetchStatus() async => _status;
}

/// 応答を差し替える fake adapter。
class _ThrowingAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, _, __) {
    throw DioException(
      requestOptions: options,
      type: DioExceptionType.connectionError,
    );
  }

  @override
  void close({bool force = false}) {}
}

class _BodyAdapter implements HttpClientAdapter {
  _BodyAdapter(this.body);
  final String body;

  @override
  Future<ResponseBody> fetch(RequestOptions options, _, __) async =>
      ResponseBody.fromString(
        body,
        200,
        headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
      );

  @override
  void close({bool force = false}) {}
}

/// overlay を本物の provider 経由で立ち上げる。
Future<ProviderContainer> _pumpOverlay(
  WidgetTester tester, {
  required AppUpdateStatus status,
  required String deviceVersion,
}) async {
  final container = ProviderContainer(
    overrides: [
      appUpdateServiceProvider
          .overrideWith((ref) => _FakeAppUpdateService(status)),
      appVersionProvider.overrideWith((ref) async => deviceVersion),
    ],
  );
  addTearDown(container.dispose);
  await container.read(appUpdateStatusProvider.notifier).refresh();

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        // 文言を assert するので locale を固定する。
        locale: Locale('ja'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AppUpdateOverlay(child: Text('child_widget')),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

const _enabled = AppUpdateStatus(
  isEnabled: true,
  latestVersion: '1.1.4',
  title: '新しい Sabiowl をご用意しました',
  body: 'App Store から更新していただけます 🪶',
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('FEAT-543 §4-1 バージョン比較', () {
    test('古ければ true', () {
      expect(isOlderVersion('1.1.3', '1.1.4'), isTrue);
      expect(isOlderVersion('1.0.9', '1.1.0'), isTrue);
      expect(isOlderVersion('0.9.9', '1.0.0'), isTrue);
    });

    test('等しい / 新しければ false', () {
      expect(isOlderVersion('1.1.4', '1.1.4'), isFalse);
      expect(isOlderVersion('1.1.5', '1.1.4'), isFalse);
      expect(isOlderVersion('2.0.0', '1.9.9'), isFalse);
    });

    test('🔴 二桁で逆転しない（文字列比較だとここが落ちる）', () {
      // `'1.1.10' < '1.1.9'` は文字列比較では true になる。
      expect(isOlderVersion('1.1.9', '1.1.10'), isTrue,
          reason: '1.1.9 は 1.1.10 より古い');
      expect(isOlderVersion('1.1.10', '1.1.9'), isFalse,
          reason: '1.1.10 を古いと判定している = 文字列比較になっている');
      expect(isOlderVersion('1.9.0', '1.10.0'), isTrue);
      expect(isOlderVersion('9.0.0', '10.0.0'), isTrue);
    });

    test('⚠️ 読めない値は「更新なし」に倒す', () {
      // 出さない側に倒すのは BootGate v1 の教訓と同じ。
      // 🔴 `1.1.4-beta` は 2026-09-23 に**この一覧から外した**。
      //    Android の dev flavor が `-dev` を付けるので、接尾辞つきは
      //    **実在する**。下の「dev ビルドの接尾辞」テストが受け持つ。
      //    ⚠️ `v1.1.4` は引き続き読めない値のまま（admin の入力誤り）。
      for (final bad in ['', '1.1', 'v1.1.4', '1.1.3+9', '1.1.4.5', 'abc',
        '1.-1.4', '1.1.4 5', '１.１.４']) {
        expect(isOlderVersion('1.1.3', bad), isFalse, reason: 'other=$bad');
        expect(isOlderVersion(bad, '1.1.4'), isFalse, reason: 'current=$bad');
      }
    });

    test('⚠️ 前後の空白は許容する（admin の入力揺れ）', () {
      // 🔵 空白 1 つで告知が止まるのは、厳しすぎて逆に事故になる。
      //    読めない値に倒すのは「形が違う」ときだけでよい。
      expect(isOlderVersion('1.1.3', ' 1.1.4 '), isTrue);
      expect(isOlderVersion(' 1.1.3 ', '1.1.4'), isTrue);
    });
    test('🔴 dev ビルドの接尾辞を落として比較する（dev 実機で告知が出なかった）', () {
      // Android の dev flavor は `versionNameSuffix = "-dev"` を付けるので、
      // `PackageInfo.version` は `1.1.3-dev` になる。旧実装は 3 要素ちょうどを
      // 要求していたため解析に失敗し、「判定できない = 告知しない」に倒れて
      // **dev ビルドでは永久に出なかった**（dev 実機確認 2026-09-23）。
      expect(isOlderVersion('1.1.3-dev', '1.1.4'), isTrue);
      expect(isOlderVersion('1.1.3-dev', '1.1.3'), isFalse,
          reason: '同じ版の dev ビルドを「古い」と見てはいけない');
      expect(isOlderVersion('1.1.4-beta', '1.1.4'), isFalse);
    });

    test('⚠️ 接尾辞を落としても読めない値は「更新なし」のまま', () {
      expect(isOlderVersion('1.1-dev', '1.1.4'), isFalse);
      expect(isOlderVersion('latest', '1.1.4'), isFalse);
      expect(isOlderVersion('1.1.x', '1.1.4'), isFalse);
      expect(isOlderVersion('-dev', '1.1.4'), isFalse);
      // 🔴 接尾辞を落とす対象を広げすぎていないこと。
      expect(isOlderVersion('1.1.3+9', '1.1.4'), isFalse,
          reason: 'ビルド番号つきは admin の入力誤りなので告知しない');
      expect(isOlderVersion('1.1.3', 'v1.1.4'), isFalse,
          reason: 'v 付きは admin の入力誤りなので告知しない');
    });
  });

  group('FEAT-543 §2-1 どの告知を出すか', () {
    AppUpdateKind kindFor(AppUpdateStatus c, String v) =>
        resolveAppUpdateKind(config: c, currentVersion: v);

    test('is_enabled が false なら何も出ない', () {
      expect(
        kindFor(
          const AppUpdateStatus(
              isEnabled: false,
              latestVersion: '9.9.9',
              minSupportedVersion: '9.9.9'),
          '1.1.3',
        ),
        AppUpdateKind.none,
        reason: 'admin の OFF が効いていない。事故ったときの逃げ道である',
      );
    });

    test('latest より古ければ推奨更新', () {
      expect(kindFor(_enabled, '1.1.3'), AppUpdateKind.recommended);
    });

    test('latest 以上なら何も出ない', () {
      // 🔴 空振り検出の対。これが無いと「常に出す」実装で緑になる。
      expect(kindFor(_enabled, '1.1.4'), AppUpdateKind.none);
      expect(kindFor(_enabled, '1.2.0'), AppUpdateKind.none);
    });

    test('🔴 必須を先に見る（順序を入れ替えると「後で」を出してしまう）', () {
      const c = AppUpdateStatus(
        isEnabled: true,
        latestVersion: '1.1.6',
        minSupportedVersion: '1.1.4',
      );
      // 3 群に分かれる。§2-7 の表そのもの。
      expect(kindFor(c, '1.1.3'), AppUpdateKind.mandatory,
          reason: '使わせてはいけない版に「後で」を出している');
      expect(kindFor(c, '1.1.4'), AppUpdateKind.recommended);
      expect(kindFor(c, '1.1.5'), AppUpdateKind.recommended);
      expect(kindFor(c, '1.1.6'), AppUpdateKind.none);
    });

    test('⚠️ min が空なら必須更新にはならない（既定の運用）', () {
      expect(kindFor(_enabled, '0.0.1'), AppUpdateKind.recommended,
          reason: 'min が空なのに締め出している');
    });
  });

  group('FEAT-543 §4-5 通信できないときは告知しない（fail open）', () {
    Future<AppUpdateStatus> fetchWith(HttpClientAdapter adapter) {
      final dio = Dio(BaseOptions(baseUrl: 'https://test.example'))
        ..httpClientAdapter = adapter;
      return AppUpdateService(dio).fetchStatus();
    }

    test('通信失敗 → off', () async {
      expect((await fetchWith(_ThrowingAdapter())).isEnabled, isFalse);
    });

    test('JSON でない応答 → off', () async {
      expect((await fetchWith(_BodyAdapter('not json at all'))).isEnabled,
          isFalse);
    });

    test('配列が返っても落ちずに off', () async {
      expect((await fetchWith(_BodyAdapter('[1,2,3]'))).isEnabled, isFalse);
    });

    test('🔴 対: 正しい応答は読める', () async {
      // これが無いと「常に off を返す」実装で緑になる。
      final status = await fetchWith(_BodyAdapter(
          '{"is_enabled":true,"latest_version":"1.1.4",'
          '"min_supported_version":"","title":"T","body":"B"}'));
      expect(status.isEnabled, isTrue);
      expect(status.latestVersion, '1.1.4');
    });
  });

  group('FEAT-543 §4-2/3/10/11 overlay が見えること', () {
    testWidgets('🔴 推奨更新: admin の入力値が出て、「後で」がある', (tester) async {
      await _pumpOverlay(tester, status: _enabled, deviceVersion: '1.1.3');

      expect(find.text(_enabled.title), findsOneWidget,
          reason: '推奨更新では admin の入力値を出す');
      expect(find.text(_enabled.body), findsOneWidget);
      expect(find.byKey(const Key('app_update_later')), findsOneWidget,
          reason: '推奨更新は「後で」で閉じられる');
      expect(find.byKey(const Key('app_update_open_store')), findsOneWidget);
    });

    testWidgets('🔴 必須更新: ARB の固定文が出て、「後で」が無い', (tester) async {
      await _pumpOverlay(
        tester,
        status: const AppUpdateStatus(
          isEnabled: true,
          latestVersion: '1.1.6',
          minSupportedVersion: '1.1.4',
          title: 'admin が入れた推奨更新のタイトル',
          body: 'admin が入れた推奨更新の本文',
        ),
        deviceVersion: '1.1.3',
      );

      final l10n = await AppLocalizations.delegate.load(const Locale('ja'));
      expect(find.text(l10n.coreAppUpdateRequiredTitle), findsOneWidget);
      expect(find.text(l10n.coreAppUpdateRequiredBody),
          findsOneWidget);
      // 🔴 admin の入力値が漏れていないこと。1 組の文面を共用すると
      //    「まだ使える群」に「使えません」と出る。
      expect(find.text('admin が入れた推奨更新のタイトル'), findsNothing,
          reason: '必須更新に推奨更新の文面が出ている');
      expect(find.byKey(const Key('app_update_later')), findsNothing,
          reason: '🔴 必須更新に「後で」を出すと、'
              '使わせてはいけない版のまま続けられてしまう');
    });

    testWidgets('🔴 対: 更新が無いときは何も出ない', (tester) async {
      await _pumpOverlay(tester, status: _enabled, deviceVersion: '1.1.4');
      expect(find.text('child_widget'), findsOneWidget);
      expect(find.byKey(const Key('app_update_open_store')), findsNothing,
          reason: '最新版のユーザーにまで告知が出ている');
    });

    testWidgets('🔴 対: admin が OFF なら何も出ない', (tester) async {
      await _pumpOverlay(
        tester,
        status: const AppUpdateStatus(
            isEnabled: false, latestVersion: '9.9.9'),
        deviceVersion: '1.1.3',
      );
      expect(find.byKey(const Key('app_update_open_store')), findsNothing);
    });
  });

  group('FEAT-543 §4-4 「後で」の 24 時間抑制', () {
    test('押した直後は抑制される', () async {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime(2026, 9, 23, 10);
      await markAppUpdateNoticeDismissed('1.1.4', prefs: prefs, now: now);
      expect(
        await isAppUpdateNoticeSuppressed('1.1.4', prefs: prefs, now: now),
        isTrue,
      );
    });

    test('24 時間を過ぎたら出る', () async {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime(2026, 9, 23, 10);
      await markAppUpdateNoticeDismissed('1.1.4', prefs: prefs, now: now);
      expect(
        await isAppUpdateNoticeSuppressed('1.1.4',
            prefs: prefs, now: now.add(const Duration(hours: 23, minutes: 59))),
        isTrue,
      );
      expect(
        await isAppUpdateNoticeSuppressed('1.1.4',
            prefs: prefs, now: now.add(const Duration(hours: 24, minutes: 1))),
        isFalse,
      );
    });

    test('🔴 版が上がれば 24 時間内でも出る', () async {
      // キーに版を含めていないと、**新しい版が出ても 1 日告知できない**。
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime(2026, 9, 23, 10);
      await markAppUpdateNoticeDismissed('1.1.4', prefs: prefs, now: now);
      expect(
        await isAppUpdateNoticeSuppressed('1.1.5', prefs: prefs, now: now),
        isFalse,
        reason: '抑制のキーに版が入っていない',
      );
    });

    testWidgets('🔴 「後で」を押すと overlay が閉じる', (tester) async {
      await _pumpOverlay(tester, status: _enabled, deviceVersion: '1.1.3');
      expect(find.byKey(const Key('app_update_later')), findsOneWidget);

      await tester.tap(find.byKey(const Key('app_update_later')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('app_update_open_store')), findsNothing,
          reason: '「後で」を押しても閉じない');
      expect(find.text('child_widget'), findsOneWidget);
    });

    testWidgets('🔴 必須更新は抑制されない（前回「後で」と言っていても出る）',
        (tester) async {
      final prefs = await SharedPreferences.getInstance();
      await markAppUpdateNoticeDismissed('1.1.6', prefs: prefs);

      await _pumpOverlay(
        tester,
        status: const AppUpdateStatus(
          isEnabled: true,
          latestVersion: '1.1.6',
          minSupportedVersion: '1.1.4',
        ),
        deviceVersion: '1.1.3',
      );
      expect(find.byKey(const Key('app_update_open_store')), findsOneWidget,
          reason: '必須更新まで抑制している。使わせてはいけない版が使えてしまう');
    });
  });

  group('FEAT-544 必須更新の文面は admin から来る', () {
    // 🔴 **空振り検出**: ARB の固定文とサーバの文面で
    //    **違う文字列**を使う。同じだとどちらが出ているのか
    //    判別できずに緑になる。
    const serverMandatoryTitle = 'admin が書いた必須更新の見出し';
    const serverMandatoryBody = 'admin が書いた必須更新の本文';

    const mandatoryConfig = AppUpdateStatus(
      isEnabled: true,
      latestVersion: '1.1.6',
      minSupportedVersion: '1.1.4',
      title: '推奨更新の見出し',
      body: '推奨更新の本文',
      mandatoryTitle: serverMandatoryTitle,
      mandatoryBody: serverMandatoryBody,
    );

    testWidgets('🔴 4: サーバの文面があればそれを出す', (tester) async {
      await _pumpOverlay(tester,
          status: mandatoryConfig, deviceVersion: '1.1.3');

      final l10n = await AppLocalizations.delegate.load(const Locale('ja'));
      expect(find.text(serverMandatoryTitle), findsOneWidget);
      expect(find.text(serverMandatoryBody), findsOneWidget);
      expect(find.text(l10n.coreAppUpdateRequiredTitle), findsNothing,
          reason: 'admin が書いた文面を無視して ARB の固定文を出している');
      expect(find.byKey(const Key('app_update_later')), findsNothing,
          reason: '必須更新なのに「後で」がある');
    });

    testWidgets('🔴 5: サーバの文面が空なら ARB の固定文', (tester) async {
      // ⚠️ 空になるのは ①Backend が未デプロイ ②通信できない
      //    ③admin が誤って空にした、の 3 通り。
      //    🔴 **閉じられない画面が無文面になる**のを防ぐ。
      await _pumpOverlay(
        tester,
        status: const AppUpdateStatus(
          isEnabled: true,
          latestVersion: '1.1.6',
          minSupportedVersion: '1.1.4',
          title: '推奨更新の見出し',
          body: '推奨更新の本文',
        ),
        deviceVersion: '1.1.3',
      );

      final l10n = await AppLocalizations.delegate.load(const Locale('ja'));
      expect(find.text(l10n.coreAppUpdateRequiredTitle), findsOneWidget,
          reason: 'ARB の固定文へ落ちていない。'
              '閉じられない画面に文面が無い状態になる');
      expect(find.text(l10n.coreAppUpdateRequiredBody), findsOneWidget);
      // 🔴 推奨更新の文面が漏れていないこと。
      expect(find.text('推奨更新の見出し'), findsNothing);
    });

    testWidgets('🔴 6: 推奨更新には必須の文面が漏れない', (tester) async {
      await _pumpOverlay(
        tester,
        status: const AppUpdateStatus(
          isEnabled: true,
          latestVersion: '1.1.4',
          title: '推奨更新の見出し',
          body: '推奨更新の本文',
          mandatoryTitle: serverMandatoryTitle,
          mandatoryBody: serverMandatoryBody,
        ),
        deviceVersion: '1.1.3',
      );

      expect(find.text('推奨更新の見出し'), findsOneWidget);
      expect(find.text(serverMandatoryTitle), findsNothing,
          reason: '推奨更新に必須更新の文面が出ている。'
              'まだ使えるユーザーに「使えません」と出すことになる');
      expect(find.byKey(const Key('app_update_later')), findsOneWidget);
    });

    test('サーバのキーが無い応答でも落ちない（Backend 未デプロイ）', () {
      // 🔵 旧 Backend は `mandatory_*` を返さない。空文字に倒れば
      //    画面側が ARB の固定文へ落とす。
      final status = AppUpdateStatus.fromJson(const {
        'is_enabled': true,
        'latest_version': '1.1.4',
        'min_supported_version': '',
        'title': 'T',
        'body': 'B',
      });
      expect(status.mandatoryTitle, '');
      expect(status.mandatoryBody, '');
    });
  });

  group('FEAT-543 §4-9 ストア URL をリテラルで書かない', () {
    test('🔴 app_urls.dart 以外に App Store の URL / ID が無い', () {
      const needles = ['apps.apple.com', 'itms-apps', kAppStoreAppId];
      final offenders = <String>[];
      var scanned = 0;
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (entity.path.endsWith('.g.dart')) continue;
        final path = entity.path.replaceAll(r'\', '/');
        if (path.endsWith('core/constants/app_urls.dart')) continue;
        if (path.contains('/l10n/')) continue;
        scanned++;
        final lines = entity.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          final trimmed = line.trimLeft();
          // 経緯の説明でストアに触れるのは正当。
          if (trimmed.startsWith('//') || trimmed.startsWith('*')) continue;
          for (final needle in needles) {
            if (line.contains(needle)) {
              offenders.add('$path:${i + 1}  $needle');
            }
          }
        }
      }
      // ⚠️ 空振り検出。走査が 0 ファイルでも緑になる形を防ぐ。
      expect(scanned, greaterThan(100),
          reason: '走査対象が少なすぎる。収集が壊れている');
      expect(offenders, isEmpty,
          reason: 'ストアの URL / ID は core/constants/app_urls.dart に'
              '置いてください:\n${offenders.join('\n')}');
    });

    test('🔵 app_urls.dart 側は deep link と web の 2 段を持っている', () {
      // 空振り検出の裏取り。片方しか無いと「押しても何も起きない」経路ができる。
      expect(kAppStoreDeepLinkUrl, startsWith('itms-apps://'));
      expect(kAppStoreWebUrl, startsWith('https://apps.apple.com/'));
      expect(kAppStoreDeepLinkUrl, contains(kAppStoreAppId));
      expect(kAppStoreWebUrl, contains(kAppStoreAppId));
    });
  });
}
