/// 【FEAT-489 Phase 2G-a (2026-08-02)】アプリの表示 locale の解決と保持。
///
/// ## ⚠️ BUG-27: `locale` を null にしてはいけない
///
/// 漢字が中国語グリフで描画される BUG-27 は、**日本語フォントを同梱して解決したの
/// ではない**。`pubspec.yaml` の `fonts:` はコメントアウトのままで、
/// `app_theme.dart` の `fontFamily: 'NotoSansJP'` も無効。
/// **`MaterialApp.locale` に明示値を渡すことだけが唯一の防御**である。
///
/// したがって:
///
/// ```dart
/// locale: null,                          // ❌ 中文端末で BUG-27 が再発する
/// locale: ref.watch(appLocaleProvider),  // ✅ 常に ja_JP か en のどちらか
/// ```
///
/// 端末 locale から解決する場合も **`ja` / `en` 以外は必ず `ja` に丸める**。
/// この不変条件は `test/i18n_locale_guard_test.dart` が CI で固定している。
///
/// ## 解決順序
///
/// 1. ユーザーが設定画面で選んだ言語 (SharedPreferences、`runApp` 前に読む)
/// 2. 端末 locale の **先頭 1 つだけ** を見て `en` なら en、それ以外は ja
/// 3. 既定 `ja`
///
/// 2 で先頭しか見ないのは意図的。端末の優先言語リストが `[zh, en]` のような
/// 中文端末で `en` に落ちると、UI は英語になるがユーザーが日本語を選び直した
/// 瞬間に BUG-27 の条件に入る。**中文端末は必ず ja に着地させる**。
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';

/// 日本語 locale。`countryCode` まで指定するのは BUG-27 の経緯を踏襲するため。
const Locale kJaLocale = Locale('ja', 'JP');

/// 英語 locale。地域は限定しない (US / UK / AU / CA すべて同じ arb で受ける)。
const Locale kEnLocale = Locale('en');

/// `MaterialApp.supportedLocales` に渡す唯一の正。
///
/// **3 つ目を足すときは BUG-27 の再検証が必須** (該当言語のグリフが端末フォントに
/// あるか / 日本語グリフに干渉しないか)。
const List<Locale> kSupportedLocales = [kJaLocale, kEnLocale];

/// SharedPreferences のキー。Backend の `PlayerSettings.preferred_language` と同名。
const String kPreferredLanguageKey = 'preferred_language';

/// 任意の言語コードを **`ja` か `en` のどちらか** に丸める。
///
/// `en` で始まるものだけが en。`zh` / `ko` / 未知 / null はすべて ja
/// (BUG-27 防御。§2.1 の「zh / ko 端末が en にも zh にも落ちないようにする」)。
String normalizeLanguageCode(String? code) {
  if (code == null) return 'ja';
  return code.toLowerCase().startsWith('en') ? 'en' : 'ja';
}

/// 正規化済みの言語コードを [Locale] に変換する。
Locale localeForLanguageCode(String code) =>
    normalizeLanguageCode(code) == 'en' ? kEnLocale : kJaLocale;

/// 起動時の locale を解決する。**戻り値は必ず non-null**。
///
/// - [savedLanguageCode]: SharedPreferences に保存されたユーザー選択 (null = 未選択)
/// - [deviceLocale]: 端末の **先頭** locale (`platformDispatcher.locale`)
Locale resolveInitialLocale({
  String? savedLanguageCode,
  Locale? deviceLocale,
}) {
  if (savedLanguageCode != null && savedLanguageCode.isNotEmpty) {
    return localeForLanguageCode(savedLanguageCode);
  }
  return localeForLanguageCode(normalizeLanguageCode(deviceLocale?.languageCode));
}

/// `main()` が解決した起動時 locale を注入するための seam。
///
/// `ProviderScope.overrides` で上書きする。override 忘れでも ja に落ちるので
/// BUG-27 の観点では安全側。
final initialLocaleProvider = Provider<Locale>((ref) => kJaLocale);

/// 言語切替に伴う副作用 (永続化 / キャッシュ破棄 / Backend 同期) をまとめた seam。
///
/// [AppLocaleController] から切り離してあるのは、**「UI の切替が I/O の成否に
/// 依存しない」という契約をテストで固定するため**。テストでは
/// [localeSideEffectsProvider] を差し替えて、失敗しても state が切り替わることを
/// 検証する (Phase 2G-a Pre-mortem S4)。
class LocaleSideEffects {
  const LocaleSideEffects(this._ref);

  final Ref _ref;

  /// [next] に切り替わった後に実行する。**呼び出し元に例外を伝播させない**。
  Future<void> apply(Locale next) async {
    // ① ローカル永続化。`main()` が runApp 前に読んで起動時 locale を決める。
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kPreferredLanguageKey, next.languageCode);
    } catch (_) {
      // 失敗しても当該セッションの表示には影響しない (次回起動で元に戻るだけ)
    }

    final api = _ref.read(apiClientProvider);

    // ② 応答キャッシュを破棄する (Phase 2E S6 の回収)。
    //    FEAT-476 の DioCacheInterceptor は ja で取得した応答を保持しているので、
    //    捨てないと「切り替えたのにサビの台詞だけ日本語」になる。
    //    **PATCH より先に**捨てる (後だと PATCH の応答経路で古い値を引き得る)。
    await api.clearResponseCache();

    // ③ Backend の `PlayerSettings.preferred_language` を更新する。
    //
    //    **best-effort**。オフライン / 401 で失敗しても UI 切替は既に成立して
    //    おり、`Accept-Language` ヘッダ (Phase 2E) が次回リクエストから正しい
    //    言語を引くので Backend 由来テキストも英語で返る。
    //    したがってここで失敗しても呼び出し元にエラーを伝えない (S4)。
    //
    //    【2026-08-02】この「PATCH が失敗しても Accept-Language が救う」は
    //    **書いた時点では成立していなかった**。Backend の I18nMiddleware が
    //    `preferred_language` を最優先しており、その field は `default='ja'` で
    //    「未設定」を表現できないため、認証済ユーザーではヘッダが読まれる
    //    ことが無かったため (20260802 functional review 懸念点 2)。
    //    Backend 側の優先順位を Accept-Language 優先に入れ替えたことで、
    //    この記述は**いま実際に成立している** (doc/design/backend_i18n.md §2.4)。
    try {
      await api.dio.patch<void>(
        '/player/',
        data: {kPreferredLanguageKey: next.languageCode},
      );
    } catch (_) {
      // Accept-Language が fallback として効くので握りつぶす
    }
  }
}

final localeSideEffectsProvider =
    Provider<LocaleSideEffects>(LocaleSideEffects.new);

/// アプリの表示 locale を保持する。`MaterialApp.locale` はこれを watch する。
///
/// **state は必ず [kSupportedLocales] のいずれか**。[setLanguage] は入力を
/// [normalizeLanguageCode] で丸めてから反映するので、外部から未対応 locale を
/// 注入することはできない (BUG-27 の構造的防御)。
class AppLocaleController extends StateNotifier<Locale> {
  AppLocaleController(this._ref) : super(_ref.read(initialLocaleProvider));

  final Ref _ref;

  /// 現在の言語コード (`'ja'` | `'en'`)。
  String get languageCode => state.languageCode;

  /// 表示言語を切り替える。[code] は ja/en に丸められる。
  ///
  /// **state を先に更新してから副作用を走らせる**。副作用が全部失敗しても
  /// 当該セッションの UI は切り替わる (Pre-mortem S4)。
  Future<void> setLanguage(String code) async {
    final next = localeForLanguageCode(code);
    if (next == state) return;

    state = next;

    // 副作用の失敗で切替を巻き戻さない。`LocaleSideEffects.apply` は内部でも
    // catch しているが、**契約を実装の内側の規律に委ねない**ためここでも囲う
    // (S4: PATCH が失敗しても切替自体は成立させる)。
    try {
      await _ref.read(localeSideEffectsProvider).apply(next);
    } catch (_) {
      // 呼び出し元 (設定画面) は切替成功として扱ってよい
    }
  }
}

final appLocaleProvider =
    StateNotifierProvider<AppLocaleController, Locale>(AppLocaleController.new);
