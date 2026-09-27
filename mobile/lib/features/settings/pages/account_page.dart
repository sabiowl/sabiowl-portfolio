import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_sign_in/google_sign_in.dart';  // FEAT-195: アカウント削除時の保険クリーンアップ
import 'package:shared_preferences/shared_preferences.dart';  // FEAT-195: オンボーディング SP クリア
import '../../../core/analytics/posthog_service.dart';  // FEAT-200
import '../../../core/api/api_client.dart';  // 【BUG-128 (2026-06-14)】ゲストトークン明示削除
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/sabi_icon.dart';  // 【FEAT-414 (2026-06-01)】sabi_unified.png 統一
import '../../auth/providers/auth_provider.dart';
import '../providers/settings_provider.dart';

// ── 削除理由マスタ（ラベルは l10n で提供、value は backend に送る固定文字列）
typedef _Reason = ({String value, String Function(AppLocalizations) label});

List<_Reason> _reasonsList(AppLocalizations l10n) => [
  (value: 'too_difficult',    label: (_) => l10n.settingsDeleteReasonToodifficult),
  (value: 'hard_to_continue', label: (_) => l10n.settingsDeleteReasonHardToContinue),
  (value: 'not_my_style',     label: (_) => l10n.settingsDeleteReasonNotMyStyle),
  (value: 'switched_app',     label: (_) => l10n.settingsDeleteReasonSwitchedApp),
  (value: 'bored',            label: (_) => l10n.settingsDeleteReasonBored),
  (value: 'privacy_concern',  label: (_) => l10n.settingsDeleteReasonPrivacyConcern),
  (value: 'other',            label: (_) => l10n.settingsDeleteReasonOther),
];

class AccountPage extends ConsumerStatefulWidget {
  const AccountPage({super.key});

  @override
  ConsumerState<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends ConsumerState<AccountPage> {
  int _step = 1;
  String? _selectedReason;
  final _reasonTextController = TextEditingController();
  bool _deleting = false;

  @override
  void dispose() {
    _reasonTextController.dispose();
    super.dispose();
  }

  void _goToStep2() => setState(() => _step = 2);

  void _goToStep3() {
    if (_selectedReason == null) return;
    setState(() => _step = 3);
  }

  /// アカウント削除の実行。
  ///
  /// ## 🔴 【BUG-157 (2026-09-11)】①と②以降を分けている理由
  ///
  /// 旧実装は 6 つの処理を**1 つの `try/catch`** で包み、
  /// **どこで落ちても同じ汎用文言**を出していた。つまり
  ///
  ///   - ①で落ちた（**アカウントは残っている**）のか
  ///   - ②③で落ちた（**アカウントは既に消えている**）のか
  ///
  /// が、ユーザーにも運営にも区別できなかった。
  ///
  /// 後者の場合、**アカウントは消えているのに「うまくいきませんでした」と
  /// 表示され、画面は削除画面に留まる**。ユーザーは「消えていない」と信じて
  /// もう一度押すが、トークンはもう無効なので今度は①が失敗する ——
  /// **同じ文言のまま、状態だけが変わっている。**
  ///
  /// 🔴 **`context.go(AppRoutes.auth)` を後片付けの失敗で飛ばしてはならない。**
  /// 削除が成功しているのに削除画面に留まるのが、今の一番悪い結果である。
  Future<void> _executeDelete() async {
    if (_deleting) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() => _deleting = true);

    // 🔴 【BUG-162 (2026-09-12)】**サーバ削除を始める前に立てる。**
    //
    // 最初の実装は「削除成功の直後」に立てていたが、**実機では抑止が効かず
    // 再作成のトーストが出た**。サーバ応答を待っているあいだに、
    // それ以前に飛んでいたリクエストの 401 が先に着くためである。
    //
    // ⚠️ 削除が失敗したら [ApiClient.allowGuestSessionRecreation] で戻す。
    // **削除できていないのに抑止を残すと、そのセッションが後で無効になっても
    // BUG-147 の出口が使えないまま詰む。**
    ApiClient.suppressGuestSessionRecreation();

    // ── ① サーバでの削除。**ここで落ちたときだけ「失敗」である** ──────────
    try {
      await ref.read(settingsServiceProvider).deleteAccount(
            reason:     _selectedReason!,
            reasonText: _reasonTextController.text.trim(),
          );
    } catch (e, st) {
      debugPrint('[account_delete] server delete failed: $e\n$st');
      // 🔴 削除できていないので抑止を戻す（上のコメント参照）。
      ApiClient.allowGuestSessionRecreation();
      if (!mounted) return;
      setState(() => _deleting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.settingsAccountDeleteFailedSabi_message),
        ),
      );
      return;
    }

    // ── ②以降は後片付け。失敗しても「削除は完了した」ことは変わらない ──────
    //
    // ⚠️ **黙って捨てないこと。** `debugPrint` を残す ——
    //    ③の `logout()` が落ちるとローカルにトークンが残り、次回起動で
    //    「消えたアカウントのトークン」で 401 になる（BUG-156 の詰みに合流する）。
    //    **ログが無いと追えない。**

    // FEAT-200: アカウント削除完了イベント（identify されているうちに送る）。
    // この後 logout() で reset() が走り識別子はクリアされる。
    try {
      await PosthogService.instance.capture('account_deleted');
    } catch (e) {
      debugPrint('[account_delete] posthog capture failed: $e');
    }

    // FEAT-195: logout() で GoogleSignIn signOut/disconnect が走る（Phase 1）。
    try {
      await ref.read(authProvider.notifier).logout();
    } catch (e) {
      debugPrint('[account_delete] logout failed: $e');
    }

    // FEAT-195: 万一 logout 内の Google クリアが失敗した場合の保険として再実行。
    // 削除済みユーザーで再サインインが起きると `/auth/social/verify/` が
    // 新規ユーザー作成に分岐し UI 応答停止につながるため、冗長でも確実性を優先。
    try {
      await GoogleSignIn().signOut();
      await GoogleSignIn().disconnect();
    } catch (_) {/* 既にクリア済み等は無視 */}

    // 【BUG-128 (2026-06-14)】ゲストモードでアカウント削除した場合、logout() は
    // ユーザートークンしか削除しないためゲストトークンが残留する。明示的に削除
    // して次回起動時に死んだゲストトークンで API を叩くのを防ぐ。
    try {
      await ref.read(apiClientProvider).deleteGuestToken();
    } catch (e) {
      debugPrint('[account_delete] deleteGuestToken failed: $e');
    }

    // 🔴 【BUG-162 (2026-09-12)】secure storage 側のローカル状態を消す。
    //
    // 下の `_clearOnboardingLocalData()` は `has_seen_tutorial` と `guest_mode`
    // を **`SharedPreferences` から**消していたが、**当時このキーは
    // secure storage にあった**ので**何も消えていなかった**。
    //
    // 🔵 【FEAT-542 (2026-09-23)】4 キーは `SharedPreferences` へ移設し、
    // `has_seen_tutorial` は `profile_setup_completed_for` に置き換わった。
    // ⚠️ それでも**消す役目はこのメソッドに集約したまま**にしている ——
    // 保存先が 2 つに分かれると、また片方だけ消す事故が起きる。
    //
    // 🔵 どちらも `app_router._performAuthCheck` が起動時の行き先を決めるのに
    // 読むキーである。消え残ると、アカウントを消したのに「前の続き」として
    // 扱われる。
    try {
      await ref.read(apiClientProvider).clearLocalStateForAccountDeletion();
    } catch (e) {
      debugPrint('[account_delete] clearLocalState failed: $e');
    }

    // FEAT-195: アカウント削除はユーザーの「完全にやり直したい」意思表示なので、
    // オンボーディング関連のローカル状態も全削除して完全クリーンスタートにする。
    await _clearOnboardingLocalData();

    // 🔴 ここには**必ず到達する**。
    if (mounted) context.go(AppRoutes.auth);
  }

  /// FEAT-195: アカウント削除時にオンボーディング系の SharedPreferences を一括削除。
  ///
  /// 🔴 【BUG-162 (2026-09-12)】`has_seen_tutorial` と `guest_mode` をここから
  /// 外した。**当時このキーは secure storage にあった**ので、
  /// `prefs.remove` では**何も消えていなかった** ——
  /// 下の宣言（「完全クリーンスタート」）が起きていなかった。
  /// 消すのは `ApiClient.clearLocalStateForAccountDeletion()` の役目である。
  ///
  /// 🔵 【FEAT-542 (2026-09-23)】あの 4 キーは `SharedPreferences` へ移したが、
  /// **役割分担は変えていない** —— 起動時の行き先を決めるキーは
  /// `ApiClient` が消し、ここはオンボーディングの入力値だけを消す。
  /// ⚠️ 保存先で分けるのではなく、**意味で分けている**。
  ///
  /// ⚠️ **ここに残っている 4 キーはオンボーディングの入力値である**
  /// (`onboarding_service.dart` の 3 つ + 廃止済みの `guest_habits`)。
  ///
  /// ログアウト時はこれを呼ばない（一時的にアプリを離れる経路のため、再ログイン時に
  /// オンボーディングフローを再度通らないよう設定済みフラグ等を残す）。
  Future<void> _clearOnboardingLocalData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('onboarding_player_name');
      await prefs.remove('onboarding_character_key');
      await prefs.remove('first_todo_completed');
      // 【FEAT-221】launch_count / second_launch_shown は「特別なお知らせ」シート
      // 完全廃止（2026-05-15）に伴い key 自体が廃止されたため remove 行も削除。
      // FEAT-180 / FEAT-188 で廃止済みキーの残骸を念のため削除
      await prefs.remove('guest_habits');
    } catch (e, st) {
      debugPrint('clear onboarding SP failed: $e\n$st');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: AppTheme.surface,
      appBar: AppBar(
        backgroundColor: AppTheme.surface,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => context.pop(),
        ),
        title: Text(l10n.settingsAccountDeletePageTitle),
      ),
      body: _deleting
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(l10n.settingsAccountDeleteDeleting,
                      style: const TextStyle(color: Colors.white54)),
                ],
              ),
            )
          : switch (_step) {
              2 => _Step2(
                  selectedReason: _selectedReason,
                  reasonTextController: _reasonTextController,
                  onSelectReason: (v) => setState(() => _selectedReason = v),
                  onNext: _goToStep3,
                  onCancel: () => context.pop(),
                ),
              3 => _Step3(
                  onDelete: _executeDelete,
                  onCancel: () => context.pop(),
                ),
              _ => _Step1(
                  onNext: _goToStep2,
                  onCancel: () => context.pop(),
                ),
            },
    );
  }
}

// ── Step 1: 注意事項 ──────────────────────────────────────────
class _Step1 extends StatelessWidget {
  const _Step1({required this.onNext, required this.onCancel});

  final VoidCallback onNext;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final deletedItems = [
      ('🗓️', l10n.settingsDeleteItem1Habits),
      ('⭐', l10n.settingsDeleteItem2Exp),
      ('🎴', l10n.settingsDeleteItem3Characters),
      ('💎', l10n.settingsDeleteItem4Diamonds),
      ('👥', l10n.settingsDeleteItem5Friends),
    ];

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Sabi メッセージ ──────────────────────────────
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppTheme.card,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 【FEAT-414 (2026-06-01)】絵文字 🪶 → sabi_unified.png に統一。
                  // SabiEmotion.pity (寄り添い) = 別れの場でも穏やかに見守るサビの表情。
                  // 既存 SabiIcon widget 再利用で onboarding/auth と同パターン。
                  const SabiIcon(emotion: SabiEmotion.pity, size: 32),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      l10n.settingsDeleteStep1SabiMessage,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.75),
                        fontSize: 14,
                        height: 1.6,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // ── 削除されるデータ一覧 ─────────────────────────
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppTheme.card,
                borderRadius: BorderRadius.circular(14),
                border:
                    Border.all(color: AppTheme.danger.withValues(alpha: 0.25)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.settingsDeleteStep1DataTitle,
                    style: TextStyle(
                      color: AppTheme.danger.withValues(alpha: 0.85),
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 12),
                  for (final (emoji, text) in deletedItems) ...[
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          Text(emoji,
                              style: const TextStyle(fontSize: 16)),
                          const SizedBox(width: 10),
                          Text(
                            text,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.65),
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),

            const Spacer(),

            // ── ボタン ───────────────────────────────────────
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: onNext,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.danger,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(l10n.settingsDeleteStep1NextButton,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: onCancel,
                child: Text(l10n.settingsDeleteCancelButton,
                    style: const TextStyle(color: Colors.grey)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Step 2: 理由入力 ──────────────────────────────────────────
class _Step2 extends StatelessWidget {
  const _Step2({
    required this.selectedReason,
    required this.reasonTextController,
    required this.onSelectReason,
    required this.onNext,
    required this.onCancel,
  });

  final String? selectedReason;
  final TextEditingController reasonTextController;
  final ValueChanged<String?> onSelectReason;
  final VoidCallback onNext;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final reasons = _reasonsList(l10n);
    final canNext = selectedReason != null;

    return SafeArea(
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              children: [
                Text(
                  l10n.settingsDeleteStep2Question,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.8),
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.settingsDeleteStep2Subtitle,
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.4),
                      fontSize: 12),
                ),
                const SizedBox(height: 20),

                // ── 理由ラジオ ────────────────────────────────
                Container(
                  decoration: BoxDecoration(
                    color: AppTheme.card,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    children: [
                      for (final r in reasons)
                        RadioListTile<String>(
                          value: r.value,
                          groupValue: selectedReason,
                          onChanged: onSelectReason,
                          activeColor: AppTheme.primary,
                          title: Text(
                            r.label(l10n),
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 14),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // ── 自由記述 ──────────────────────────────────
                Text(
                  l10n.settingsDeleteStep2FreeTextLabel,
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                      fontSize: 12),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: reasonTextController,
                  maxLines: 4,
                  maxLength: 200,
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: l10n.settingsDeleteStep2FreeTextHint,
                    hintStyle: TextStyle(
                        color: Colors.white.withValues(alpha: 0.25),
                        fontSize: 13),
                    filled: true,
                    fillColor: AppTheme.card,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    counterStyle: TextStyle(
                        color: Colors.white.withValues(alpha: 0.3),
                        fontSize: 11),
                  ),
                ),
              ],
            ),
          ),

          // ── 固定ボタンエリア ──────────────────────────────────
          Padding(
            padding: EdgeInsets.fromLTRB(
                20, 8, 20, 20 + MediaQuery.of(context).padding.bottom),
            child: Column(
              children: [
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: canNext ? onNext : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor:
                          canNext ? AppTheme.danger : Colors.grey.shade800,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text(l10n.settingsDeleteStep2NextButton,
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: onCancel,
                  child: Text(l10n.settingsDeleteCancelButton,
                      style: const TextStyle(color: Colors.grey)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Step 3: 最終確認（カウントダウンガード） ───────────────────
class _Step3 extends StatefulWidget {
  const _Step3({required this.onDelete, required this.onCancel});

  final VoidCallback onDelete;
  final VoidCallback onCancel;

  @override
  State<_Step3> createState() => _Step3State();
}

class _Step3State extends State<_Step3> {
  int _countdown = 5;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_countdown <= 1) {
        t.cancel();
        setState(() => _countdown = 0);
      } else {
        setState(() => _countdown--);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  bool get _canDelete => _countdown == 0;

  String _buttonLabel(AppLocalizations l10n) => _canDelete
      ? l10n.settingsDeleteStep3ButtonDelete
      : l10n.settingsDeleteStep3ButtonCountdown(_countdown);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
        child: Column(
          children: [
            // ── Sabi ─────────────────────────────────────────
            // 【FEAT-414 (2026-06-01)】絵文字 🪶 → sabi_unified.png に統一。
            // SabiEmotion.sad (別れの共感) = 「さみしいけど見送る」感情を意味的に明示。
            // 表示画像は FEAT-316 で全感情統一 (sabi_unified.png) のため pity と同じ
            // 画像が表示されるが、emotion メタ情報で意図を記録 (v1.1+ 感情別画像復活時の自動切替対応)。
            const SabiIcon(emotion: SabiEmotion.sad, size: 64),
            const SizedBox(height: 16),
            Text(
              l10n.settingsDeleteStep3Title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              l10n.settingsDeleteStep3SabiMessage,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.55),
                fontSize: 14,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 24),

            // ── 最終警告テキスト ──────────────────────────────
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppTheme.danger.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
                border:
                    Border.all(color: AppTheme.danger.withValues(alpha: 0.3)),
              ),
              child: Text(
                l10n.settingsDeleteStep3Warning,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppTheme.danger,
                  fontSize: 13,
                  height: 1.6,
                ),
              ),
            ),

            const Spacer(),

            // ── カウントダウン表示 ────────────────────────────
            if (!_canDelete) ...[
              Text(
                l10n.settingsDeleteStep3CountdownText(_countdown),
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.35),
                    fontSize: 12),
              ),
              const SizedBox(height: 10),
            ],

            // ── 削除ボタン ────────────────────────────────────
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _canDelete ? widget.onDelete : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      _canDelete ? AppTheme.danger : Colors.grey.shade800,
                  foregroundColor: Colors.white,
                  disabledForegroundColor: Colors.white54,
                  disabledBackgroundColor: Colors.grey.shade800,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(_buttonLabel(l10n),
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: widget.onCancel,
                child: Text(l10n.settingsDeleteCancelFinal,
                    style: const TextStyle(color: Colors.grey)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
