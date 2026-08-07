# src/prod/ — prod flavor 用 sourceset

【Phase D-Android (2026-07-06)】このディレクトリは `flutter build apk --flavor prod`
時のみ merge される Android sourceset。

## 配置経路 (2 パターン)

### パターン A (現状、推奨): app 直下 fallback を使う

`mobile/android/app/google-services.json` に prod 用ファイルが配置済み (従来と同じ)。
`src/prod/google-services.json` は不要。Gradle が fallback で app 直下を読む。

- 利点: 従来の deployment 経路 (App Store / Play Store 提出) と同じ file layout
- 欠点: prod 明示化されないが、Phase D-Android 段階では影響なし

### パターン B: src/prod/ に prod 用 google-services.json を明示配置

`mobile/android/app/google-services.json` を削除 (or dev/prod どちらでもない場合の
fallback として残置) し、`src/prod/google-services.json` を配置する。

- 利点: prod / dev の分離が sourceset レベルで完全対称
- 欠点: 移動作業が発生、CI/codemagic 側の設定変更も必要になる可能性

**現状は パターン A を採用** (Phase D-Android スコープを最小化)。
将来 Phase D-iOS 完了後、CI 設定と合わせて パターン B に移行検討。
