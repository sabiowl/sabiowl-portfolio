import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// 【BUG-151 (2026-09-02)】アプリのバージョン文字列（例: `1.1.1`）。
///
/// 🔴 **`pubspec.yaml` の `version:` が唯一の真実値である。**
/// バージョンを画面に出すときは必ず本 provider を経由し、
/// **リテラルで書かないこと。**
///
/// ## なぜ provider にしたか
///
/// 発見時、アプリ内にバージョン表示が 2 箇所あり、**片方だけが本物を読んでいた**:
///
/// | 場所 | 実装 | 表示 |
/// |---|---|---|
/// | ホームのドロワー | `PackageInfo.fromPlatform()` (FEAT-464) | `1.1.1` ✅ |
/// | 設定 → アプリ情報 | `Text('1.0.0')` の**リテラル** | `1.0.0` ❌ |
///
/// v1.0 → v1.1.0 → v1.1.1 のあいだ「片方だけ正しい」状態が続いていた。
/// 2 画面を並べて見る機会が無いので、誰も気付けなかった。
///
/// `pubspec.yaml` の値は**ビルドに必須**なのでリリースのたび必ず上がる。
/// つまり **`PackageInfo` から読むかぎり「更新を忘れる」余地は無い**。
/// 忘れが起きるのは**リテラルで持っているときだけ**である。
///
/// ## 集約するのは「値」であって「見た目」ではない
///
/// ドロワーは `バージョン 1.1.1`、設定は `1.1.1` + 外部リンクアイコンで
/// **描画が違う**。共通 widget にすると片方に無理が出るので、
/// **取得だけを共有し、描画は各画面に任せる**。
///
/// ## キャッシュ
///
/// `FutureProvider` は解決済みの値を保持するので、`PackageInfo.fromPlatform()`
/// はアプリ起動後 1 回しか走らない。
/// FEAT-464 Pre-mortem #3 が `initState` で手動キャッシュしていた
/// 「Drawer 開閉のたびに再取得すると体感遅延が出る」問題は、本 provider に
/// 寄せることで自動的に満たされる。
///
/// 🔵 再発防止は `test/core/app_version_no_literal_test.dart` が走査で縛る。
final appVersionProvider = FutureProvider<String>((ref) async {
  final info = await PackageInfo.fromPlatform();
  return info.version;
});
