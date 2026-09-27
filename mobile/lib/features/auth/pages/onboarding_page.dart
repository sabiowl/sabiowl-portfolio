import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/analytics/posthog_service.dart';  // FEAT-200
import '../../../l10n/app_localizations.dart';
import '../../../core/api/api_client.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
// 【BUG (2026-07-02)】_complete で PATCH/select 後の player scoped invalidate 用。
import '../../../core/cache/cache_service.dart' show cacheServiceProvider;
import '../../habits/providers/habits_provider.dart' show playerNotifierProvider;
import '../../habits/providers/home_bootstrap_provider.dart'
    show homeBootstrapRawProvider, kHomeBootstrapCacheKey;
import '../../timeline/providers/timeline_provider.dart';  // FEAT-233: timelineAutoCreateProvider
import '../services/onboarding_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// データ定義
// ─────────────────────────────────────────────────────────────────────────────

class _WorldSlide {
  final String emoji;
  final double emojiSize;
  final String title;
  final String subtitle;
  /// 【FEAT-320 (2026-05-27)】imagePath が指定されている場合は emoji の代わりに
  /// Image.asset で表示する。welcome step (サビ自己紹介) で 🪶 絵文字を
  /// sabi_unified.png に置換するために導入。
  final String? imagePath;

  const _WorldSlide({
    required this.emoji,
    this.emojiSize = 72,
    required this.title,
    required this.subtitle,
    this.imagePath,
  });
}

const _kWorldSlideCount = 3;

List<_WorldSlide> _getWorldSlides(AppLocalizations l10n) => [
  _WorldSlide(
    emoji:     '🪶',
    emojiSize: 88,
    // 【FEAT-320】チュートリアル welcome 画面のフクロウ 🪶 emoji を sabi_unified.png
    // (PixelLab 92×92 ドット絵) に置換。FEAT-316 でアプリ全体のサビ画像を統一済の
    // ため、OnboardingPage のここだけ emoji 残置の不整合を解消。emoji フィールドは
    // 画像読み込み失敗時のフォールバックとして残す。
    imagePath: 'assets/images/sabi/sabi_unified.webp',
    title:    l10n.authOnboardingSlide1TitleSabi_message,
    subtitle: l10n.authOnboardingSlide1SubtitleSabi_message,
  ),
  _WorldSlide(
    emoji:    '📅',
    title:    l10n.authOnboardingSlide2Title,
    subtitle: l10n.authOnboardingSlide2SubtitleSabi_message,
  ),
  _WorldSlide(
    emoji:    '🌙',
    title:    l10n.authOnboardingSlide3Title,
    subtitle: l10n.authOnboardingSlide3SubtitleSabi_message,
  ),
];

/// スターターキャラクターの定義（バックエンド API 不要のローカルデータ）。
///
/// 【FEAT-192】`imagePath` を追加。`_CharacterCard` で画像主体の表示に切り替え、
/// `emoji` はアセット読み込み失敗時のフォールバックとして残す。
class _StarterCharacter {
  final String key;
  final String imagePath;
  final String emoji;
  final String name;
  final String role;
  final String description;

  const _StarterCharacter({
    required this.key,
    required this.imagePath,
    required this.emoji,
    required this.name,
    required this.role,
    required this.description,
  });
}

// 【FEAT-391 ジョブ名統一】role を Backend の Job 名と整合させた。
// 並び順: ソウル, アリア (2 列 1 行、「直球 vs 機動」の対比軸)
// 【FEAT-322 (2026-05-27)】noir / zenon は starter から除外、ガチャ収集枠。
// 【BUG-103 (2026-06-14)】旧 rune (ルーン) → cyan (シアン) に rename (migration 0137)。
// 【BUG-105 (2026-06-14)】starter pool を 6 → 2 に縮小 (migration 0139)。
//   faye/lucia/cyan/beatrix は starter 外し、ダイヤ購入 (800💎) に移行。
//   残った 2 体: sol (戦士、直球アタッカー) / aria (アサシン、機動型)。
//   対比軸を明示することで「初期ジョブ理解」を促進する PM 判断。
List<_StarterCharacter> _getStarters(AppLocalizations l10n) => [
  _StarterCharacter(
    key:         'sol',
    imagePath:   'assets/images/characters/character_sol.webp',
    emoji:       '☀️',
    name:        l10n.authStarterSolName,
    role:        l10n.battleJobNameWarrior,
    description: l10n.authStarterSolDescription,
  ),
  _StarterCharacter(
    key:         'aria',
    imagePath:   'assets/images/characters/character_aria.webp',
    emoji:       '🌟',
    name:        l10n.authStarterAriaName,
    role:        l10n.battleJobNameAssassin,
    // 【2026-05-30】description を新ジョブ (アサシン) と整合。旧文「知識と魔法の力で...」は
    // 旧ジョブ (魔法使い) 時代の文章のまま残っていた = FEAT-391 移行後の取り残し。
    description: l10n.authStarterAriaDescription,
  ),
];

// ─────────────────────────────────────────────────────────────────────────────
// OnboardingPage
// ─────────────────────────────────────────────────────────────────────────────

/// 全ステップ数（世界観スライド3枚 + 性別選択1 + 名前入力1 + キャラ選択1 = 6）
/// `_worldSlides.length + 3` と等価。
/// BUG-30: Dart の const 評価はユーザー定義クラス（_WorldSlide）の List.length を
/// 定数式で使えないためリテラル化。`_worldSlides` の枚数を変える場合はここも合わせて更新。
/// 【FEAT-221】性別選択ステップを追加し 5→6 に拡張（2026-05-15）。
const _kTotalSteps = 6;

class OnboardingPage extends ConsumerStatefulWidget {
  const OnboardingPage({super.key});

  @override
  ConsumerState<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends ConsumerState<OnboardingPage>
    with SingleTickerProviderStateMixin {
  final _pageController = PageController();
  final _nameController = TextEditingController();
  final _nameFocusNode  = FocusNode();

  int     _currentStep     = 0;
  /// 【FEAT-194】スキップ廃止に伴い、明示選択を強制するため null 初期化に変更。
  /// 「はじめよう」ボタンは `_selectedCharKey != null` のときだけ活性化する。
  String? _selectedCharKey;
  /// 【FEAT-221】性別選択（'f' / 'm'、null は未選択）。明示選択を強制する。
  /// `PlayerProfile.GENDER_CHOICES`（backend/api/models/player.py）と整合。
  String? _selectedGender;
  bool    _isCompleting    = false;

  // 【FEAT-221】ステップ配置（世界観 3 → 性別 → 名前 → キャラ）
  bool get _isGenderStep    => _currentStep == _kWorldSlideCount;
  bool get _isNameStep      => _currentStep == _kWorldSlideCount + 1;
  bool get _isCharacterStep => _currentStep == _kWorldSlideCount + 2;

  @override
  void initState() {
    super.initState();
    // FEAT-200: オンボーディング開始をトラッキング。
    // `path` はゲスト経由 / ソーシャル新規経由のどちらかを判定して送る。
    // 現時点では ApiClient のトークン状態から推定（hg_token があれば social、なければ guest）。
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final apiClient = ref.read(apiClientProvider);
      final hasUserToken = (await apiClient.getToken())?.isNotEmpty ?? false;
      await PosthogService.instance.capture('onboarding_started', properties: {
        'path': hasUserToken ? 'social' : 'guest',
      });
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    _nameController.dispose();
    _nameFocusNode.dispose();
    super.dispose();
  }

  // ── ナビゲーション ───────────────────────────────────────────────────────

  void _nextStep() {
    if (_currentStep >= _kTotalSteps - 1) return;

    // 【FEAT-221】性別未選択ガード（明示選択を強制、キャラ選択と同じ UX）
    if (_isGenderStep && _selectedGender == null) {
      HapticFeedback.lightImpact();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:  Text(AppLocalizations.of(context)!.authOnboardingGenderRequiredSnackbar),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    // 名前入力ステップで空欄チェック
    if (_isNameStep) {
      final name = _nameController.text.trim();
      if (name.isEmpty) {
        HapticFeedback.lightImpact();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:  Text(AppLocalizations.of(context)!.authOnboardingNameRequiredSnackbar),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }
      _nameFocusNode.unfocus();
    }

    setState(() => _currentStep++);
    _pageController.nextPage(
      duration: const Duration(milliseconds: 350),
      curve:    Curves.easeInOut,
    );
  }

  /// 【FEAT-192】前のステップへ戻る。
  /// 名前入力・キャラ選択の state は保持されているため、戻っても入力済みデータは消えない。
  void _prevStep() {
    if (_currentStep <= 0) return;
    HapticFeedback.lightImpact();
    // 名前入力中なら IME を閉じてから戻る
    if (_isNameStep) _nameFocusNode.unfocus();
    setState(() => _currentStep--);
    _pageController.animateToPage(
      _currentStep,
      duration: const Duration(milliseconds: 300),
      curve:    Curves.easeInOut,
    );
  }

  // 【FEAT-194】スキップ機能は廃止。
  //   理由:
  //     1. 旧実装は `_selectedCharKey = 'aria'` のまま完了させており、
  //        「スキップ」表記と「aria 強制選択」の挙動が一致していなかった
  //     2. キャラ選択は Sabiowl のコア体験。明示選択で愛着を育てる UX を強制
  //     3. キャラはホーム → キャラ画面で常時変更可能なので柔軟性は失われない

  /// オンボーディング完了処理
  ///
  ///   1. `PATCH /api/player/` で名前と性別を反映
  ///   2. `POST /api/characters/<id>/select/` でキャラ選択を反映
  ///
  /// 🔴 【FEAT-542 (2026-09-23)】**トークンはここで作らない。**
  ///
  /// 旧実装は「ゲストトークンが無ければ `guest-init` を呼ぶ」を持っており、
  /// それが 3 つの不具合の共通の根だった:
  ///
  /// | | 何が起きたか |
  /// |---|---|
  /// | BUG-161 | `authProvider` を通さないので status が古く、完了直後にログイン画面へ弾かれた |
  /// | BUG-166 | 連携済みユーザーが再インストールしただけで「新しいゲスト」にされた |
  /// | 計測欠落 | `guest_session_started` が新規ユーザーに送られていなかった |
  ///
  /// 🔵 **トークンを作るのは `authProvider` だけになった。**
  /// ゲストは認証画面の「ゲストとして始める」→ `startAsGuest()` を通り、
  /// `justRegistered=true` → `AuthPage` の `ref.listen` 経由でここへ来る
  /// （ソーシャルの新規ユーザーと**同じ経路**）。
  /// 🔴 **「状態が古いまま `/home` へ行く」経路は、ガードで防がれるのではなく
  /// 存在しなくなった。** だから BUG-161 の `refreshAuthStatus()` も要らない。
  Future<void> _complete() async {
    if (_isCompleting) return;
    setState(() => _isCompleting = true);

    try {
      final name = _nameController.text.trim().isEmpty
          ? AppLocalizations.of(context)!.authOnboardingDefaultName
          : _nameController.text.trim();

      final apiClient = ref.read(apiClientProvider);

      // 🔵 計測の `path` を決めるためだけに読む。
      //    **トークンの有無で分岐する処理はもう無い。**
      final hasUserToken  = (await apiClient.getToken())?.isNotEmpty ?? false;

      // ── 1. プレイヤー名 + 性別を即時反映 ────────────────────────
      // 【FEAT-221】性別もここで PATCH。`PlayerProfileSerializer.fields` には
      // `gender` が writable で含まれている（backend/api/serializers.py L255）。
      try {
        await apiClient.dio.patch('/player/', data: {
          'name': name,
          if (_selectedGender != null) 'gender': _selectedGender,
        });
      } on DioException {
        // 失敗してもログイン/ホーム遷移は止めない（ユーザーは後で編集可能）
      }

      // ── 2. キャラクター選択を反映 ──────────────────────────────
      // GET /characters/ で key→id のマッピングを取得して POST /characters/<id>/select/
      //
      // 【FEAT-221】防御的ハードニング: 旧実装は `on DioException` のみキャッチしていたが、
      // 以下のケースで Throwable が漏れて画面遷移が中断されていた可能性あり:
      //   - res.data の要素が Map<String, dynamic> でない（cast 時に TypeError）
      //   - res.data がそもそも List/Map 以外（型キャスト中の予期せぬ例外）
      //   - Character DB シード未実行で空リスト返却（無害だが要ログ）
      //   - GET /characters/ で 403/404（DioException でキャッチされるが silent）
      // 広範な `catch (e)` + debugPrint でアプリ落ちを完全に防止する。
      try {
        final res = await apiClient.dio.get('/characters/');
        final raw = res.data;
        if (raw is! List) {
          debugPrint('[Onboarding] /characters/ unexpected type: ${raw.runtimeType}');
        } else if (raw.isEmpty) {
          debugPrint('[Onboarding] /characters/ returned empty list (DB seed missing?)');
        } else {
          // cast を安全に: 各要素が Map である保証はないので whereType でフィルタ
          final list = raw.whereType<Map<String, dynamic>>().toList();
          if (list.isEmpty) {
            debugPrint('[Onboarding] /characters/ items are not Map<String, dynamic>');
          } else {
            final hit = list.firstWhere(
              (c) =>
                  (c['key']?.toString() ?? '') == _selectedCharKey ||
                  (c['name']?.toString() ?? '') == _selectedCharKey,
              orElse: () => const <String, dynamic>{},
            );
            final charId = hit['id'];
            if (charId is int) {
              await apiClient.dio.post('/characters/$charId/select/');
            } else {
              debugPrint(
                '[Onboarding] no character matched key=$_selectedCharKey '
                '(DB has ${list.length} chars)',
              );
            }
          }
        }
      } catch (e, stack) {
        // DioException も TypeError も全て吸収して遷移を継続。
        // ユーザーは後で Character ページから再選択可能。
        debugPrint('[Onboarding] character selection swallowed: $e\n$stack');
      }

      // ── 3. ローカルにも名前・キャラを保存（既存挙動を維持）─────
      await OnboardingService.saveName(name);
      // 【FEAT-194】_selectedCharKey は nullable 化したが、本フローに到達した時点で
      // 「はじめよう」ボタンの活性条件により null ではないことが保証されている。
      // 防御的に null チェックして保存をスキップ。
      final charKey = _selectedCharKey;
      if (charKey != null && charKey.isNotEmpty) {
        await OnboardingService.saveCharacterKey(charKey);
      }

      // ── 4. 【FEAT-233】当日のデフォルトタイムライン予定を確実に自動作成 ──
      // 旧実装は TimelineDashboard の initState postFrameCallback に任せていたが、
      // Render コールドスタート時に初回呼び出しが失敗すると失敗時も createdIds に
      // 記録されて当日中 blacklist 化される（BUG-T workaround）。ユーザーが
      // template を無効化 → 有効化しないと表示されない UX を引き起こしていた。
      // 本タイミング（name PATCH + character select 完了後）ならサーバーが
      // 温まっているため成功率が高い。失敗時もユーザーが手動で template を
      // 触れるので致命的ではないが、新規体験のために確実に await する。
      final now   = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      try {
        await ref.read(timelineAutoCreateProvider(today).future);
      } catch (e) {
        // 失敗時も home 遷移は止めない（ユーザーは後で手動で template を有効化可能）
        debugPrint('[Onboarding] timelineAutoCreate failed: $e');
      }

      // ── 5. 🔴 プロフィール設定の完了を、**持ち主付きで**記録する ────
      //
      // 🔴 【FEAT-542 (2026-09-23)】旧 `markTutorialShown()` の後継である。
      // 旧キーは「チュートリアルを見たか」と「プロフィール設定が終わったか」を
      // 兼任しており、**分岐に使われていたのは後者だけ**だった。
      //
      // ⚠️ **値には持ち主（いまの資格情報の指紋）が入る。** 端末に
      // 付いた真偽値のままだと、**古い「設定済み」を新しいゲストが引き継ぐ** ——
      // 連携済みユーザーのトークンが消える -> ゲストとして始める ->
      // 設定の途中で kill -> 再起動でホームへ（名前「ゲスト」+ キャラ未選択）。
      //
      // ⚠️ **ここに置く。** 上の PATCH とキャラ選択より前に書くと、
      //    途中で落ちたときに「設定済みだが名前もキャラも無い」が残る。
      await apiClient.markProfileSetupCompleted();

      // ── 6. player scoped provider を invalidate (2026-07-02 BUG hotfix) ──
      // 【症状】ゲストモードで onboarding を完了して home に到達した直後、
      // 画面上部のステータス枠に name='ゲスト' + キャラ画像=ゼノン (fallback)
      // が表示されてしまう。画面遷移して戻る等の再読み込みで正しい値
      // (入力した名前 + 選択したキャラ) に切り替わる。
      //
      // 【真因】OnboardingPage._complete の PATCH /player/ + POST
      // /characters/<id>/select/ は Backend を正しく更新している (再読み込みで
      // 治ることが証拠) が、Riverpod の `playerNotifierProvider` /
      // `homeBootstrapRawProvider` の invalidate をこの経路で行っていない。
      //
      // ・startAsGuest 経由: `_invalidateAllPlayerScopedProviders` で invalidate
      //   済 (auth_provider.dart) だが、その後の PATCH で内容が変わったのに
      //   再 invalidate されないため、home 到達時の initial build 前に
      //   何らかの経路で stale state が注入されると旧値表示になる。
      // ・真初回起動 (Splash → /onboarding 直行) 経路: startAsGuest を通らない
      //   ので invalidate すら実行されない。
      //
      // 【修正】PATCH + select 完了後、確実に fresh fetch が走るよう
      // player scoped provider + home bootstrap cache を明示 invalidate する。
      // 「サーバーは正しい状態」→「そこから改めて fetch させる」単一防御点。
      //
      // 実装補足: `invalidateHomeBootstrapCache(Ref)` は Provider ref 前提の
      // helper で WidgetRef を受けられないため、ここでは同等の 2 ステップ
      // (cache 削除 + provider invalidate) を直接 WidgetRef で実行する。
      try {
        await ref
            .read(cacheServiceProvider)
            .invalidate(kHomeBootstrapCacheKey);
      } catch (e) {
        debugPrint('[Onboarding] home bootstrap cache invalidate failed: $e');
      }
      ref.invalidate(homeBootstrapRawProvider);
      ref.invalidate(playerNotifierProvider);

      // FEAT-200: オンボーディング完了をトラッキング。
      // `path` は冒頭で取得済みの `hasUserToken` をそのまま流用
      // （`/api/player/` PATCH 〜 キャラ選択中にトークン状態は変わらない）。
      await PosthogService.instance.capture('onboarding_completed', properties: {
        'path': hasUserToken ? 'social' : 'guest',
        if (charKey != null && charKey.isNotEmpty) 'selected_character': charKey,
      });

      if (!mounted) return;
      context.go(AppRoutes.home);
    } catch (_) {
      if (mounted) setState(() => _isCompleting = false);
    }
  }

  // ── build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final slides = _getWorldSlides(l10n);
    // 【FEAT-192】Android 物理戻る / iOS スワイプバックでも _prevStep に倒す。
    // 最初のステップ (step 0) では canPop=true → 通常通り pop してタイトル画面へ。
    return PopScope(
      canPop: _currentStep == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _prevStep();
      },
      child: Scaffold(
      backgroundColor: AppTheme.surface,
      body: SafeArea(
        child: Column(
          children: [
            // ── ステップインジケーター ─────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(_kTotalSteps, (i) {
                  final isActive  = i == _currentStep;
                  final isVisited = i < _currentStep;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    margin:   const EdgeInsets.symmetric(horizontal: 4),
                    width:    isActive ? 20 : 8,
                    height:   8,
                    decoration: BoxDecoration(
                      color: isActive || isVisited
                          ? AppTheme.primary
                          : Colors.white24,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  );
                }),
              ),
            ),

            // ── ページコンテンツ ───────────────────────────────────────────
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                // スワイプ無効化（ボタン操作のみ）
                physics:    const NeverScrollableScrollPhysics(),
                itemCount:  _kTotalSteps,
                onPageChanged: (i) => setState(() => _currentStep = i),
                itemBuilder: (_, i) {
                  if (i < _kWorldSlideCount) {
                    return _buildWorldSlide(slides[i]);
                  }
                  // 【FEAT-221】性別選択 → 名前入力 → キャラ選択 の 3 ステップ
                  if (i == _kWorldSlideCount) {
                    return _buildGenderStep(l10n);
                  }
                  if (i == _kWorldSlideCount + 1) {
                    return _buildNameStep(l10n);
                  }
                  return _buildCharacterStep(l10n);
                },
              ),
            ),

            // ── ボトムナビゲーション ───────────────────────────────────────
            _buildBottomNav(l10n),
          ],
        ),
      ),
      ),
    );
  }

  // ── 世界観スライド ───────────────────────────────────────────────────────

  Widget _buildWorldSlide(_WorldSlide slide) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 36),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // 【FEAT-320】imagePath が指定されている場合は Image.asset で表示。
          // emoji フィールドは画像読み込み失敗時のフォールバック。
          if (slide.imagePath != null)
            SizedBox(
              width:  slide.emojiSize,
              height: slide.emojiSize,
              child: Image.asset(
                slide.imagePath!,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.none,  // ドット絵 Nearest Neighbor
                errorBuilder: (_, __, ___) => Text(
                  slide.emoji,
                  style: TextStyle(fontSize: slide.emojiSize),
                ),
              ),
            )
          else
            Text(slide.emoji, style: TextStyle(fontSize: slide.emojiSize)),
          const SizedBox(height: 36),
          Text(
            slide.title,
            style: const TextStyle(
              color:      Colors.white,
              fontSize:   22,
              fontWeight: FontWeight.bold,
              height:     1.4,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Text(
            slide.subtitle,
            style: const TextStyle(
              color:    Colors.white54,
              fontSize: 14,
              height:   1.7,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  // ── 性別選択ステップ（FEAT-221） ────────────────────────────────────────

  Widget _buildGenderStep(AppLocalizations l10n) {
    // 【FEAT-221】PlayerProfile.GENDER_CHOICES（backend/api/models/player.py）は
    // 現在 2 値（'f' / 'm'）。本ステップも同 2 値で実装する。
    // 「その他」は将来モデル拡張時に別 FEAT で追加。
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 36),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // 【FEAT-322 (2026-05-27)】🪶 emoji を sabi_unified.png に置換。
          // FEAT-316/320 で他全箇所のサビ画像を sabi_unified.png に統一済の
          // 取り残し (性別選択 / 名前入力 step の 2 箇所) を解消、世界観整合確保。
          // emoji フィールドは画像読み込み失敗時のフォールバック。
          SizedBox(
            width:  52,
            height: 52,
            child: Image.asset(
              'assets/images/sabi/sabi_unified.webp',
              fit: BoxFit.contain,
              filterQuality: FilterQuality.none,  // ドット絵 Nearest Neighbor
              errorBuilder: (_, __, ___) =>
                  const Text('🪶', style: TextStyle(fontSize: 52)),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            l10n.authOnboardingGenderTitle,
            style: const TextStyle(
              color:      Colors.white,
              fontSize:   20,
              fontWeight: FontWeight.bold,
              height:     1.4,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            l10n.authOnboardingGenderSubtitle,
            style: const TextStyle(color: Colors.white54, fontSize: 13),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          // 【FEAT-233】3 値化（男性 / 女性 / 回答しない）+ 順序変更。
          // PlayerProfile.GENDER_CHOICES と完全整合。「回答しない」はプライバシー配慮の選択肢。
          for (final option in [
            ('m', l10n.authOnboardingGenderMale,      Icons.male),
            ('f', l10n.authOnboardingGenderFemale,    Icons.female),
            ('n', l10n.authOnboardingGenderNotAnswer, Icons.do_not_disturb_alt_outlined),
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _GenderOption(
                code:       option.$1,
                label:      option.$2,
                icon:       option.$3,
                isSelected: _selectedGender == option.$1,
                onTap: () {
                  HapticFeedback.selectionClick();
                  setState(() => _selectedGender = option.$1);
                },
              ),
            ),
        ],
      ),
    );
  }

  // ── 名前入力ステップ ─────────────────────────────────────────────────────

  Widget _buildNameStep(AppLocalizations l10n) {
    // 【FEAT-194】キーボード表示時のオーバーフロー対策。
    //   - SingleChildScrollView でラップしてスクロール可能に
    //   - bottom padding に viewInsets.bottom を加算して IME 領域を確保
    //   - 上下 margin を縮小（20→16, 32→24）して余裕を作る
    //   - TextField の counter を buildCounter で非表示にして高さを ~11px 削減
    return SingleChildScrollView(
      padding: EdgeInsets.only(
        left:   32,
        right:  32,
        top:    24,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize:       MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 【FEAT-322 (2026-05-27)】🪶 emoji を sabi_unified.png に置換 (性別選択
          // step と同パターン)。FEAT-316/320 のサビ画像統一の取り残し解消。
          SizedBox(
            width:  52,
            height: 52,
            child: Image.asset(
              'assets/images/sabi/sabi_unified.webp',
              fit: BoxFit.contain,
              filterQuality: FilterQuality.none,
              errorBuilder: (_, __, ___) =>
                  const Text('🪶', style: TextStyle(fontSize: 52)),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            l10n.authOnboardingNameTitle,
            style: const TextStyle(
              color:      Colors.white,
              fontSize:   20,
              fontWeight: FontWeight.bold,
              height:     1.4,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.authOnboardingNameSubtitleSabi_message,
            style: const TextStyle(
              color:    Colors.white54,
              fontSize: 13,
              height:   1.5,
            ),
          ),
          const SizedBox(height: 24),
          TextField(
            controller:      _nameController,
            focusNode:       _nameFocusNode,
            autofocus:       true,
            maxLength:       20,
            // FEAT-194: カウンター非表示で高さを削減（20 文字制限は維持）
            buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
            style: const TextStyle(color: Colors.white, fontSize: 18),
            textInputAction: TextInputAction.done,
            onSubmitted:     (_) => _nextStep(),
            decoration: InputDecoration(
              counterText: '',
              hintText:    l10n.authOnboardingNameHint,
              hintStyle:   const TextStyle(color: Colors.white24),
              filled:      true,
              fillColor:   Colors.white.withValues(alpha: 0.07),
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 20, vertical: 16),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide:   BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(
                    color: AppTheme.primary, width: 1.5),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── キャラ選択ステップ ───────────────────────────────────────────────────

  Widget _buildCharacterStep(AppLocalizations l10n) {
    // 【FEAT-194】オーバーフロー対策:
    //   - mainAxisSize.min を明示してコンテンツ高さに合わせる
    //   - childAspectRatio: 0.78 → 0.85 で各セル高さを削減
    //   - mainAxisSpacing/crossAxisSpacing 10 → 8 で密度向上
    //   - 余白縮小（24→20、16→12、bottom 0→16）
    //   - 未選択時の説明文プレースホルダで AnimatedSwitcher の高さブレを抑制
    //
    // 【FEAT-194】カード本体（画像サイズ等）は `_CharacterCard` 側で 56×56 に縮小済み。
    final starters = _getStarters(l10n);
    final selected = starters.where((c) => c.key == _selectedCharKey).toList();
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l10n.authOnboardingCharacterTitle,
            style: const TextStyle(
              color:      Colors.white,
              fontSize:   20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.authOnboardingCharacterSubtitle,
            style: const TextStyle(color: Colors.white54, fontSize: 13),
          ),
          const SizedBox(height: 24),
          // 【2026-07-09 hotfix】旧 8 スターター (FEAT-233) 時代の横長レイアウト
          // (childAspectRatio: 2.4、画像 48px + 名前・役割) は、v1 の 2 キャラ
          // (ソウル / アリア) 構成では 1 行にコンパクトに収まってしまい、初回
          // onboarding での「仲間を選ぶ」体験の重みが弱くなっていた。
          // 2 キャラ縦長ヒーローカードに変更 (childAspectRatio: 0.85、画像 120px
          // + 大きめの名前・役割) して選択肢の存在感を強調する。
          //
          // v1.1+ でキャラが 3+ に増えた場合は、childAspectRatio と layout の
          // 再検討が必要 (2 列 × 2 行 or 3 列でヒーロー継続、等)。
          GridView.count(
            crossAxisCount:   2,
            shrinkWrap:       true,
            physics:          const NeverScrollableScrollPhysics(),
            mainAxisSpacing:  12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.85,  // 縦長ヒーロー (W:H ≒ 1:1.18) で画像大きめ + 名前・役割下配置
            children: starters
                .map((c) => _CharacterCard(
                      character:  c,
                      isSelected: _selectedCharKey == c.key,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        setState(() => _selectedCharKey = c.key);
                      },
                    ))
                .toList(),
          ),
          const SizedBox(height: 12),
          // 選択中キャラの説明文（未選択時は高さプレースホルダで AnimatedSwitcher のレイアウト揺れを防ぐ）
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: selected.isNotEmpty
                ? Text(
                    selected.first.description,
                    key:       ValueKey(_selectedCharKey),
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 12, height: 1.4),
                    textAlign: TextAlign.center,
                  )
                : const SizedBox(
                    key: ValueKey('empty'),
                    height: 18,
                  ),
          ),
        ],
      ),
    );
  }

  // ── ボトムナビゲーション ─────────────────────────────────────────────────

  Widget _buildBottomNav(AppLocalizations l10n) {
    final isLastStep = _currentStep == _kTotalSteps - 1;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        8,
        24,
        MediaQuery.of(context).padding.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 【FEAT-192】「前へ」ボタン（ステップ 1 以降のみ表示）
          if (_currentStep > 0)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _isCompleting ? null : _prevStep,
                icon:  const Icon(Icons.arrow_back, size: 16),
                label: Text(l10n.authOnboardingPrevButton),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white70,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
                ),
              ),
            ),
          // メインボタン
          //
          // 【FEAT-194】キャラ選択ステップでは `_selectedCharKey == null` のとき
          // 「はじめよう」ボタンを非活性化し、明示選択を強制する。
          // 他のステップ（世界観・名前入力）は従来通り。名前入力は `_nextStep()`
          // 側で空欄チェックして SnackBar を出すため、ボタン自体は活性のまま。
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _isCompleting || (_isCharacterStep && _selectedCharKey == null)
                  ? null
                  : (isLastStep ? _complete : _nextStep),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                foregroundColor: Colors.white,
                disabledBackgroundColor: AppTheme.primary.withValues(alpha: 0.35),
                disabledForegroundColor: Colors.white.withValues(alpha: 0.6),
                padding:   const EdgeInsets.symmetric(vertical: 15),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                textStyle: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.bold),
                // BUG-17: Row の非 Flex 子として配置するため minimumSize をオーバーライド。
                // グローバルテーマの Size.fromHeight(48)=Size(infinity,48) が Column 内では
                // 問題ないが、念のため明示的に指定する。
                minimumSize: const Size(double.infinity, 52),
              ),
              child: _isCompleting
                  ? const SizedBox(
                      width:  20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  // 【FEAT-231】サビ口調規約遵守: 「〜よう！」（少年口調 + 感嘆符）→ 紳士的トーンへ
                  : Text(isLastStep ? l10n.authOnboardingStartButtonSabi_message : l10n.authOnboardingNextButton),
            ),
          ),
          // 【FEAT-194】キャラ選択ステップの「スキップ」ボタンは廃止。
          // 「自分のキャラを選ぶ」がオンボーディング体験のコアのため、明示選択を強制する。
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 性別選択カード（FEAT-221 / 性別選択ステップ用）
// ─────────────────────────────────────────────────────────────────────────────

/// 【FEAT-221】キャラ選択カードと同じデザイン感の性別選択カード。
/// 横長の Row レイアウト（アイコン + ラベル）で、選択状態は枠と色で表現する。
class _GenderOption extends StatelessWidget {
  final String       code;
  final String       label;
  final IconData     icon;
  final bool         isSelected;
  final VoidCallback onTap;

  const _GenderOption({
    required this.code,
    required this.label,
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.primary.withValues(alpha: 0.15)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected ? AppTheme.primary : Colors.white12,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              color: isSelected ? AppTheme.primary : Colors.white70,
              size:  22,
            ),
            const SizedBox(width: 14),
            Text(
              label,
              style: TextStyle(
                color:      isSelected ? AppTheme.primary : Colors.white,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                fontSize:   15,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// キャラクターカード（キャラ選択ステップ用）
// ─────────────────────────────────────────────────────────────────────────────

class _CharacterCard extends StatelessWidget {
  final _StarterCharacter character;
  final bool              isSelected;
  final VoidCallback      onTap;

  const _CharacterCard({
    required this.character,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        // 【2026-07-09 hotfix】旧 padding (v:8, h:4) の Row 用スペースから、
        // Column 縦長ヒーロー用の generous padding (v:16, h:12) に変更。
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.primary.withValues(alpha: 0.15)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(18),  // 旧 14 → 18 (大きめカードに合わせ丸み増)
          border: Border.all(
            color: isSelected ? AppTheme.primary : Colors.white12,
            width: isSelected ? 2 : 1,
          ),
          // 選択時に僅かな primary glow (2 択選択の存在感を強調)
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: AppTheme.primary.withValues(alpha: 0.25),
                    blurRadius: 16,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        // 【2026-07-09 hotfix】v1 の 2 キャラ (ソウル / アリア) に合わせて Row → Column 縦長化。
        // 旧 Row (画像 48px 左 + テキスト右) は 8 スターター時代の横長カード想定。
        // 2 択構成では 1 カードあたりの視覚重量が弱く、選択の重みが伝わりにくかった。
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // ヒーロー画像 (48 → 96、2 倍化)。cardAspectRatio 0.85 内で
            // 上端に大きく配置、下に名前・役割スペースを確保。
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: 1,  // 正方形イメージ枠 (dot art の縦横比)
                  child: Image.asset(
                    character.imagePath,
                    fit: BoxFit.contain,
                    // 【FEAT-316】PixelLab 92×92 ドット絵を Nearest Neighbor 補間で
                    // 表示してドット感維持（Linear だとぼやけて世界観破綻）。
                    filterQuality: FilterQuality.none,
                    errorBuilder: (_, __, ___) => Center(
                      child: Text(
                        character.emoji,
                        style: const TextStyle(fontSize: 48),  // 旧 28 → 48
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            // 名前 (旧 13 → 18) と役割 (旧 10 → 13) を拡大、
            // ヒーロー画像下に横並びで階層化。
            Text(
              character.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color:      isSelected ? AppTheme.primary : Colors.white,
                fontWeight: FontWeight.bold,
                fontSize:   18,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              character.role,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white54,  // 旧 white38 → white54 (可読性 UP)
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
