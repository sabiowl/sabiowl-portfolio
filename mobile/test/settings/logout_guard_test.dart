// 【BUG-154 (2026-09-11)】通信できないときでもログアウトできること。
//
// ## 何が起きていたか
//
// `_confirmLogout` は `/auth/social/accounts/` の取得に失敗すると
// **SnackBar を出して return** していた —— **確認ダイアログすら開かない**。
// ログアウト処理そのものは通信を捨てる前提で書かれているのに、
// **入口の事前チェックだけが閉じていた** (fail closed)。
//
// 🔴 結果として**アプリが壊れて逃げ出したいユーザーほど逃げられない**という、
// ガードの目的と真逆の状態になっていた。
//
// ## 🔴 1 と 2 は対で書く
//
// 1 だけだと「**事前チェックを丸ごと消す**」実装で緑になり、
// **未連携ユーザーがデータを失う**方向の退行を検出できない。
// **ガードを消すのではなく、判定材料をローカルに切り替えるのが本修正**である。

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sabiowl/features/settings/logout_guard.dart';
import 'package:sabiowl/features/settings/services/settings_service.dart';

LinkedAccounts _accounts({required bool linked}) => LinkedAccounts(
      google: LinkedAccountInfo(
        isLinked: linked,
        email: linked ? 'someone@example.com' : null,
      ),
      apple: const LinkedAccountInfo(isLinked: false, email: null),
    );

void main() {
  group('サーバに聞けたとき（従来どおり）', () {
    test('連携あり → 止めない', () async {
      final blocked = await shouldBlockLogoutAsUnlinked(
        fetchLinkedAccounts: () async => _accounts(linked: true),
        isGuestMode: () async => fail('サーバに聞けたなら fallback は使わない'),
      );
      expect(blocked, isFalse);
    });

    test('連携なし → 止める（未連携警告）', () async {
      final blocked = await shouldBlockLogoutAsUnlinked(
        fetchLinkedAccounts: () async => _accounts(linked: false),
        isGuestMode: () async => fail('サーバに聞けたなら fallback は使わない'),
      );
      expect(blocked, isTrue);
    });
  });

  group('🔴 サーバに聞けないとき（本 BUG）', () {
    test('取得失敗 + guest_mode なし → 止めない（ログアウトできる）', () async {
      final blocked = await shouldBlockLogoutAsUnlinked(
        fetchLinkedAccounts: () async => throw Exception('offline'),
        isGuestMode: () async => false,
      );
      expect(
        blocked, isFalse,
        reason: '連携済みユーザーは通信できなくてもログアウトできなければならない。'
            'ここで止めると「壊れて逃げ出したいユーザーほど逃げられない」',
      );
    });

    test('🔴 取得失敗 + guest_mode あり → 止める（ガードは生きている）', () async {
      final blocked = await shouldBlockLogoutAsUnlinked(
        fetchLinkedAccounts: () async => throw Exception('offline'),
        isGuestMode: () async => true,
      );
      expect(
        blocked, isTrue,
        reason: '「失敗したら通す」実装だと未連携ユーザーがデータを失う。'
            'ガードを消すのではなく、判定材料をローカルに切り替えるのが本修正',
      );
    });
  });

  group('タイムアウト', () {
    test('既定は 5 秒（Dio の 60 秒を待たない）', () {
      // ⚠️ Dio の既定は connect / receive とも **60 秒** (Render の
      //    コールドスタート対応で意図的に長い)。サーバが遅いだけの場合、
      //    **押しても 1 分間なにも起きない**。
      expect(kLogoutLinkCheckTimeout, const Duration(seconds: 5));
    });

    test('🔴 応答が返らないときタイムアウトしてローカル判定に落ちる', () async {
      var fellBack = false;
      final blocked = await shouldBlockLogoutAsUnlinked(
        // 永久に返らない future
        fetchLinkedAccounts: () => Completer<LinkedAccounts>().future,
        isGuestMode: () async {
          fellBack = true;
          return false;
        },
        timeout: const Duration(milliseconds: 50),
      );
      expect(fellBack, isTrue, reason: 'タイムアウト後にローカル判定へ落ちること');
      expect(blocked, isFalse);
    });
  });

  group('⚠️ 前提の固定', () {
    test('🔴 呼び出し側が isGuestMode を fallback として渡している', () {
      // §2-1 の前提:「非ゲスト ⇒ 連携済み」。
      // `guest_mode` は正式登録の完了時に `setGuestMode(false)` で削除され、
      // FEAT-178 で Magic Link が撤去された結果、
      // **非ゲストになる経路はソーシャル連携だけ**である。
      //
      // 🔴 この前提が将来崩れると、未連携ユーザーがデータを失う経路になる。
      //    引数が黙って外されていないことを走査で縛る。
      final source = File(
        'lib/features/settings/pages/settings_page.dart',
      ).readAsStringSync();
      final at = source.indexOf('shouldBlockLogoutAsUnlinked(');
      expect(at, greaterThan(0), reason: 'ログアウトのガードが呼ばれていない');
      final call = source.substring(at, source.indexOf(');', at));
      expect(
        call.contains('isGuestMode'), isTrue,
        reason: 'fallback が isGuestMode でなくなっている。'
            '§2-1 の前提を再確認すること',
      );
    });

    test('🔴 事前チェックの失敗で return していない（fail closed に戻していない）', () {
      final source = File(
        'lib/features/settings/pages/settings_page.dart',
      ).readAsStringSync();
      final at = source.indexOf('Future<void> _confirmLogout(');
      final body = source.substring(at, source.indexOf('\n  Future<', at + 10));
      expect(
        body.contains('settingsLogoutCheckErrorSnackbarSabi_message'), isFalse,
        reason: '取得失敗時に SnackBar を出して return する旧実装に戻っている',
      );
    });
  });
}
