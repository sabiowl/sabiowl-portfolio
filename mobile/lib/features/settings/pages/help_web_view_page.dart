// 【FEAT-485 (2026-07-08)】使い方・ヘルプ画面 (アプリ内 WebView)。
//
// ## 責務
//
// sabiowl-home-pages の使い方ページ (`kSabiowlHelpUrl`) を **アプリ内 WebView**
// で表示する。以下の設計原則:
//
// - **外部ブラウザに飛ばさない**: user が Sabiowl に戻る動線 (Safari から復帰
//   タップ等) を消失させないため。使い方は「困った時に何度でも見たい参照系」
//   情報のため、context 保持を優先。
// - **JavaScript 有効化**: YouTube 動画埋め込み (Web サイト側で `<iframe>`
//   経由の埋め込み想定) の再生を許可するため必須。
// - **WebView 内リンクは同一 WebView 内で遷移**: 使い方サイト内のページ間遷移
//   (help/home.html → help/challenge.html 等) は WebView 内で完結する。外部
//   ドメインへのリンクは特別扱いしない (v1.0 では外部リンク混在は想定なし)。
// - **戻るジェスチャ / AppBar 戻るボタン** で settings 画面に即座に戻る。
//
// ## 既存 URL 経路との使い分け
//
// | 経路 | 開き方 | 想定 |
// |------|--------|------|
// | プライバシー / 利用規約 / 特商法 / リリースノート / FAQ | 外部ブラウザ (launchUrl) | 一度読めば済む |
// | 使い方・ヘルプ (本ページ) | **アプリ内 WebView** | 繰り返し参照 |
//
// この乖離は意図的な設計判断。docstring で明示 (docs/instructions_from_gemini/
// tutorial.md § UX 方針: 「必要なタイミングで確認できる導線」)。
//
// ## Pre-mortem
//
// - **S1 (ネットワーク断)**: onWebResourceError で state を持ち、リトライボタン
//   を表示する。「うまくいきませんでした 🪶」サビ口調エラー。
// - **S2 (レスポンス遅延)**: onProgress で 0-1.0 の進捗を LinearProgressIndicator
//   に反映、user に「読み込み中」を可視化。
// - **S3 (dispose 中の setState race)**: mounted チェックを全 async 経路に配置。
// - **S4 (JavaScript 無効化バグ)**: 明示的に JavaScriptMode.unrestricted で
//   有効化 (webview_flutter default は disabled)。
// - **S5 (仮 URL 段階で 404)**: sabiowl-home-pages に help.html 未配置の間は
//   404 が表示される可能性。onWebResourceError で error state を UI 化するので
//   構造的にハンドリング済。

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../core/constants/app_urls.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';

class HelpWebViewPage extends StatefulWidget {
  const HelpWebViewPage({super.key});

  @override
  State<HelpWebViewPage> createState() => _HelpWebViewPageState();
}

class _HelpWebViewPageState extends State<HelpWebViewPage> {
  late final WebViewController _controller;

  /// 現在のページ読み込み進捗 (0.0 - 1.0)。1.0 = 完了。
  double _progress = 0.0;

  /// ネットワークエラー等で page 読み込みに失敗したかどうか。
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _controller = _buildController();
  }

  WebViewController _buildController() {
    final controller = WebViewController()
      // 【FEAT-485】JavaScript 有効化: YouTube 埋め込み iframe が動作するため必須。
      // webview_flutter の default は disabled のため明示的に unrestricted に。
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(AppTheme.background)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (!mounted) return;
            setState(() => _progress = progress / 100.0);
          },
          onPageStarted: (_) {
            if (!mounted) return;
            setState(() {
              _hasError = false;
              _progress = 0.0;
            });
          },
          onPageFinished: (_) {
            if (!mounted) return;
            setState(() => _progress = 1.0);
          },
          onWebResourceError: (error) {
            if (!mounted) return;
            // 【Pre-mortem S1】メイン frame の error のみ表示。iframe 内 (YouTube
            // 内部エラー等) の error は無視することで、YouTube 動画に一時的な
            // 通信断が起きても page 全体が error 表示にならないようにする。
            if (error.isForMainFrame == true) {
              setState(() => _hasError = true);
            }
          },
        ),
      )
      ..loadRequest(Uri.parse(kSabiowlHelpUrl));
    return controller;
  }

  /// リロードボタン / エラー画面のリトライ経路。
  Future<void> _reload() async {
    if (!mounted) return;
    setState(() {
      _hasError = false;
      _progress = 0.0;
    });
    await _controller.loadRequest(Uri.parse(kSabiowlHelpUrl));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: Text(AppLocalizations.of(context)!.settingsHelpPageTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: AppLocalizations.of(context)!.settingsHelpPageRefreshTooltip,
            onPressed: _reload,
          ),
        ],
      ),
      body: Column(
        children: [
          // ── 読み込み進捗バー (page load 完了まで表示) ────────────────
          if (_progress < 1.0 && !_hasError)
            LinearProgressIndicator(
              value: _progress,
              minHeight: 2,
              backgroundColor: Colors.white.withValues(alpha: 0.08),
              valueColor: const AlwaysStoppedAnimation<Color>(AppTheme.primary),
            ),
          // ── メイン領域: WebView または エラー画面 ────────────────────
          Expanded(
            child: _hasError
                ? _ErrorView(onRetry: _reload)
                : WebViewWidget(controller: _controller),
          ),
        ],
      ),
    );
  }
}

/// ネットワーク断 / 404 等でメイン frame 読み込みに失敗した場合の error 画面。
/// サビ口調 + リトライボタン + 「あとで見る」で戻れる導線。
class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined,
                size: 56, color: Colors.white38),
            const SizedBox(height: 16),
            Text(
              l10n.settingsHelpPageErrorTitle,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.settingsHelpPageErrorBodySabi_message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 13,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: Text(l10n.settingsHelpPageRetryButton),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                foregroundColor: Colors.white,
                minimumSize: const Size(240, 44),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
