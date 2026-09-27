/// 【FEAT-463 (2026-06-22)】Sabiowl 公式ページ URL 定数集約。
///
/// 既存の散在 (privacy_policy_page / settings_page / terms_of_service_page /
/// contact_page の 5 ファイル 6 箇所) を本ファイルに統一し、将来の URL 移行
/// (例: GitHub Pages → sabiowl.com 独自ドメイン) を 1 ファイル変更で完結させる。
///
/// 緊急メンテナンス overlay (FEAT-463) では `kSabiowlHomePageTopUrl` を
/// 「最新情報」リンク先として表示する。
library;

import '../l10n/service_l10n.dart';  // 【FEAT-489 Phase 2D】BuildContext なし層の l10n

/// Sabiowl 公式ホームページのベース URL (末尾 `/` なし)。
///
/// 【2026-09-23】**独自ドメイン `sabiowl.com` へ移行済**。本ファイルを作った
/// 狙い (「移行時は本定数のみ変更すれば配下の各ページ URL も自動的に
/// 切り替わる」) が実際に効いた形で、変更はこの 1 行だけである。
///
/// 🔵 旧 `https://sabiowl.github.io/sabiowl-home-pages/...` は **301 で
/// 新ドメインへ飛ぶ**ので、更新していない旧バージョンのアプリも壊れない。
/// ⚠️ ただしリンクごとに 1 ホップ増えるので、アプリ側は新ドメインを直に指す。
const String kSabiowlHomePageBase = 'https://sabiowl.com';

/// 【FEAT-489 Phase 5 (2026-08-02)】公式ページ URL を locale で出し分ける。
///
/// ## URL の付き方が 2 系統ある
///
/// 【FEAT-519 Phase 3 (2026-08-06)】**全 7 トピックに英語版が揃った**ため、
/// 現在は全ページが切替対象。ただし命名は揃っていない:
///
/// | 対象 | 英語版 URL | 理由 |
/// |---|---|---|
/// | 法務 3 ページ | `*_en.html` | ストア登録済 + アプリ直リンクで **動かせない** |
/// | TOP / 使い方 / FAQ / リリースノート | `/en/...` | URL 制約が無いので `/en/` 配下 |
///
/// 揃っていないのは意図的で、法務ページの URL を動かすと
/// **ストア審査とアプリの両方が壊れる** (FEAT-519 §3)。
///
/// **英語版ページを追加したら、ここに 1 件足すこと。**
/// 対応関係は `sabiowl-home-pages/_data/i18n.yml` が単一真実値で、
/// 同リポジトリの `scripts/verify_i18n_links.py` が実ページとの整合を検証する。
///
/// ## 特商法ページだけ URL の対応が 1:1 でない
///
/// 特定商取引法は日本国内法で、英語圏に同等の制度がない。英語版は直訳ではなく
/// 「販売者情報 + 消費者向け情報」として書き起こしてあるため、
/// `specified_commercial_transactions` → `legal_consumer_info_en` という
/// **名前の異なるページ**に対応する (doc/legal/en_legal_pages_plan.md §2)。
///
/// ## `k` 接頭辞のまま getter にしている理由
///
/// 呼び出し側 (settings_page 等 4 箇所) は `Uri.parse(kSabiowl...Url)` で
/// 参照しており `const` 文脈では使っていない。名前を変えると呼び出し側の
/// 差分が増えるだけなので、**識別子は据え置いて中身だけ getter 化**した。
bool get _isEnglish => ServiceL10n.current.localeName.startsWith('en');

/// プライバシーポリシー (HTML)。英語 locale では英語版を返す。
String get kSabiowlPrivacyPolicyUrl => _isEnglish
    ? '$kSabiowlHomePageBase/privacy_policy_en.html'
    : '$kSabiowlHomePageBase/privacy_policy.html';

/// 利用規約 (HTML)。英語 locale では英語版を返す。
String get kSabiowlTermsOfServiceUrl => _isEnglish
    ? '$kSabiowlHomePageBase/terms_of_service_en.html'
    : '$kSabiowlHomePageBase/terms_of_service.html';

/// リリースノート (HTML)。英語 locale では英語版を返す。
/// 【FEAT-519 Phase 3 (2026-08-06)】英語版を整備したので切替対象に加えた。
String get kSabiowlReleaseNotesUrl => _isEnglish
    ? '$kSabiowlHomePageBase/en/release_notes.html'
    : '$kSabiowlHomePageBase/release_notes.html';

/// 特定商取引法に基づく表記 (HTML)。
///
/// 英語 locale では **`legal_consumer_info_en.html`** を返す (上記のとおり
/// 直訳ページではなく、英語圏向けに書き起こした販売者情報ページ)。
String get kSabiowlSpecifiedCommercialTransactionsUrl => _isEnglish
    ? '$kSabiowlHomePageBase/legal_consumer_info_en.html'
    : '$kSabiowlHomePageBase/specified_commercial_transactions.html';

/// FAQ (HTML)。英語 locale では英語版を返す。
/// 【FEAT-519 Phase 3 (2026-08-06)】英語版を整備したので切替対象に加えた。
String get kSabiowlFaqUrl => _isEnglish
    ? '$kSabiowlHomePageBase/en/faq.html'
    : '$kSabiowlHomePageBase/faq.html';

/// 【FEAT-485 (2026-07-08)】使い方・ヘルプ (HTML)。
///
/// **仕様の背景**: doc/instructions_from_gemini/tutorial.md
///
/// **既存 FAQ (`kSabiowlFaqUrl`) との使い分け**:
/// - kSabiowlFaqUrl: Q&A 形式、一度読めば済む → 外部ブラウザで開く (settings_page)
/// - kSabiowlHelpUrl: 操作手順を動画 + 画像で説明、繰り返し参照 → **アプリ内 WebView**
///   で開く (settings_page から context.push(AppRoutes.help))
///
/// **Web サイト側 URL 構造 (予定)**:
/// - トップ: `help.html` (画面選択メニュー)
/// - 各画面: `help/home.html`, `help/challenge.html`, `help/guild.html` 等
///   → 現状は最上位 URL のみを Mobile に渡し、Web サイト側 SPA で画面遷移する設計
/// 【FEAT-519 Phase 3 (2026-08-06)】英語版を整備したので切替対象に加えた。
String get kSabiowlHelpUrl => _isEnglish
    ? '$kSabiowlHomePageBase/en/help.html'
    : '$kSabiowlHomePageBase/help.html';

/// 緊急メンテナンス overlay の「最新情報」リンク先 (ホームページ TOP)。
/// 【FEAT-463】障害時にユーザーが最新情報を確認できるよう、TOP ページを示す。
///
/// 【FEAT-519 Phase 2 (2026-08-06)】英語 TOP (`/en/`) を新設したので locale で
/// 出し分ける。**障害時に開くページ**なので、英語ユーザーを日本語 TOP に
/// 飛ばすと状況を読めないまま放置することになる。
///
/// 英語 TOP は法務 3 ページの `*_en.html` と命名が揃っていないが、これは意図的:
/// 法務ページはストア登録済 + アプリ直リンクで URL を動かせないのに対し、
/// TOP は共有・入力される URL なので `/en/` の方が実用的
/// (`sabiowl-home-pages/_data/i18n.yml` 参照)。
String get kSabiowlHomePageTopUrl =>
    _isEnglish ? '$kSabiowlHomePageBase/en/' : '$kSabiowlHomePageBase/';

/// お問い合わせ用メールアドレス (mailto:)。
/// 【FEAT-463】緊急メンテナンス overlay の「お問い合わせ」リンク。
/// Backend の `CONTACT_TO_EMAIL` 設定値と整合 (settings.py)。
const String kSabiowlSupportEmail = 'support@sabiowl.com';
const String kSabiowlSupportMailto = 'mailto:$kSabiowlSupportEmail';

/// 【FEAT-479 hotfix (2026-07-06)】メンテナンス画面のお問い合わせ mailto URI。
///
/// 件名 + 本文テンプレートを事前入力してメーラーを起動する。ユーザーは
/// 「● 発生日時 / 端末 / OS / 症状」の項目を埋めるだけで送信できる。
///
/// Sabi 静穏原則: 定型テンプレは事務的にならないよう、Sabi の 🪶 マーカーを
/// 冒頭に配置してプロダクトトーンを維持。
///
/// 【FEAT-489 Phase 2D (2026-08-02)】件名 / 本文を arb 化。本関数は定数ファイル内の
/// トップレベル関数で BuildContext を取らないため [ServiceL10n] 経由で解決する。
Uri buildSabiowlMaintenanceContactMailto() {
  final l10n = ServiceL10n.current;
  final subject = l10n.coreMaintenanceContactMailSubject;
  final body = l10n.coreMaintenanceContactMailBody;
  return Uri(
    scheme: 'mailto',
    path: kSabiowlSupportEmail,
    query: 'subject=${Uri.encodeQueryComponent(subject)}'
        '&body=${Uri.encodeQueryComponent(body)}',
  );
}

/// 【2026-06-27】公式 X (旧 Twitter) アカウント。
/// 設定画面「アプリ情報」セクションから外部ブラウザで開く動線。
/// sabiowl-home-pages の index.md / _config.yml にも同じハンドルが記載されている。
const String kSabiowlOfficialXUrl = 'https://x.com/sabiowlapp';

// ── 【FEAT-543 (2026-09-23)】App Store への遷移 ──────────────────────────────

/// App Store の数値 ID。
///
/// 🔵 ストアの公開 URL に出る値なので**秘密ではない**。
/// ⚠️ **ここ以外に書かないこと。** `test/core/store_url_no_literal_test.dart` が
/// 走査で縛っている（`app_version_no_literal_test.dart` と同じ手口）。
const String kAppStoreAppId = '6772130388';

/// App Store アプリを直接開く deep link。**最初にこちらを試す。**
///
/// 🔵 `itms-apps:` は App Store アプリが処理するので、ブラウザを経由しない。
const String kAppStoreDeepLinkUrl =
    'itms-apps://itunes.apple.com/app/id$kAppStoreAppId';

/// deep link が開けなかったときに落とす web URL。
///
/// ⚠️ シミュレータや App Store アプリを無効化した端末では deep link が
/// 開けない。**2 段にしておかないと「押しても何も起きない」になる。**
const String kAppStoreWebUrl = 'https://apps.apple.com/app/id$kAppStoreAppId';

// ⏸️ Android は Play 未公開なので今回は対象外。追加するときは
//    `market://details?id=...` → `https://play.google.com/...` の 2 段で同じ形になる。
