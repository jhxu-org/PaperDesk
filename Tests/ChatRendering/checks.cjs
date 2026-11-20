const test = require('node:test');
const assert = require('node:assert/strict');
const { render } = require('../../Sources/PaperDesk/Resources/Chat/markup.js');
const countMath = html => (html.match(/class="katex"/g) || []).length;
const visual = { id: 'p2', page: 1, caption: 'Figure 1: Original <diagram>', dataURL: 'data:image/jpeg;base64,/9j/2Q==' };

test('trusted PDF previews appear between explanation paragraphs, with source actions', () => {
    const html = render('前文。\n\n[visual:p2]\n\n后文。 [p2b1]', [{ id: 'p2b1', page: 1 }], [visual]);
    assert.match(html, /<figure class="paper-visual">/);
    assert.ok(html.indexOf('前文') < html.indexOf('<figure'));
    assert.ok(html.indexOf('</figure>') < html.indexOf('后文'));
    assert.match(html, /data-action="preview"/); assert.match(html, /data-action="pdf"/);
    assert.match(html, /Figure 1: Original &lt;diagram&gt;/);
    assert.match(html, /第 2 页原文/);
    assert.match(html, /paperdesk:\/\/source\/p2b1/);
});
test('visual allowlist, duplicate markers, code and partial streams', () => {
    const text = '解释 [visual:p2]\n\n[visual:p2]\n\n[visual:p99]';
    assert.equal((render(text, [], [visual]).match(/<figure/g) || []).length, 1);
    assert.doesNotMatch(render('[visual:p99]', [], [visual]), /<img/);
    assert.doesNotMatch(render('`[visual:p2]`\n\n```\n[visual:p2]\n```', [], [visual]), /<img/);
    for (let i = 0; i <= text.length; i++) assert.doesNotThrow(() => render(text.slice(0, i), [], [visual]));
});
test('model image URLs and unsafe preview URLs cannot load images', () => {
    assert.doesNotMatch(render('![x](data:image/jpeg;base64,/9j/2Q==)'), /<img/);
    assert.doesNotMatch(render('[visual:p2]', [], [{ ...visual, dataURL: 'https://example.com/private' }]), /<img|src="https/);
    assert.doesNotMatch(render('[visual:p2]', [], [{ ...visual, dataURL: 'data:image/svg+xml;base64,abc' }]), /<img/);
    assert.match(render('[visual:p2]', [], [{ ...visual, dataURL: '' }]), /在 PDF 中展示/);
});

test('screenshot regression: inline fraction and arrows retain LaTeX before Markdown', () => {
    const html = render(String.raw`**问题诊断**：比例 \(R = \frac{BC}{BC+KL}\)，\(R \to 0\)；\(R \to 1\)。 [P4-C1]`, [{ id: 'P4-C1', page: 3 }]);
    assert.equal(countMath(html), 3);
    assert.match(html, /<mfrac>/);
    assert.match(html, /→/);
    assert.match(html, /<strong>问题诊断<\/strong>/);
    assert.match(html, /href="paperdesk:\/\/source\/P4-C1">第 4 页<\/a>/);
});
test('four delimiters, powers, integrals and aligned matrices', () => {
    const text = String.raw`行内 $x_i^2$ 和 \(\sqrt{x}\)。

$$
\int_0^1 x^2\,dx = \frac{1}{3}
$$

\[
\begin{aligned}A &= \begin{bmatrix}1 & 2\\3 & 4\end{bmatrix}\\
p(x) &= \sum_{i=1}^n w_i x_i
\end{aligned}
\]`;
    const html = render(text);
    assert.equal(countMath(html), 4);
    assert.equal((html.match(/class="math-block"/g) || []).length, 2);
    assert.doesNotMatch(html, /math-fallback/);
    assert.match(html, /<msubsup>|<msup>|<msub>/);
});
test('formulas work inside lists and adjacent Chinese prose', () => {
    const html = render(String.raw`1. 比例$R=\frac{BC}{BC+KL}$区分潜空间。
   - 当 \(R\to0\) 时退化。

   $$x^2+y^2=z^2$$
2. 下一点。`);
    assert.equal(countMath(html), 3);
    assert.match(html, /<ol>/); assert.match(html, /<ul>/);
    assert.match(html, /下一点/);
});
test('code fences and inline code keep their literal formulas and citations', () => {
    const text = '`\\(x\\)`、`$x$`、`[P1]`\n\n```latex\n\\[x^2\\]\n[P1]\n```';
    const html = render(text, [{ id: 'P1', page: 0 }]);
    assert.equal(countMath(html), 0);
    assert.doesNotMatch(html, /class="citation"/);
    assert.match(html, /<pre><code/);
});
test('literal escapes and currency remain readable', () => {
    const html = render(String.raw`价格 $5 和 $10，转义 \$x\$，双反斜杠 \\(x\\)。`);
    assert.equal(countMath(html), 0);
    assert.match(html, /价格 \$5 和 \$10/);
    assert.match(html, /转义 \$x\$/);
});
test('every streamed prefix renders safely and incomplete delimiters remain visible', () => {
    const text = String.raw`比例 \(R=\frac{BC}{BC+KL}\)；$$x^2$$ 完成。`;
    for (let i = 0; i <= text.length; i++) assert.doesNotThrow(() => render(text.slice(0, i)));
    assert.match(render(String.raw`比例 \(R=\frac{BC}`), /\\\(R=\\frac\{BC\}/);
    assert.equal(countMath(render(text)), 2);
});
test('malformed or unsupported math falls back without losing the answer', () => {
    const html = render(String.raw`前文 \(\frac{a}\) 后文 \(\unknowncommand{x}\) 结尾。`);
    assert.match(html, /math-fallback/); assert.match(html, /结尾/);
    assert.doesNotMatch(html, /<script/);
});
test('untrusted output cannot run HTML, fetch images or create arbitrary navigation', () => {
    const html = render(String.raw`<script>alert(1)</script><img src="https://example.com/leak">
![remote](https://example.com/tracker)
[open](https://example.com) [fake](paperdesk://source/UNKNOWN)
\(\href{https://example.com}{x}\) \(\includegraphics{https://example.com/a.png}\)`);
    assert.doesNotMatch(html, /<script|<img|href="https:|href="paperdesk:/);
    assert.match(html, /&lt;script&gt;/);
});
test('only supplied citation IDs are linked; code and unknown IDs are unchanged', () => {
    const html = render('[P1] [UNKNOWN] [引用](paperdesk://source/P1)', [{ id: 'P1', page: 0 }]);
    assert.equal((html.match(/class="citation"/g) || []).length, 2);
    assert.match(html, /\[UNKNOWN\]/);
});
test('rendered HTML includes accessible MathML and isolated bounded macros', () => {
    assert.match(render(String.raw`\(x^2\)`), /<math /);
    render(String.raw`\(\gdef\test{hidden}\test\)`);
    assert.match(render(String.raw`\(\test\)`), /math-fallback/);
    assert.match(render(String.raw`\(\def\loop{\loop}\loop\)`), /math-fallback/);
});
