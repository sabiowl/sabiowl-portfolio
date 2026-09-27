/*
 * 【2026-08-11】admin の翻訳下書きプロンプトを組み立ててクリップボードへコピーする。
 *
 * ## 何をするものか
 *
 * ボタンを押すと「原文 + 翻訳方針」を含んだプロンプトがクリップボードに入る。
 * それを LLM に貼り、返ってきた訳を admin のフォームに貼り戻す運用を想定する。
 *
 * **LLM は呼ばない。** 外部依存もシークレットも増えないのが本方式の要点で、
 * `anthropic` を SEC-11 (2026-05-15) で撤去した状態を維持したまま運用を軽くする。
 * API を直接叩く案は工数 6-8h + Render env var 追加になるため v1.1 では見送った
 * (現状の運用負荷は月 2 行 × 2 field = 数分)。
 *
 * ## フィールドの対応付けは設定しない
 *
 * フォームを走査して `id_<name>` と `id_<name>_en` が **両方存在する** ものを
 * ペアとして拾う。admin ごとに対応表を書かせると、field を足したときに
 * 更新を忘れる (`i18n_targets.py` の docstring が「手書きリストは人が思い出した
 * ものしか拾わない」と書いているのと同じ問題)。
 *
 * ## 使い方
 *
 *   class FooAdmin(admin.ModelAdmin):
 *       class Media:
 *           js = ('admin/js/i18n_translate_prompt.js',)
 *
 * ペアが 1 組も無いフォームでは何も描画しない (無害)。
 */
(function () {
  'use strict';

  var JA_TO_EN = 'ja2en';
  var EN_TO_JA = 'en2ja';

  /** フォーム内の `id_<name>` / `id_<name>_en` ペアを拾う。 */
  function collectPairs() {
    var pairs = [];
    var nodes = document.querySelectorAll('input[id^="id_"], textarea[id^="id_"]');
    Array.prototype.forEach.call(nodes, function (enNode) {
      if (!/_en$/.test(enNode.id)) return;
      var base = enNode.id.replace(/_en$/, '');
      var jaNode = document.getElementById(base);
      if (!jaNode) return;
      pairs.push({
        name: base.replace(/^id_/, ''),
        ja: jaNode,
        en: enNode,
      });
    });
    return pairs;
  }

  /* 翻訳方針。原文の語調を壊さないことを最優先にしている。
   * サビ口調ルール (CLAUDE.md) を無条件に適用してはいけない —— チャレンジの
   * 案内文は「みんなで達成しよう!」のような勧誘形で、サビの台詞ではない。
   * 🪶 の有無を手がかりにする条件付きルールとして書いてある。 */
  var COMMON = [
    '# 前提',
    'Sabiowl は「習慣化を楽しく続ける」ための iOS アプリです。習慣の達成が',
    'RPG 的な成長 (EXP / レベル / キャラクター) に繋がる設計になっています。',
    '',
    '# 方針',
    '- 直訳にしない。訳文だけを読んで自然に感じられる表現にする',
    '- **原文の語調を保つ**。丁寧体は丁寧体、勧誘形は勧誘形で受ける。',
    '  原文に無い感嘆符や絵文字を足さない',
    '- 原文に 🪶 が含まれる場合、それはマスコット「サビ」の発言。',
    '  落ち着いた紳士的なトーンを保ち、🪶 は文末に残す',
    '- 「例）」のような書式は、訳先の言語の慣用に置き換える (英語なら "e.g.")',
    '- 改行の位置は原文に合わせる',
    '- 固有名詞 (Sabiowl / サビ / リリア) は訳さない',
  ];

  var DIRECTION = {};
  DIRECTION[JA_TO_EN] = {
    label: '英訳の下書きプロンプトをコピー',
    from: 'ja',
    heading: '以下の日本語を **英語** にしてください。',
    extra: [
      '- 英語圏のアプリとして自然な語彙を選ぶ。和製英語や直訳調を避ける',
    ],
  };
  DIRECTION[EN_TO_JA] = {
    label: '和訳の下書きプロンプトをコピー',
    from: 'en',
    heading: '以下の英語を **日本語** にしてください。',
    extra: [
      '- 日本語がこのプロダクトの原文です。訳した結果が「翻訳っぽい」と',
      '  感じられないところまで練ってください',
      '- サビの台詞 (🪶 付き) を訳す場合のみ、次の語尾ルールに従うこと:',
      '  使う =「〜ですね / 〜ますよ / 〜でしょう / 〜しましょう」',
      '  禁止 =「〜じゃ / 〜のじゃ」(老人口調)、「〜だよ / 〜だね」(少年口調)、',
      '        一人称「ワシ / 僕 / 俺」、二人称「君 / お主」、感嘆符「!」',
    ],
  };

  function buildPrompt(direction, pairs) {
    var d = DIRECTION[direction];
    var filled = pairs.filter(function (p) {
      return (p[d.from].value || '').trim() !== '';
    });
    if (!filled.length) return null;

    var lines = ['# 依頼', d.heading, ''];
    lines = lines.concat(COMMON, d.extra, ['']);
    lines.push('# 出力形式');
    lines.push('前置きや説明を書かず、次の形式で訳文だけを返してください。');
    lines.push('');
    filled.forEach(function (p) {
      lines.push('[' + p.name + ']');
      lines.push('<訳文>');
      lines.push('');
    });
    lines.push('# 原文');
    filled.forEach(function (p) {
      lines.push('[' + p.name + ']');
      lines.push(p[d.from].value);
      lines.push('');
    });
    return lines.join('\n');
  }

  function flash(node, message, isError) {
    node.textContent = message;
    node.style.color = isError ? '#ba2121' : '#417690';
    if (flash._t) window.clearTimeout(flash._t);
    flash._t = window.setTimeout(function () { node.textContent = ''; }, 6000);
  }

  /** クリップボード API が使えない環境向けの退避先 (http 経由の admin 等)。 */
  function fallbackCopy(text, statusNode) {
    var ta = document.createElement('textarea');
    ta.value = text;
    ta.readOnly = true;
    ta.style.width = '100%';
    ta.style.height = '8em';
    ta.style.marginTop = '6px';
    statusNode.parentNode.appendChild(ta);
    ta.select();
    flash(statusNode, 'クリップボードに書けませんでした。下の枠から手動でコピーしてください。', true);
  }

  function makeButton(direction, pairs, statusNode) {
    var btn = document.createElement('button');
    btn.type = 'button';           // ← submit にしない (押すと保存されてしまう)
    btn.className = 'button';
    btn.style.marginRight = '8px';
    btn.textContent = DIRECTION[direction].label;
    btn.addEventListener('click', function () {
      var prompt = buildPrompt(direction, pairs);
      if (!prompt) {
        flash(statusNode, '訳元が空です。先に ' +
          (DIRECTION[direction].from === 'ja' ? '日本語' : '英語') + 'を入力してください。', true);
        return;
      }
      if (navigator.clipboard && window.isSecureContext) {
        navigator.clipboard.writeText(prompt).then(function () {
          flash(statusNode, 'コピーしました。LLM に貼り付けて、返ってきた訳をフォームに戻してください。');
        }, function () {
          fallbackCopy(prompt, statusNode);
        });
      } else {
        fallbackCopy(prompt, statusNode);
      }
    });
    return btn;
  }

  function init() {
    var pairs = collectPairs();
    if (!pairs.length) return;

    var anchor = document.querySelector('#content-main form fieldset')
              || document.querySelector('#content-main form');
    if (!anchor) return;

    var box = document.createElement('div');
    box.className = 'module aligned';
    box.style.padding = '10px 12px';
    box.style.marginBottom = '12px';

    var status = document.createElement('div');
    status.style.marginTop = '6px';
    status.style.fontSize = '12px';

    box.appendChild(makeButton(JA_TO_EN, pairs, status));
    box.appendChild(makeButton(EN_TO_JA, pairs, status));

    var note = document.createElement('div');
    note.style.marginTop = '6px';
    note.style.fontSize = '11px';
    note.style.color = '#666';
    // 「下書き」であることを画面にも出す。プロジェクトの方針は
    // 「LLM 一次翻訳 + reviewer check」(2026-08-03 ユーザー判断) で、
    // ここで生成した訳はレビューを通っていない。
    note.textContent =
      '対象: ' + pairs.map(function (p) { return p.name; }).join(' / ') +
      ' — 生成されるのは下書きです。そのまま公開せず、内容を確認してから保存してください。';
    box.appendChild(note);
    box.appendChild(status);

    anchor.parentNode.insertBefore(box, anchor);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
