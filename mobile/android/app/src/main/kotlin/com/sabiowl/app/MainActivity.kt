package com.sabiowl.app

import android.content.Context
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * MainActivity with MethodChannel handler for battle haptics.
 *
 * 【新規 (2026-06-26)】サビバトル必殺技演出用の波形ハプティクス。
 * Channel: "sabiowl/battle_haptics"
 *
 * 5 メソッド (強度順):
 *  - buttonPress : 極軽い 20ms 単発、振幅 50 (ボタン押下フィードバック)
 *  - normalHit   : 軽い 15ms 単発、振幅 80 (通常攻撃命中、2026-06-27 追加)
 *  - gaugeMax    : 中程度 ~100ms 単発、振幅 130 (ゲージ MAX 通知)
 *  - criticalHit : 強め 60ms 単発、振幅 200 (クリ命中、2026-06-27 追加)
 *  - ultimateHit : 250-350ms 余韻ある波形、振幅 255 (撃墜エフェクト命中)
 *  - koFinish    : 380ms「一撃 → 間 → 祝祭」波形 (FEAT-526、2026-08-22 追加)
 *
 * VibrationEffect.createWaveform で振幅 + 持続を制御 (API 26+)。
 * 振幅制御非対応の端末は createOneShot にフォールバック。
 * API 26 未満は default vibrate (ms 指定のみ、deprecated だが互換目的で許容)。
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "sabiowl/battle_haptics"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                val vibrator = getVibrator() ?: run {
                    result.success(false)
                    return@setMethodCallHandler
                }
                if (!vibrator.hasVibrator()) {
                    result.success(false)
                    return@setMethodCallHandler
                }
                when (call.method) {
                    "gaugeMax"    -> result.success(playGaugeMax(vibrator))
                    "buttonPress" -> result.success(playButtonPress(vibrator))
                    "ultimateHit" -> result.success(playUltimateHit(vibrator))
                    // 【2026-06-27】通常攻撃 / クリ命中。CLAUDE.md FEAT-296
                    // 「3 段防御 + 強度別分離」哲学と整合 (buttonPress→normalHit→
                    // gaugeMax→criticalHit→ultimateHit の振幅階段)。
                    "normalHit"   -> result.success(playNormalHit(vibrator))
                    "criticalHit" -> result.success(playCriticalHit(vibrator))
                    // 【FEAT-526】とどめの一撃。ultimateHit と違い **上昇して終わる**
                    // (「強く当たった」ではなく「勝った」を返すため)。
                    "koFinish"    -> result.success(playKoFinish(vibrator))
                    else          -> result.notImplemented()
                }
            }
    }

    /** API 31+ では VibratorManager 経由、それ以下では legacy getSystemService。 */
    private fun getVibrator(): Vibrator? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val manager =
                getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager
            manager?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        }
    }

    /** ゲージ MAX: 100ms 中程度 (振幅 130/255)。 */
    private fun playGaugeMax(vibrator: Vibrator): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val effect = if (vibrator.hasAmplitudeControl()) {
                VibrationEffect.createOneShot(100L, 130)
            } else {
                VibrationEffect.createOneShot(100L, VibrationEffect.DEFAULT_AMPLITUDE)
            }
            vibrator.vibrate(effect)
            true
        } else {
            @Suppress("DEPRECATION")
            vibrator.vibrate(100L)
            true
        }
    }

    /** ボタン押下: 20ms 極軽い tap (振幅 50/255)。 */
    private fun playButtonPress(vibrator: Vibrator): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val effect = if (vibrator.hasAmplitudeControl()) {
                VibrationEffect.createOneShot(20L, 50)
            } else {
                // 振幅制御不可: 既定強度の最短パルス
                VibrationEffect.createOneShot(20L, VibrationEffect.DEFAULT_AMPLITUDE)
            }
            vibrator.vibrate(effect)
            true
        } else {
            @Suppress("DEPRECATION")
            vibrator.vibrate(20L)
            true
        }
    }

    /**
     * 【2026-06-27】通常攻撃命中: 15ms 軽い tap (振幅 80/255)。
     *
     * ターン制 ATB バトルで攻撃が当たるたびに発火するため、邪魔にならない最小強度。
     * buttonPress (振幅 50) よりわずかに強く、「コツン」と当たった存在感を与える。
     * クリティカルは playCriticalHit (振幅 200) で明らかに強い別感触。
     */
    private fun playNormalHit(vibrator: Vibrator): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val effect = if (vibrator.hasAmplitudeControl()) {
                VibrationEffect.createOneShot(15L, 80)
            } else {
                VibrationEffect.createOneShot(15L, VibrationEffect.DEFAULT_AMPLITUDE)
            }
            vibrator.vibrate(effect)
            true
        } else {
            @Suppress("DEPRECATION")
            vibrator.vibrate(15L)
            true
        }
    }

    /**
     * 【2026-06-27】クリティカル命中: 60ms 強めパルス (振幅 200/255)。
     *
     * 通常攻撃 (15ms / 振幅 80) より明らかに強く、「ガツン」と決まった感を演出。
     * ultimateHit (350ms 波形) より短い単発で「クリの瞬間」を強調、必殺技と差別化。
     */
    private fun playCriticalHit(vibrator: Vibrator): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val effect = if (vibrator.hasAmplitudeControl()) {
                VibrationEffect.createOneShot(60L, 200)
            } else {
                VibrationEffect.createOneShot(60L, VibrationEffect.DEFAULT_AMPLITUDE)
            }
            vibrator.vibrate(effect)
            true
        } else {
            @Suppress("DEPRECATION")
            vibrator.vibrate(60L)
            true
        }
    }

    /**
     * 必殺技命中: 300ms 余韻ある波形 (撃墜エフェクト)。
     *
     * 波形設計 (timings/amplitudes ペア):
     *   - 0 → 50ms  : amplitude 0 (pre-delay、撃墜の「タメ」)
     *   - 50 → 150ms: amplitude 255 (最強パルス 100ms「ヴ」)
     *   - 150 → 230ms: amplitude 180 (中強度 80ms「ヴーーー」)
     *   - 230 → 350ms: amplitude 80 (低強度 120ms 余韻「ーン」)
     *
     * 合計 350ms、徐々に減衰する余韻パターン。
     */
    private fun playUltimateHit(vibrator: Vibrator): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val timings = longArrayOf(50L, 100L, 80L, 120L)
            if (vibrator.hasAmplitudeControl()) {
                val amplitudes = intArrayOf(0, 255, 180, 80)
                val effect = VibrationEffect.createWaveform(timings, amplitudes, -1)
                vibrator.vibrate(effect)
            } else {
                // 振幅制御非対応端末: timing のみで凹凸 (vibrate-pause-vibrate-pause)
                val onOffTimings = longArrayOf(50L, 100L, 30L, 80L, 50L, 120L)
                val effect = VibrationEffect.createWaveform(onOffTimings, -1)
                vibrator.vibrate(effect)
            }
            true
        } else {
            // API 26 未満: 古い pattern API
            @Suppress("DEPRECATION")
            val pattern = longArrayOf(50L, 100L, 30L, 80L, 50L, 120L)
            @Suppress("DEPRECATION")
            vibrator.vibrate(pattern, -1)
            true
        }
    }

    /**
     * 【FEAT-526 (2026-08-22)】とどめの一撃: 380ms「一撃 → 間 → 祝祭」波形。
     *
     * ultimateHit との違いは **終わり方** である。ultimateHit は減衰して消える
     * (「強く当たった」)。こちらは上昇して終わる (「勝った」)。
     *
     * 波形設計 (timings[i] は amplitudes[i] の継続時間):
     *   -   0 →  60ms : 振幅 255  とどめの一撃「ドン」
     *   -  60 → 180ms : 振幅   0  **ヒットストップの「間」** ← ここがいちばん大事
     *   - 180 → 215ms : 振幅 140  祝祭 1「タ」
     *   - 215 → 240ms : 振幅   0  区切り
     *   - 240 → 285ms : 振幅 190  祝祭 2「タ」
     *   - 285 → 310ms : 振幅   0  区切り
     *   - 310 → 380ms : 振幅 255  祝祭 3「ターン」
     *
     * 合計 380ms。真ん中の無音を詰めると、ただの連打になって「決めた」感が消える。
     *
     * 振幅制御非対応の端末では on/off の時間だけで同じリズムを作る
     * (強弱は出せないが、**間とリズムは再現できる** —— そちらが本質)。
     */
    private fun playKoFinish(vibrator: Vibrator): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val timings = longArrayOf(60L, 120L, 35L, 25L, 45L, 25L, 70L)
            if (vibrator.hasAmplitudeControl()) {
                val amplitudes = intArrayOf(255, 0, 140, 0, 190, 0, 255)
                val effect = VibrationEffect.createWaveform(timings, amplitudes, -1)
                vibrator.vibrate(effect)
            } else {
                // 振幅制御非対応: timing の on/off だけで同じリズムを刻む。
                // createWaveform(timings, repeat) は timings[0] を「待ち」として
                // 扱うので、先頭に 0 を置いてから on/off を交互に並べる。
                val onOffTimings = longArrayOf(0L, 60L, 120L, 35L, 25L, 45L, 25L, 70L)
                val effect = VibrationEffect.createWaveform(onOffTimings, -1)
                vibrator.vibrate(effect)
            }
            true
        } else {
            // API 26 未満: 古い pattern API (先頭は待ち時間)
            @Suppress("DEPRECATION")
            val pattern = longArrayOf(0L, 60L, 120L, 35L, 25L, 45L, 25L, 70L)
            @Suppress("DEPRECATION")
            vibrator.vibrate(pattern, -1)
            true
        }
    }
}
