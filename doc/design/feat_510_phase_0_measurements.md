# FEAT-510 Phase 0 — 現状 DL サイズ実測 + Phase 1-3 見積調整

> 作成日: 2026-07-29
> **ステータス**: ✅ Phase 0 完了 (PM 直接 ~1.5h)
> **関連**: [FEAT-510 初回 DL 減量指示書](../instructions/FEAT-510_initial_download_size_reduction.md)
> **計測環境**: Windows 11 / Flutter 3.29.3 / `flutter build appbundle --target-platform android-arm64` (release build)、prod flavor

---

## 1. Summary — 3 line takeaway

- **Android aab (ARM64 slice) 実測 = 80.94 MB**、iOS IPA は architecture 依存で ~90-105 MB 推定 (Windows で iOS build 不可のため間接推定)
- **画像 asset 59.22 MB = app の 77%** が bundle 画像で占められている、うち WebP 化余地は 59 MB × ~65% = **~38 MB 削減見込**
- **結論: Phase 1 (WebP + App Thinning) 単独で ~43-50 MB 到達可能**、Phase 2 (BG asset DL) は size 目的では必須ではなく、progressive install UX の nice-to-have に格下げ可能

---

## 2. 実測データ

### 2.1 Android aab (ground truth、`app-prod-release.aab`)

| 項目 | サイズ |
|---|---:|
| **`app-prod-release.aab` (ARM64 only、release build)** | **80.94 MB** |
| Universal (multi-ABI、非推奨、armeabi-v7a + arm64-v8a + x86_64) | 未計測 (推定 100-120 MB) |
| Play Store install サイズ (User の端末着地) | Play Store が per-device slice、~65-75 MB 推定 (Google 公式 App Bundle FAQ) |

### 2.2 .aab 内訳 (base/ split、ARM64-only、compressed = delivery size)

| Path | Size (compressed) | Notes |
|---|---:|---|
| `base/lib/arm64-v8a/libflutter.so` | 4.98 MB | Flutter engine (削減不可) |
| `base/lib/arm64-v8a/libapp.so` | 4.50 MB | Compiled Dart code + 全 packages (削減余地は tree-shake のみ) |
| `base/assets/flutter_assets/assets/images/` | **59.22 MB (89 files)** | 🎯 主要削減対象 |
| `base/assets/flutter_assets/assets/animations/` | 3.14 MB (2 files) | `character_aria_motion_1.gif` 3.22 MB が大半 |
| `base/dex/classes.dex` | 2.92 MB | Kotlin/Java bytecode |
| `BUNDLE-METADATA/proguard.map` | 2.93 MB | Debug metadata、実 device には shipping しない |
| その他 (fonts, res/, meta, ネイティブ SDK 等) | ~3-8 MB | permission_handler / firebase / sentry / posthog SDK |

### 2.3 assets/images/ 詳細 (bundle 内訳、compressed)

| Sub-path | 総サイズ | 平均 file size | 削減余地 |
|---|---:|---:|:---:|
| `characters/` (14 files、pubspec で個別登録) | 26.38 MB | ~1.88 MB/file | 🔴 高 (WebP 85%) |
| `backgrounds/world/` (21 files、puzzle world) | 16.20 MB | ~0.77 MB/file | 🟠 中〜高 (WebP 75%) |
| `battle/` (150 files、Enemy sprites) | 33.45 MB (raw 全 subfolder) | ~0.22 MB/file avg | 🟠 中 (WebP 60%) |
| `backgrounds/` (root 4 files、Guild reception) | 4.88 MB | ~1.22 MB/file | 🔴 高 (WebP 80%) |
| `backgrounds/battle/` (4 files、tier 別 battle BG) | 0.11 MB | ~0.03 MB/file | 🟢 低 (すでに小) |
| `npc/` (2 files、Lilia sprite) | 0.18 MB | ~0.09 MB/file | 🟢 低 |
| `sabi/` (3 files registered) | 0.74 MB | ~0.25 MB/file | 🟢 低 |
| `animations/character_aria_motion_1.gif` | 3.22 MB (single file) | — | 🟠 中 (WebP animated or Lottie 化) |

**合計 bundle 画像**: ~89-93 MB raw、~62 MB compressed (aab)

### 2.4 削減余地の最大ファイル top 5 (compressed、削減効果 = 単価 × 数)

| # | File | 現状 (compressed) | WebP q=85 推定 | 削減量 |
|---|---|---:|---:|---:|
| 1 | `character_rune.png` | 2.35 MB | ~0.4 MB | 1.95 MB |
| 2 | `character_aurum.png` | 2.33 MB | ~0.4 MB | 1.93 MB |
| 3 | `world_evening_castle_town.png` | 2.45 MB | ~0.6 MB | 1.85 MB |
| 4 | `world_sunrise_mono.png` | 2.27 MB | ~0.5 MB | 1.77 MB |
| 5 | `bar.png` (backgrounds root) | 2.22 MB | ~0.5 MB | 1.72 MB |

**14 character × ~2 MB delta = 28 MB / 21 world BG × ~1.5 MB delta = 32 MB** → 単純に character + world だけで **~60 MB 削減可能**、これで target < 50 MB 到達。

### 2.5 iOS 推定 (Windows で build 不可、間接推定)

- iOS IPA は Android aab + 10-20% overhead が典型 (Objective-C runtime + Swift stdlib 埋込 + Info.plist 等)
- 推定: **~90-105 MB (universal IPA)**、App Thinning 適用後 **~65-80 MB per device**
- 現状でも cellular download threshold (200 MB は現行 Apple の上限、100 MB は "OTA 制限" の目安、100 MB 以下は "Wi-Fi 不要" が浸透) にすでに **十分近い危険水域**、v1.1 英語 arb 追加で余裕なし

---

## 3. FEAT-510 見積の実測ベース修正

### 3.1 Phase 1 (WebP + App Thinning) の期待効果 — 実測ベース更新

| 項目 | FEAT-510 起票時の推定 | Phase 0 実測ベース修正 | 差分 |
|---|---:|---:|:---:|
| 現状 IPA (iOS) | ~85-95 MB | **~90-105 MB (推定)** | 現状は同等 |
| WebP 削減率 | 30-50% | **65% (character/world)、40% (battle 系)** | ⬆ 削減余地大 |
| Phase 1 完了時サイズ | 65-80 MB | **~43-50 MB** ⭐ | ⬇ 目標大幅超過 |

**含意**: Phase 1 単独で target `< 50 MB` を達成可能。**Phase 2 (BG asset DL) は size 目的では不要**、以下のいずれかに再位置付け可能:

- (a) **Phase 2 削除 or v1.2+ 送り**: Phase 1 で size 課題解決 → 実装スコープ縮小 (~1-2 週 → ~1 週)
- (b) **Phase 2 → progressive install UX (nice-to-have)**: Character コレクション画面での「新キャラ解禁時にダウンロード」演出は残置、size 目的から UX 目的に転換

**PM 推奨**: **(b)**。Phase 1 で size 課題は解決するが、character 解禁演出は v1.1 の game engagement 上有意義。ただし v1.1 launch の cutoff (10 月) 判断で切り離し可能なオプション扱いに。

### 3.2 Phase 3 (解禁演出統合) の再定義

Phase 2 が nice-to-have 化すると Phase 3 (解禁演出) の意義も再定義:

- Phase 3 は **Phase 2 の存在を前提とした on-demand DL 演出** = Phase 2 が nice-to-have 化なら Phase 3 も対応降格
- 代替案: v1.1 では **Phase 1 のみ実装 + Phase 2/3 は v1.2 候補**、v1.1 launch の scope 圧縮

### 3.3 実装工数の見直し

| Phase | 起票時見積 | 実測ベース修正 | 内訳 |
|---|---:|---:|---|
| Phase 0 (現状計測) | ~2h | ✅ **1.5h 実測完了** | 本文書 |
| Phase 1 (WebP + App Thinning) | ~1 週 (~40h) | **~2-3 日 (~15-20h)** | 89 files × WebP 変換 + `pubspec.yaml` asset エントリ更新 + Flutter 側互換性検証 + 実機動作確認 |
| Phase 2 (BG asset DL) | ~1-2 週 (~40-80h) | v1.2+ 送り可能 | Phase 2 の Backend + `AssetBundleManager` + `SabiAsset` widget 統合 |
| Phase 3 (解禁演出統合) | ~3-5 日 (~24-40h) | v1.2+ 送り可能 | Phase 2 依存 |
| **v1.1 scope 合計** | **~2-3 週** | **~2-3 日** ⭐ | Phase 1 のみで size 課題解決 |

**含意**: v1.1 の FEAT-510 実装工数が **~10 倍圧縮**。他の v1.1 主軸 (FEAT-505 Battle Skip / FEAT-511 熟練度 / FEAT-512 tutorial) にリソース回せる。

---

## 4. WebP 変換の実装ポイント (Phase 1 handoff 用)

### 4.1 変換対象と品質設定

| 対象 | 現状形式 | 変換後 | 品質設定 | 期待削減率 |
|---|---|---|---|---:|
| Character 14 files | PNG | WebP | quality=85 (lossy) | ~80% |
| World BG 21 files | PNG | WebP | quality=80 (lossy) | ~75% |
| Battle sprites 150 files (recurse) | PNG | WebP | quality=90 (lossless) | ~40% (dot-art は lossless が推奨) |
| Guild BG 4 files | PNG | WebP | quality=80 (lossy) | ~78% |
| NPC 2 files (Lilia) | PNG | WebP | quality=90 (lossless、faces) | ~50% |
| Sabi 3 files | PNG | WebP | quality=90 (lossless、mascot brand) | ~50% |
| animations/character_aria_motion_1.gif | GIF | Lottie or WebP animated | — | 判断保留、別途 spike |

**注意**: dot-art (battle sprites) は **lossy 変換で edge が blur する** ので lossless WebP (quality=90) 推奨。Character は AI 生成イラストなので lossy OK。

### 4.2 変換ツール

- **cwebp** (Google 公式 CLI、macOS/Linux/Windows): `cwebp -q 85 input.png -o output.webp`
- **Squoosh CLI**: `npx @squoosh/cli --webp '{quality:85}' *.png` (bulk 変換に便利)
- **Batch script**: `assets/images/characters/*.png` を bulk 変換する PowerShell script を Phase 1 handoff で用意

### 4.3 Flutter 側互換性

- Flutter 3.x は WebP native 対応 (`Image.asset('foo.webp')` そのまま動く)
- `pubspec.yaml` の asset エントリを `.png` → `.webp` に一括置換
- Dart code 内の `AssetImage('.../foo.png')` を `.webp` に一括置換 (grep + sed)、~14 character + 21 world BG + battle 150 + guild 4 = 189 個の path 置換
- iOS/Android 双方で WebP は Android 4.0+ / iOS 14+ から native サポート、Sabiowl の minimum OS 要件 (Android 8+ / iOS 15+) 内で問題なし

### 4.4 App Thinning

- iOS: `Assets.xcassets` 化されていない asset は Universal IPA に含まれる = 端末別最適化されない
- Sabiowl は現状 flutter assets 経由 (`assets/images/...`) 直接読み込み、`Assets.xcassets` 経由ではない
- App Thinning の効果は **Flutter 経由の asset には限定的** (~5-10% 削減程度)
- 主要削減効果は WebP 変換に依存

---

## 5. Pre-mortem for Phase 1 実装 (追加 3 件、起票時 S1-S7 に追加)

### S8: WebP lossy 変換で character の絵柄が劣化 → user feedback で「絵が汚くなった」

**緩和**: quality=85 で before/after 目視比較を PM が事前実施、劣化が目立つ character (Rune / Aurum の顔部分) は quality=90 に個別 up。全 14 character の視覚 QA を Phase 1 完了時に必須ゲート化。

### S9: Battle sprite (150 files) を lossless WebP にしても期待削減率 40% に届かない可能性

**緩和**: 事前 spike で battle sprite 5 files を lossless WebP 変換して実測、40% 未達なら lossy quality=95 (dot-art でも許容範囲) に切替検討。Phase 1 開始時に決着。

### S10: 189 個の path 置換の regression (画像未表示 or errorBuilder fallback)

**緩和**: Phase 1 完了後の実機動作確認で全 189 image path を 1 度は render 経路に載せる QA テスト。少なくとも Home / Guild / Battle 3 画面 + Character 全 14 体の詳細シート open を目視確認。

---

## 6. 次の Action (PM 判断依頼)

### 6.1 FEAT-510 指示書の更新

Phase 0 実測結果を反映して、指示書の Phase 1 見積・Phase 2/3 の position を更新する。**採用/棄却は user 判断**:

| 選択 | 内容 |
|---|---|
| **A. Phase 2/3 を v1.2 に送る (推奨)** | v1.1 は Phase 1 のみ (~2-3 日)、size 目的達成。Phase 2/3 は progressive install UX として v1.2 検討 |
| B. Phase 2/3 を残置 (原案通り) | v1.1 で全 Phase 実装 (~2-3 週)、character 解禁演出も含めた完成形 |
| C. Phase 2 のみ v1.1、Phase 3 は v1.2 | 中間解、Phase 2 の BG asset DL 基盤だけ整えて演出は後回し |

**PM 推奨**: **A**。他 v1.1 主軸 (FEAT-505 / FEAT-511 / FEAT-512) にリソース回せる。character 解禁演出は v1.2 の追加価値として整理。

### 6.2 Phase 1 実装の担当

- **A. PM 直接**: ~2-3 日集中 = PM が今すぐ着手可能な軽量規模
- **B. Develop 委譲**: 189 path 置換 + 14 character 視覚 QA = mechanical work、Develop に handoff 適
- **PM 推奨**: **B**。mechanical work は Develop 効率的、PM は残 v1.1 主軸の設計に focus。

---

## 7. References

- [FEAT-510 初回 DL 減量指示書](../instructions/FEAT-510_initial_download_size_reduction.md) — Phase 0 実測結果反映後に更新
- [Apple App Store Cellular Download 制限 (公式)](https://developer.apple.com/support/appstore/) — 200 MB を超えると Wi-Fi 必須、100 MB 以下が UX 上望ましい
- [Google Play App Bundle FAQ](https://developer.android.com/guide/app-bundle) — Play Store per-device slice で ~65-75 MB 推定
- [Flutter WebP support (公式)](https://docs.flutter.dev/ui/assets/assets-and-images) — Image.asset は WebP native 対応
- [FEAT-227](../instructions/FEAT-227_flutter_asset_cleanup.md) — Lottie / video_player 削除の前例、asset cleanup pattern の真実値

---

## 8. Change Log

- **2026-07-29**: Phase 0 実測完了 (PM 直接 ~1.5h)。Android aab 80.94 MB / 画像 59.22 MB (77%) 実測、Phase 1 WebP 変換で ~43-50 MB 到達見込を確認、Phase 2/3 の位置付け変更を PM 推奨。
