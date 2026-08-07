// 【公開スナップショット用のスタブ】
//
// 本番リポジトリの `firebase_options.dart` は、`--dart-define=FLAVOR=dev` に応じて
// `firebase_options_dev.dart` / `firebase_options_prod.dart` へ委譲する薄い分岐層です。
// 委譲先には Firebase の Web API キーが含まれるため、公開リポジトリからは除外して
// います（Google の設計上これらは「秘密」ではなく識別子ですが、公開する積極的な
// 理由もないため）。
//
// このファイルは、除外によって `NotificationService` の import が解決できなくなり
// `flutter analyze` / `flutter test` が通らなくなるのを防ぐためのスタブです。
// **公開版のシグネチャは本物と同一**で、値だけがプレースホルダになっています。
//
// 実際に動かすには FlutterFire CLI で生成してください:
//
//     dart pub global activate flutterfire_cli
//     flutterfire configure
//
// ignore_for_file: type=lint
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;

/// Default [FirebaseOptions] — 本番では flavor に応じて dev / prod を切り替える。
///
/// 本番実装では `String.fromEnvironment('FLAVOR', defaultValue: 'prod')` を
/// compile-time に評価し、tree-shaking で分岐が消滅します（実行時オーバーヘッド 0）。
/// default を prod にしてあるのは、`--dart-define` の指定漏れで dev 経路が
/// 本番機に混入するのを防ぐためです。
class DefaultFirebaseOptions {
  // ignore: do_not_use_environment
  static const String _flavor =
      String.fromEnvironment('FLAVOR', defaultValue: 'prod');

  /// 現行 platform + 現行 flavor の [FirebaseOptions] を返す。
  ///
  /// スタブでは実際の値を持たないため、呼び出されたら明示的に落とします。
  /// 黙ってダミー値を返すと「Firebase に繋がらない」原因の特定が遅れるためです。
  static FirebaseOptions get currentPlatform {
    throw UnsupportedError(
      'これは公開スナップショット用のスタブです。'
      '`flutterfire configure` で firebase_options.dart を生成してください。',
    );
  }

  /// 現在の flavor 名 (デバッグログ用)。
  static String get flavor => _flavor;
}
