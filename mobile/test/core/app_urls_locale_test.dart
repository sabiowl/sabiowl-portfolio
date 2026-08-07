// 【FEAT-489 Phase 5 (2026-08-02)】公式ページ URL の locale 出し分けガード。
//
// ## なぜ必要か
//
// `sabiowl-home-pages` に英語版があるのは **法務 3 ページのみ**
// (privacy_policy_en / terms_of_service_en / legal_consumer_info_en)。
// FAQ・使い方・リリースノート・TOP に `_en` 版は無い。
//
// 「英語なら全部 _en を付ければよい」と後から一律化されると、
// **英語ユーザーだけ 404 に飛ばす**。逆に法務ページの出し分けが消えると、
// 英語ユーザーに日本語の規約を見せることになる。どちらも実機で気付きにくいので
// CI で固定する。
//
// 実行方法:
// ```powershell
// cd mobile
// flutter test test/core/app_urls_locale_test.dart
// ```

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/core/constants/app_urls.dart';
import 'package:sabiowl/core/l10n/service_l10n.dart';

void main() {
  // ServiceL10n は static holder。テスト間でリークするので必ず ja に戻す
  // (Phase 2D の申し送り、service_l10n_test.dart と同じ規律)。
  tearDown(() => ServiceL10n.debugSetLocale(const Locale('ja')));

  group('A: 英語版が実在するページは locale で切り替わる', () {
    test('プライバシーポリシー', () {
      ServiceL10n.debugSetLocale(const Locale('ja'));
      expect(kSabiowlPrivacyPolicyUrl, endsWith('/privacy_policy.html'));

      ServiceL10n.debugSetLocale(const Locale('en'));
      expect(kSabiowlPrivacyPolicyUrl, endsWith('/privacy_policy_en.html'));
    });

    test('利用規約', () {
      ServiceL10n.debugSetLocale(const Locale('ja'));
      expect(kSabiowlTermsOfServiceUrl, endsWith('/terms_of_service.html'));

      ServiceL10n.debugSetLocale(const Locale('en'));
      expect(kSabiowlTermsOfServiceUrl, endsWith('/terms_of_service_en.html'));
    });

    test('特商法ページは英語版だと別名の販売者情報ページを指す', () {
      // 特定商取引法は日本国内法。英語版は直訳ではなく書き起こしのため、
      // URL が 1:1 対応しない (doc/legal/en_legal_pages_plan.md §2)。
      ServiceL10n.debugSetLocale(const Locale('ja'));
      expect(kSabiowlSpecifiedCommercialTransactionsUrl,
          endsWith('/specified_commercial_transactions.html'));

      ServiceL10n.debugSetLocale(const Locale('en'));
      expect(kSabiowlSpecifiedCommercialTransactionsUrl,
          endsWith('/legal_consumer_info_en.html'));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // B: 【FEAT-519 Phase 3 (2026-08-06)】`/en/` 配下に置いたページ
  //
  // 旧 B 群は「英語版が無いページは切り替えてはいけない」という検査で、
  // release_notes / faq / help が **常に日本語版を返すこと** を縛っていた。
  // Phase 3 で 3 ページとも英語版を用意したので、検査の向きが逆になる。
  //
  // **URL の付き方が法務ページと違う点に注意**: 法務 3 ページはストア登録済で
  // 動かせないため `*_en.html` のままだが、この 3 ページは URL 制約が無いので
  // `/en/` 配下に置いた (FEAT-519 §3)。
  // ───────────────────────────────────────────────────────────────────────────
  group('B: /en/ 配下に置いたページ', () {
    test('リリースノート', () {
      ServiceL10n.debugSetLocale(const Locale('ja'));
      expect(kSabiowlReleaseNotesUrl, endsWith('/release_notes.html'));
      expect(kSabiowlReleaseNotesUrl, isNot(contains('/en/')));

      ServiceL10n.debugSetLocale(const Locale('en'));
      expect(kSabiowlReleaseNotesUrl, endsWith('/en/release_notes.html'));
    });

    test('FAQ', () {
      ServiceL10n.debugSetLocale(const Locale('ja'));
      expect(kSabiowlFaqUrl, endsWith('/faq.html'));
      expect(kSabiowlFaqUrl, isNot(contains('/en/')));

      ServiceL10n.debugSetLocale(const Locale('en'));
      expect(kSabiowlFaqUrl, endsWith('/en/faq.html'));
    });

    test('使い方ガイド', () {
      ServiceL10n.debugSetLocale(const Locale('ja'));
      expect(kSabiowlHelpUrl, endsWith('/help.html'));
      expect(kSabiowlHelpUrl, isNot(contains('/en/')));

      ServiceL10n.debugSetLocale(const Locale('en'));
      expect(kSabiowlHelpUrl, endsWith('/en/help.html'));
    });

    test('法務 3 ページは `/en/` 配下に移していない', () {
      // ここが落ちたら「英語なら /en/」と一律化された合図。
      // 法務ページの URL はストア登録済 + アプリ直リンクで動かせない。
      // 動かすと **プライバシーポリシー URL が 404 になり審査で reject される**。
      ServiceL10n.debugSetLocale(const Locale('en'));

      for (final url in [
        kSabiowlPrivacyPolicyUrl,
        kSabiowlTermsOfServiceUrl,
        kSabiowlSpecifiedCommercialTransactionsUrl,
      ]) {
        expect(url, isNot(contains('/en/')),
            reason: '法務ページは `*_en.html` のまま。URL を動かすと'
                'ストア審査とアプリの両方が壊れる (FEAT-519 §3)');
        expect(url, endsWith('_en.html'));
      }
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // B-2: TOP ページ (【FEAT-519 Phase 2 (2026-08-06)】英語版を新設)
  // ───────────────────────────────────────────────────────────────────────────
  group('B-2: TOP ページ', () {
    // 旧実装では B 群に `endsWith('/')` として置かれていたが、
    // **英語 TOP `/en/` でもそのまま通ってしまう**ため検査になっていなかった。
    // 理由文も「TOP ページに英語版は無い」のまま古くなっていた。
    test('英語 locale では英語 TOP (/en/) を返す', () {
      ServiceL10n.debugSetLocale(const Locale('en'));
      expect(kSabiowlHomePageTopUrl, endsWith('/en/'),
          reason: '障害時に開くページなので、英語ユーザーを日本語 TOP に'
              '飛ばすと状況を読めないまま放置することになる');
    });

    test('日本語 locale では日本語 TOP を返す', () {
      ServiceL10n.debugSetLocale(const Locale('ja'));
      expect(kSabiowlHomePageTopUrl, endsWith('sabiowl-home-pages/'));
      expect(kSabiowlHomePageTopUrl, isNot(contains('/en/')));
    });
  });

  group('C: 共通の不変条件', () {
    test('どの locale でも公式ドメイン配下を指す', () {
      for (final locale in const [Locale('ja'), Locale('en')]) {
        ServiceL10n.debugSetLocale(locale);
        for (final url in [
          kSabiowlPrivacyPolicyUrl,
          kSabiowlTermsOfServiceUrl,
          kSabiowlSpecifiedCommercialTransactionsUrl,
          kSabiowlReleaseNotesUrl,
          kSabiowlFaqUrl,
          kSabiowlHelpUrl,
          kSabiowlHomePageTopUrl,
        ]) {
          expect(url, startsWith(kSabiowlHomePageBase),
              reason: '$locale で $url が base URL から外れている');
        }
      }
    });

    test('未対応 locale は日本語版に着地する (BUG-27 の丸めと同じ方針)', () {
      // ServiceL10n が万一 ja/en 以外を保持しても、日本語版を返して 404 を避ける。
      ServiceL10n.debugSetLocale(const Locale('ja', 'JP'));
      expect(kSabiowlPrivacyPolicyUrl, endsWith('/privacy_policy.html'));
    });
  });
}
