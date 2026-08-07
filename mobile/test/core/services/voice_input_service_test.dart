// 【FEAT-499 (2026-07-26) / FEAT-501 (2026-07-26)】VoiceInputService テスト。
//
// speech_to_text は iOS/Android プラットフォームチャンネルを使用するため、
// 実 STT 動作はユニットテストでは検証できない。従来 (FEAT-499) は Dart-only な
// 状態 (シングルトン同一性・初期状態・未初期化 stop/cancel の安全性) のみ検証していた。
//
// 【FEAT-501 B】VoiceInputService.forTest(SpeechToText) の seam を使い、
// fake SpeechToText を注入して「実際に事故った 3 契約 + timeout 契約」を縛る:
//   契約1 (9257291): _stt.listen() が TypeError 相当 (null 返却→bool cast 失敗) でも
//                    onResult(final) が届けば Future は最終結果で解決する
//   契約2 (aac71c6): final onResult が来なくても、直前 partial + onStatus フォール
//                    バックで中間結果が返る (Samsung では final が空/欠落するケース)
//   契約3 (b882d43): permanent error 後の次の initialize() で SpeechToText を再生成
//   契約4 (FEAT-501 A): listen() が timeout に到達したら _lastPartialWords を返し、
//                    _stt.cancel() を呼ぶ (processing ハングの脱出路)
//
// iOS 実機での動作検証は user 側 (subaru) が `flutter run` で実施。
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'package:sabiowl/core/services/voice_input_service.dart';

/// initialize()/listen() のコールバックを driver 可能にする fake SpeechToText。
///
/// initialize/listen で渡された onStatus/onError/onResult を保持し、
/// emit* ヘルパーでテスト側から発火する。
class _FakeStt extends SpeechToText {
  // SpeechToText() は singleton を返す factory のため、継承には generative な
  // withMethodChannel() (@visibleForTesting、body 空) を super で呼ぶ。
  _FakeStt({this.available = true, this.startedResult = true})
      : super.withMethodChannel();

  bool available;

  /// _stt.listen() の戻り値。null にすると service 側の
  /// `bool started = await _stt.listen(...)` で dynamic→bool 暗黙 downcast が
  /// TypeError を投げる (Samsung Galaxy quirk の再現)。
  Object? startedResult;

  SpeechStatusListener? onStatusCb;
  SpeechErrorListener? onErrorCb;
  SpeechResultListener? onResultCb;

  bool _listening = false;
  int initializeCount = 0;
  int listenCount = 0;
  int cancelCount = 0;
  int stopCount = 0;

  @override
  bool get isAvailable => available;

  @override
  bool get isListening => _listening;

  @override
  Future<bool> initialize({
    SpeechErrorListener? onError,
    SpeechStatusListener? onStatus,
    dynamic debugLogging = false,
    Duration finalTimeout = const Duration(seconds: 2),
    List<SpeechConfigOption>? options,
  }) async {
    initializeCount++;
    onErrorCb = onError;
    onStatusCb = onStatus;
    return available;
  }

  @override
  Future<dynamic> listen({
    SpeechResultListener? onResult,
    Duration? listenFor,
    Duration? pauseFor,
    String? localeId,
    SpeechSoundLevelChange? onSoundLevelChange,
    dynamic cancelOnError = false,
    dynamic partialResults = true,
    dynamic onDevice = false,
    ListenMode listenMode = ListenMode.confirmation,
    dynamic sampleRate = 0,
    SpeechListenOptions? listenOptions,
  }) async {
    listenCount++;
    onResultCb = onResult;
    _listening = true;
    return startedResult; // null => 呼出側 bool 代入で TypeError
  }

  @override
  Future<void> cancel() async {
    cancelCount++;
    _listening = false;
  }

  @override
  Future<void> stop() async {
    stopCount++;
    _listening = false;
  }

  // ── test drivers ──────────────────────────────────────────────────────
  void emitPartial(String words) => onResultCb?.call(_result(words, false));
  void emitFinal(String words) => onResultCb?.call(_result(words, true));
  void emitStatus(String status) => onStatusCb?.call(status);
  void emitError(String msg, {bool permanent = false}) =>
      onErrorCb?.call(SpeechRecognitionError(msg, permanent));

  SpeechRecognitionResult _result(String words, bool isFinal) =>
      SpeechRecognitionResult(
        [SpeechRecognitionWords(words, null, 1.0)],
        (isFinal ? ResultType.finalResult : ResultType.partial).value,
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VoiceInputService — Dart-only 基本契約 (FEAT-499)', () {
    test('シングルトンは同一インスタンスを返す', () {
      expect(VoiceInputService.instance, same(VoiceInputService.instance));
    });

    test('初期状態: isListening = false', () {
      expect(VoiceInputService.instance.isListening, isFalse);
    });

    test('未初期化・未リスニング時に stop() を呼んでも例外なし', () {
      expect(() => VoiceInputService.instance.stop(), returnsNormally);
    });

    test('未初期化・未リスニング時に cancel() を呼んでも例外なし', () {
      expect(() => VoiceInputService.instance.cancel(), returnsNormally);
    });

    test('cancel() 後も isListening = false のまま', () {
      VoiceInputService.instance.cancel();
      expect(VoiceInputService.instance.isListening, isFalse);
    });
  });

  group('VoiceInputService — 契約テスト (FEAT-501 B、forTest seam)', () {
    test('契約1: listen() が null 返却 (TypeError 経路) でも final onResult で解決する',
        () async {
      // startedResult=null → service の `bool started = await ...` が TypeError、
      // Samsung quirk として started=true 扱い → onResult(final) を待つ。
      final fake = _FakeStt(available: true, startedResult: null);
      final svc = VoiceInputService.forTest(fake);

      final future = svc.listen();
      await pumpEventQueue(); // initialize + _stt.listen を解決し onResult を格納

      fake.emitFinal('こんにちは');
      expect(await future, 'こんにちは',
          reason: 'TypeError で return せず onResult(final) の結果を返す');
      expect(svc.lastError, isNull, reason: 'final が届けばエラー扱いにしない');
    });

    test('契約2: final onResult が来なくても onStatus フォールバックで中間結果を返す',
        () async {
      final fake = _FakeStt(available: true, startedResult: true);
      final svc = VoiceInputService.forTest(fake);

      final future = svc.listen();
      await pumpEventQueue();

      fake.emitPartial('とちゅうまで');   // _lastPartialWords を更新
      fake.emitStatus('notListening');    // 100ms 猶予後にフォールバック complete

      expect(await future, 'とちゅうまで',
          reason: 'final 欠落時は直前 partial (_lastPartialWords) を返す');
    });

    test('契約3: permanent error 後の次の initialize() で SpeechToText を再生成する',
        () async {
      final first = _FakeStt(available: true);
      final second = _FakeStt(available: true);
      final svc = VoiceInputService.forTest(first)..sttFactory = () => second;

      expect(await svc.initialize(), isTrue);
      expect(first.initializeCount, 1);

      // permanent error 発生 → 内部 _permanentError フラグが立つ
      first.emitError('error_client', permanent: true);

      // 次の initialize() は sttFactory() 経由で新インスタンス (second) を初期化する
      expect(await svc.initialize(), isTrue);
      expect(second.initializeCount, 1,
          reason: 'permanent error 後は新インスタンスで再初期化する');
      expect(first.initializeCount, 1, reason: '旧インスタンスを再利用しない');
    });

    test('契約4: timeout 到達で _lastPartialWords を返し _stt.cancel() を呼ぶ', () {
      fakeAsync((async) {
        final fake = _FakeStt(available: true, startedResult: true);
        final svc = VoiceInputService.forTest(fake);

        String? result;
        Object? error;
        svc.listen(timeout: const Duration(seconds: 30)).then(
              (r) => result = r,
              onError: (Object e) => error = e,
            );
        async.flushMicrotasks(); // initialize + _stt.listen を解決

        fake.emitPartial('とちゅう'); // _lastPartialWords='とちゅう'
        async.elapse(const Duration(seconds: 35)); // listenFor(30)+5s に到達
        async.flushMicrotasks();

        expect(error, isNull);
        expect(result, 'とちゅう', reason: 'timeout でも途中の partial を捨てない');
        expect(fake.cancelCount, greaterThan(0),
            reason: 'timeout で _stt.cancel() を呼ぶ');
        expect(svc.lastError, 'listen_timeout');
      });
    });
  });
}
