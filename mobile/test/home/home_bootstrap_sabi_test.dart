// 【FEAT-484 (2026-07-08)】HomeBootstrap への sabi_message 統合 契約テスト (2 件)。
//
// 検証観点:
//   1. bootstrap データに sabi_message が注入された場合 (nonce==0)、
//      sabiMessageProvider が bootstrapSabiMessageProvider の値を即時返す
//      (独立 HTTP リクエストを発行しない)。
//   2. nonce > 0 の場合は bootstrapSabiMessageProvider が非 null でも
//      短絡しない (SabiService 経路に進む → テスト環境でネットワーク失敗)。
//
// テスト方針:
//   - Widget rendering 不要 (pure Riverpod unit test)
//   - Backend 接続不要 (ProviderContainer override + ProviderScope テスト)
//   - シナリオ A は short-circuit 前に解決。
//   - シナリオ B は fake SabiService で「独立フェッチ経路の値」を明示的に
//     返し、bootstrap 値ではなくそちらが返ることを確認する (実ネットワーク
//     依存だと `apiClient` が `flutter_secure_storage` platform channel に
//     アクセスして `TestWidgetsFlutterBinding` 未初期化のまま固まるため、
//     「例外 throw」への依存を撤去し決定的な fake に置換した [2026-07-08 検証時修正])。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/features/sabi/models/sabi_message.dart';
import 'package:sabiowl/features/sabi/providers/sabi_provider.dart';
import 'package:sabiowl/features/sabi/services/sabi_service.dart';

// ── ヘルパー ────────────────────────────────────────────────────────────────

SabiMessage _fixedMessage({String msg = 'テストメッセージ'}) {
  return SabiMessage.fromJson({
    'message':    msg,
    'is_rest_day': false,
    'context':    'default',
    'emotion':    'normal',
  });
}

/// シナリオ B 用 fake: 独立フェッチ経路に進んだ場合にのみ呼ばれる。
/// bootstrap 値とは明確に異なるメッセージを返し、短絡しなかったことを検証する。
class _FakeSabiService implements SabiService {
  @override
  Future<SabiMessage> fetchMessage({String? timeSegment, int? nonce}) async {
    return _fixedMessage(msg: '独立フェッチ経路メッセージ (nonce=$nonce)');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ── テスト ────────────────────────────────────────────────────────────────────

void main() {
  group('FEAT-484 HomeBootstrap sabi_message 統合 契約テスト', () {
    // ─────────────────────────────────────────────────────────────────────
    // シナリオ A: nonce==0 + bootstrap 注入済み → bootstrap 値を即返す
    // ─────────────────────────────────────────────────────────────────────
    test('シナリオ A: nonce==0 かつ bootstrap 非 null → Future.value で即解決 (HTTP なし)',
        () async {
      final expected = _fixedMessage(msg: 'Bootstrap経由メッセージ');

      final container = ProviderContainer(
        overrides: [
          bootstrapSabiMessageProvider.overrideWith((ref) => expected),
          sabiRefreshCounterProvider.overrideWith((ref) => 0),
          // sabiServiceProvider は override 不要:
          // 短絡が正常動作なら fetchMessage は呼ばれない。
        ],
      );
      addTearDown(container.dispose);

      final result = await container.read(sabiMessageProvider.future);

      expect(result.message,   expected.message);
      expect(result.isRestDay, isFalse);
      expect(result.context,   'default');
    });

    // ─────────────────────────────────────────────────────────────────────
    // シナリオ B: nonce > 0 → bootstrap 非 null でも SabiService 経路に進む
    //
    // fake SabiService (_FakeSabiService) をオーバーライドし、独立フェッチ
    // 経路に進んだ場合にのみ返る、bootstrap 値とは異なるメッセージを検証する。
    // ─────────────────────────────────────────────────────────────────────
    test('シナリオ B: nonce==1 かつ bootstrap 非 null → 短絡せず SabiService 経路 (fake 値)',
        () async {
      final bootstrapValue = _fixedMessage(msg: 'Bootstrap経由メッセージ');

      final container = ProviderContainer(
        overrides: [
          bootstrapSabiMessageProvider.overrideWith((ref) => bootstrapValue),
          sabiRefreshCounterProvider.overrideWith((ref) => 1),
          sabiServiceProvider.overrideWith((ref) => _FakeSabiService()),
        ],
      );
      addTearDown(container.dispose);

      final result = await container.read(sabiMessageProvider.future);

      // bootstrap 値ではなく、独立フェッチ経路 (fake) の値が返ることを確認。
      expect(result.message, isNot(equals(bootstrapValue.message)));
      expect(result.message, contains('独立フェッチ経路メッセージ'));
      expect(result.message, contains('nonce=1'));
    });
  });
}
