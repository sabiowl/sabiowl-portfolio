import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../constants/app_urls.dart';
import '../constants/preferences_keys.dart';
import '../providers/app_update_provider.dart';
import '../services/app_update_service.dart';
import '../theme/app_theme.dart';
import '../../l10n/app_localizations.dart';

/// 【FEAT-543 (2026-09-23)】バージョンアップ告知の全画面 overlay。
///
/// ## 優先順位
///
/// ```
/// 停止 > メンテ > 🆕 更新告知 > レート制限 > 通信エラー > 通常 UI
/// ```
///
/// 🔵 **メンテより下**なのは、メンテ中は更新しても直らないから。
/// 🔵 **通信エラーより上**なのは、**古い版が API 契約に合わなくて
/// 通信に失敗している場合がある**から。そこで「通信できませんでした」を
/// 見せても、ユーザーには打つ手が無い。
///
/// ## 文面の出どころが 2 つある
///
/// | 種別 | 文面 | 空のとき |
/// |---|---|---|
/// | 推奨更新 | **admin の入力値**（DB） | 空のまま出る（閉じられるので詰まない） |
/// | 🔴 必須更新 | **admin の入力値**（DB、FEAT-544） | **ARB の固定文へ落とす** |
///
/// 🔴 **1 組の文面を両方に使ってはいけない。** しきい値 2 本を同時に使うと
/// ユーザーが 3 群に分かれ、**どちらかに必ず嘘が出る**。
/// 「更新しないとご利用いただけません」と書けば**まだ使える群**にも出るし、
/// 「お急ぎでなくとも構いません」と書けば**閉じられない群**に出る。
///
/// 🔵 【FEAT-544 (2026-09-23)】必須更新の文面も admin から編集できるように
/// なった。FEAT-543 はアプリに固定していたが、**admin に無い機能は忘れられる**
/// （ユーザー指摘）。**入力欄はそれ自体が運用の説明書である。**
/// ⚠️ ARB の固定文は**消していない** —— Backend が未デプロイ / 通信できない /
/// admin が誤って空にした、の 3 通りで**閉じられない画面が無文面になる**のを防ぐ。
class AppUpdateOverlay extends ConsumerWidget {
  const AppUpdateOverlay({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // ⚠️ 未解決 / エラーは `none` に倒す。**出さない側が安全側**である。
    final kind =
        ref.watch(appUpdateDecisionProvider).valueOrNull ?? AppUpdateKind.none;
    return Stack(
      children: [
        child,
        if (kind != AppUpdateKind.none)
          Positioned.fill(child: _AppUpdateScreen(kind: kind)),
      ],
    );
  }
}

class _AppUpdateScreen extends ConsumerStatefulWidget {
  const _AppUpdateScreen({required this.kind});
  final AppUpdateKind kind;

  @override
  ConsumerState<_AppUpdateScreen> createState() => _AppUpdateScreenState();
}

class _AppUpdateScreenState extends ConsumerState<_AppUpdateScreen> {
  /// 🔴 【BUG-165 (2026-09-12)】告知は**この画面の中**に出す。
  ///
  /// ⚠️ **SnackBar は使えない。** この overlay の根は**不透明な `Material`**
  /// で、`ScaffoldMessenger` の SnackBar は**route 側の `Scaffold` の中**に
  /// 描かれる —— つまり**この画面の下に隠れて見えない**。
  /// 実機で「押したのに何も出ない」と報告されたのがこれである。
  String? _notice;

  bool _opening = false;

  bool get _isMandatory => widget.kind == AppUpdateKind.mandatory;

  /// App Store を開く。**deep link → web の 2 段**で試す。
  ///
  /// ⚠️ `canLaunchUrl` の pre-check は使わない。iOS の
  /// `LSApplicationQueriesSchemes` 未登録で false を返す環境が実在し、
  /// **ボタンが silent に無反応**になる（FEAT-463 で踏んだ形）。
  Future<void> _openStore() async {
    if (_opening) return;
    setState(() {
      _opening = true;
      _notice = null;
    });
    final l10n = AppLocalizations.of(context)!;

    final opened = await _tryLaunch(Uri.parse(kAppStoreDeepLinkUrl)) ||
        await _tryLaunch(Uri.parse(kAppStoreWebUrl));

    if (!mounted) return;
    setState(() {
      _opening = false;
      // 🔴 開けなかったことを**この画面の中で**伝える。
      //    ここが無いと「押しても何も起きない」で終わる。
      _notice = opened ? null : l10n.coreAppUpdateOpenFailedMessage;
    });
  }

  Future<bool> _tryLaunch(Uri uri) async {
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  /// 「後で」。**推奨更新にしか無い。**
  Future<void> _onLater() async {
    final version = ref.read(appUpdateStatusProvider).latestVersion;
    await markAppUpdateNoticeDismissed(version);
    if (!mounted) return;
    // 抑制の判定をやり直させる → `none` になって overlay が閉じる。
    ref.invalidate(appUpdateDecisionProvider);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final config = ref.watch(appUpdateStatusProvider);

    // 🔴 【FEAT-544 (2026-09-23)】必須更新の文面は **admin の入力値が優先**。
    //
    // ⚠️ **空のときは ARB の固定文へ落とす。** 空になるのは
    //   ①Backend が未デプロイ ②通信できない ③admin が誤って空にした
    // の 3 通りで、いずれも**閉じられない画面が無文面になる**。
    //
    // 🔴 **ARB の固定文を消さないこと。** 消すと上の 3 通りで
    // 「何をすればよいか分からない、閉じられない画面」が出る。
    //
    // 🔵 推奨更新は従来どおり admin の入力値だけ。あちらは「後で」で
    //    閉じられるので、空でも詰まない。
    final title = _isMandatory
        ? (config.mandatoryTitle.isNotEmpty
            ? config.mandatoryTitle
            : l10n.coreAppUpdateRequiredTitle)
        : config.title;
    final body = _isMandatory
        ? (config.mandatoryBody.isNotEmpty
            ? config.mandatoryBody
            : l10n.coreAppUpdateRequiredBody)
        : config.body;

    return PopScope(
      // 🔴 必須更新は戻るジェスチャでも抜けさせない。
      canPop: !_isMandatory,
      child: Material(
        color: AppTheme.background,
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _isMandatory
                        ? Icons.system_update_alt
                        : Icons.upgrade_outlined,
                    size: 64,
                    color: Colors.white54,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    title,
                    key: const Key('app_update_title'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    body,
                    key: const Key('app_update_body'),
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 14,
                      height: 1.6,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 40),
                  ElevatedButton(
                    key: const Key('app_update_open_store'),
                    onPressed: _opening ? null : _openStore,
                    child: _opening
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(l10n.coreAppUpdateOpenStoreButton),
                  ),
                  // 🔴 【BUG-165】開けなかった通知はここに出す。
                  if (_notice != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(
                        _notice!,
                        key: const Key('app_update_notice'),
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          height: 1.5,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  // 🔴 「後で」は推奨更新にしか出さない。
                  //    必須更新に出すと、使わせてはいけない版のまま続けられる。
                  if (!_isMandatory) ...[
                    const SizedBox(height: 12),
                    TextButton(
                      key: const Key('app_update_later'),
                      onPressed: _onLater,
                      child: Text(
                        l10n.coreAppUpdateLaterButton,
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
