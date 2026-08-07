# Battle Sprite Assets

【FEAT-295】MVP バトルシステム用のドット絵スプライト配置先。

## 想定ファイル一覧（PM 並行調達）

| ファイル名 | 用途 | 推奨サイズ | 調達方法 |
|---|---|---|---|
| `sabi.png` | サビ (フォールバック) | 96x96 | `assets/images/sabi/sabi_dot_6464.png` を 96x96 に拡大 |
| `enemy_goblin.png` | ゴブリン (MVP の敵) | 96x96 | AI 生成 (PixelLab 等) / フリー素材 |
| `character_zenon.png` | キャラ 1 (ゼノン) | 96x96 | 既存 `assets/images/characters/character_zenon.png` のドット化 |
| `character_aria.png` | キャラ 2 (アリア) | 96x96 | 同上 |
| ... | 他キャラ 7 体 | 96x96 | 同上 |

## 配置されていない場合の挙動

`CombatantSprite` (`mobile/lib/features/battle/widgets/combatant_sprite.dart`) の
`Image.asset(...).errorBuilder` でグレー半透明プレースホルダが表示される。
戦闘ロジック自体は問題なく動作する（数値・ログは正しく出る）。

## 手法 A / 手法 B

設計ノート (`doc/design/battle_system.md`) §7.1 を参照:
- **手法 A**: AI 画像生成で 8bit 風に変換 (1 キャラ 30 分 × 11 = ~6 時間)
- **手法 B**: 元 PNG を 96x96 にリサイズ + `FilterQuality.none` で nearest-neighbor 描画 (0 時間)

MVP は手法 A を狙い、間に合わなければ Phase 1b 開始時に手法 B でフォールバック。
