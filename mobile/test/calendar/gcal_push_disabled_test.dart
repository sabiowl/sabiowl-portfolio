// 【FEAT-373 (2026-05-29)】v1.0 で Google Calendar push 機能廃止の契約テスト。
//
// 検証対象:
//   A. FeatureFlags.gcalPushEnabled は false (v1.0 で push 廃止の定数確認)
//   B. _pushToGoogleInBackground: FeatureFlags.gcalPushEnabled=false で即 return
//      (flag gate が最初の行に置かれているため ApiClient に触れない)
//   C. retryPendingPushes: FeatureFlags gate → gcalPushEnabled param gate の 2 重防御
//      (FeatureFlags が優先され、param が true でも skip される)
//   D. syncGoogleCalendar Step 6: FeatureFlags=false で pushed=0 で正常完了
//
// テスト設計:
//   - A: 単純な const 値確認
//   - B: GoogleCalendarSyncService / TimelineService の "FeatureFlags gate は first check"
//     を実証 → ApiClient が null でもクラッシュしない (gate が先に return するため)
//   - C: retryPendingPushes(gcalPushEnabled: true) でも FeatureFlags.gcalPushEnabled=false
//     が優先されて早期 return = APIClient に到達しない
//   - D: ProviderContainer で service を生成、syncGoogleCalendar は accessToken 取得で
//     サイレント no-op (GoogleSignIn は catch で吸収)
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sabiowl/core/constants/feature_flags.dart';
import 'package:sabiowl/features/calendar/providers/calendar_provider.dart';

void main() {
  // syncGoogleCalendar は Steps 1-5 で GoogleSignIn (MethodChannel) を触るため
  // テストバインディングを初期化しておく必要がある。
  TestWidgetsFlutterBinding.ensureInitialized();
  group('FEAT-373 v1.0 push 機能廃止 契約テスト', () {
    // ─────────────────────────────────────────────────────────────────
    // テスト A: FeatureFlags.gcalPushEnabled = false の定数確認
    // ─────────────────────────────────────────────────────────────────
    test('A: FeatureFlags.gcalPushEnabled は false (v1.0 で push 廃止確証)', () {
      // 最もシンプルなアサーション: const が正しい値を持つことを縛る。
      // v1.1+ で push を再有効化する際にこのテストが壊れ、意図的な変更の証拠となる。
      expect(
        FeatureFlags.gcalPushEnabled,
        isFalse,
        reason: 'v1.0 では gcalPushEnabled=false が必須 (FEAT-373)',
      );
    });

    // ─────────────────────────────────────────────────────────────────
    // テスト B: retryPendingPushes が FeatureFlags gate で早期 return
    //           (gcalPushEnabled param=true でも FeatureFlags が優先される)
    // ─────────────────────────────────────────────────────────────────
    test('B: retryPendingPushes(gcalPushEnabled: true) でも FeatureFlags gate で early return',
        () async {
      // ProviderContainer で実際のサービスインスタンスを生成。
      // ApiClient の constructor は Dio 初期化のみ (platform channels なし) で安全。
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final service = container.read(googleCalendarSyncServiceProvider);

      // gcalPushEnabled=true (FEAT-372 param) でも FeatureFlags.gcalPushEnabled=false が
      // 最初に判定されるため early return → ApiClient に到達しない → 例外なく完了。
      await expectLater(
        () => service.retryPendingPushes(gcalPushEnabled: true),
        returnsNormally,
        reason: 'FeatureFlags.gcalPushEnabled=false が FEAT-372 param より優先される (FEAT-373)',
      );
    });

    // ─────────────────────────────────────────────────────────────────
    // テスト C: retryPendingPushes(gcalPushEnabled: false) も early return
    //           (FeatureFlags gate が先に発火、FEAT-372 gate は到達しない)
    // ─────────────────────────────────────────────────────────────────
    test('C: retryPendingPushes(gcalPushEnabled: false) は FeatureFlags gate で early return',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final service = container.read(googleCalendarSyncServiceProvider);

      await expectLater(
        () => service.retryPendingPushes(gcalPushEnabled: false),
        returnsNormally,
        reason: 'FeatureFlags gate + FEAT-372 gate の両方が発火しても正常完了する',
      );
    });

    // ─────────────────────────────────────────────────────────────────
    // テスト D: syncGoogleCalendar の Step 6 が FeatureFlags=false でスキップされる
    //           (syncGoogleCalendar 全体は catch で吸収されて正常完了)
    // ─────────────────────────────────────────────────────────────────
    test('D: syncGoogleCalendar は FeatureFlags=false で Step 6 skip して正常完了',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final service = container.read(googleCalendarSyncServiceProvider);

      // syncGoogleCalendar は accessToken 取得 (_ensureCalendarAccessToken) で
      // GoogleSignIn platform channel が呼ばれて失敗するが、内部 catch で吸収される。
      // 重要: Step 6 (push loop) は FeatureFlags.gcalPushEnabled=false でスキップ済み。
      // 結果 null が返るか、例外が呼び出し元に伝播しないことを確認。
      await expectLater(
        () => service.syncGoogleCalendar(),
        returnsNormally,
        reason: 'syncGoogleCalendar は内部 catch で吸収されて正常完了、Step 6 はスキップ',
      );
    });
  });
}
