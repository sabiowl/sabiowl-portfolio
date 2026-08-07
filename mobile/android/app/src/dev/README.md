# src/dev/ — dev flavor 用 sourceset

【Phase D-Android (2026-07-06)】このディレクトリは `flutter build apk --flavor dev` 時
のみ merge される Android sourceset。

## 配置すべきファイル (User 手動配置)

- `google-services.json` — dev Firebase project (Android app `com.sabiowl.app.dev`) 用
  設定ファイル。**Firebase Console → dev project → プロジェクト設定 → General →
  Android アプリ → 設定ファイルをダウンロード** で取得。

## 未配置時の挙動

`google-services.json` が本ディレクトリに存在しない状態で `--flavor dev` build を
実行すると、`com.google.gms.google-services` Gradle plugin が以下エラーで build 失敗:

```
File google-services.json is missing. The Google Services Plugin cannot function without it.
```

このエラーが出たら本ディレクトリに dev 用 `google-services.json` を配置すれば解消する。

## 手順詳細

`doc/instructions/PHASE_D_ANDROID_SETUP.md` §2 を参照。
