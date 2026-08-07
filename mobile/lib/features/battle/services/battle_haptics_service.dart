import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 【新規 (2026-06-26)】バトル演出用ハプティクスサービス。
///
/// 「通知」ではなく「ゲーム演出」として 5 種のパターンを提供 (強度順):
///   - [playButtonPress]: 必殺ボタン押下時 — 極軽い tap (ほぼ感じない)
///   - [playNormalHit]  : 通常攻撃命中時 — 軽い tap「コツン」(2026-06-27 追加)
///   - [playGaugeMax]   : 必殺ゲージ MAX 到達時 — 中程度 ~100ms「ヴォン」
///   - [playCriticalHit]: クリ命中時 — 短い強パルス「ガツン」(2026-06-27 追加)
///   - [playUltimateHit]: 必殺技命中時 — 250-350ms 余韻ある「ヴヴーーーン」
///
/// ## プラットフォーム別実装
///
/// - **Android**: `VibrationEffect.createWaveform(timings, amplitudes, repeat)`
///   経由で波形 (パルス → 余韻減衰) を再生 (API 26+ の振幅制御端末)
/// - **iOS**: `CHHapticEngine` で `CHHapticPattern` を組み、強度 + 鋭さ + 持続を
///   制御した余韻のあるパターン (iOS 13+ + Taptic Engine 搭載端末)
/// - **未対応端末 / 失敗時**: `HapticFeedback` の合成チェーン (lightImpact /
///   mediumImpact / heavyImpact を時間差で連打) にフォールバック
///
/// MethodChannel `sabiowl/battle_haptics` 経由でネイティブと通信する。
/// チャンネル未登録 / 例外時は自動でフォールバックパスを実行する。
class BattleHapticsService {
  BattleHapticsService._();
  static final BattleHapticsService instance = BattleHapticsService._();

  /// ネイティブ MethodChannel 名 (Android Kotlin / iOS Swift と一致)。
  static const _channel = MethodChannel('sabiowl/battle_haptics');

  /// 【2026-06-27】通常攻撃命中時のハプティクス (微小な振動「コツン」)。
  ///
  /// ターン制 ATB バトルで攻撃が当たるたびに発火するため、邪魔にならない最小強度。
  /// - Android: 15ms / 振幅 80 (buttonPress 振幅 50 より一段強い)
  /// - iOS: CHHapticTransient intensity 0.35 / sharpness 0.5
  /// - フォールバック: `HapticFeedback.selectionClick` (Apple/Android 標準の軽い tap)
  ///
  /// クリティカル時は [playCriticalHit] を呼ぶこと (本メソッドとは別の強い感触)。
  Future<void> playNormalHit() async {
    if (await _invokeNative('normalHit')) return;
    await HapticFeedback.selectionClick();
  }

  /// 【2026-06-27】クリティカル命中時のハプティクス (短い強パルス「ガツン」)。
  ///
  /// 通常攻撃より明らかに強く、クリの瞬間を強調する。必殺技 (ultimateHit、350ms 波形)
  /// より短い単発で「必殺技 ≠ クリティカル」の差別化。
  /// - Android: 60ms / 振幅 200 (gaugeMax 130 と ultimateHit 255 の中間)
  /// - iOS: CHHapticTransient intensity 0.75 / sharpness 0.85
  /// - フォールバック: `HapticFeedback.mediumImpact` (Apple/Android 標準の中インパクト)
  Future<void> playCriticalHit() async {
    if (await _invokeNative('criticalHit')) return;
    await HapticFeedback.mediumImpact();
  }

  /// 必殺ゲージ MAX 到達時のハプティクス (中程度 ~100ms「ヴォン」)。
  ///
  /// 「もうすぐ撃てる」の合図、邪魔にならない強さで一発だけ。
  Future<void> playGaugeMax() async {
    if (await _invokeNative('gaugeMax')) return;
    // Fallback: 標準 medium impact (短い 1 発、~30-50ms)
    await HapticFeedback.mediumImpact();
  }

  /// 必殺ボタン押下時のハプティクス (極軽い tap 感)。
  ///
  /// ボタン操作のフィードバックとしては最弱、押した感は出すが演出を邪魔しない。
  Future<void> playButtonPress() async {
    if (await _invokeNative('buttonPress')) return;
    // Fallback: standard selection click (very light)
    await HapticFeedback.selectionClick();
  }

  /// 必殺技命中時のハプティクス (250-350ms 余韻ある「ヴヴーーーン」)。
  ///
  /// 撃墜エフェクトのインパクトと同期、画面シェイク + フラッシュ + 爆発と
  /// **同一フレームで開始** される (caller 側で await を使わず fire-and-forget
  /// 推奨)。
  Future<void> playUltimateHit() async {
    if (await _invokeNative('ultimateHit')) return;
    // Fallback: 強→中→軽 の time-staggered chain で「余韻」を模倣
    // (true な waveform 制御は native 経路でしか実現できないため近似)
    HapticFeedback.heavyImpact();
    await Future<void>.delayed(const Duration(milliseconds: 90));
    HapticFeedback.heavyImpact();
    await Future<void>.delayed(const Duration(milliseconds: 90));
    HapticFeedback.mediumImpact();
    await Future<void>.delayed(const Duration(milliseconds: 90));
    HapticFeedback.lightImpact();
  }

  /// MethodChannel 呼び出しヘルパ。
  ///
  /// 戻り値: native 側が `true` を返した場合のみ true (= ネイティブで再生済)。
  /// チャンネル未登録 / 例外 / 端末非対応 (false) のいずれかで false を返し、
  /// 呼び出し側でフォールバック経路に進む。
  Future<bool> _invokeNative(String method) async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return false;
    }
    try {
      final ok = await _channel.invokeMethod<bool>(method);
      return ok == true;
    } on PlatformException catch (e, st) {
      debugPrint('[BattleHaptics] $method native failed: $e');
      debugPrintStack(stackTrace: st);
      return false;
    } on MissingPluginException {
      // ネイティブハンドラ未登録 (build 漏れ等)。サイレントフォールバック。
      return false;
    } catch (e) {
      debugPrint('[BattleHaptics] $method unexpected: $e');
      return false;
    }
  }
}
