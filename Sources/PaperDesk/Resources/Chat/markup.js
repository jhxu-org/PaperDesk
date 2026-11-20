(function (root, factory) {
    if (typeof module === 'object' && module.exports) {
        module.exports = factory(require('./vendor/markdown-it.min.js'), require('./vendor/katex.min.js'));
    } else { root.PaperDeskMarkup = factory(root.markdownit, root.katex); }
})(typeof globalThis !== 'undefined' ? globalThis : this, function (markdownit, katex) {
    'use strict';
    const md = markdownit({ html: false, breaks: true, linkify: false, typographer: false });
    const escape = md.utils.escapeHtml;
    function escapedAt(text, at) {
        let count = 0;
        while (at > 0 && text[--at] === '\\') count++;
        return count % 2 === 1;
    }
    function mathAt(text, start, max = text.length) {
        let open, close, display = false;
        if (text.startsWith('$$', start)) { open = close = '$$'; display = true; }
        else if (text.startsWith('\\[', start)) { open = '\\['; close = '\\]'; display = true; }
        else if (text.startsWith('\\(', start)) { open = '\\('; close = '\\)'; }
        else if (text[start] === '$' && !/\s/.test(text[start + 1] || ' ')) { open = close = '$'; }
        else { return null; }
        const from = start + open.length;
        let end = from;
        while ((end = text.indexOf(close, end)) >= 0 && end < max) {
            if (escapedAt(text, end)) { end += close.length; continue; }
            if (open === '$' && (/\s/.test(text[end - 1]) || /[\d$]/.test(text[end + 1] || ''))) { end++; continue; }
            const body = text.slice(from, end);
            if (open === '$' && (body.includes('\n') || /^\d+(?:[.,]\d+)*$/.test(body))) return null;
            if (!body.trim()) return null;
            return { body, end: end + close.length, display, raw: text.slice(start, end + close.length) };
        }
        // Keep unclosed backslash delimiters visible while a response is streaming.
        if (open.startsWith('\\')) return { pending: true, raw: text.slice(start, max), end: max };
        return null;
    }
    // '$' must stop the text rule before Markdown consumes the surrounding prose.
    const terminators = new Set('\n\\`*_[\]!<&$~:#%+-=>@^{}');
    md.inline.ruler.at('text', function (state, silent) {
        let end = state.pos;
        while (end < state.posMax && !terminators.has(state.src[end])) end++;
        if (end === state.pos) return false;
        if (!silent) state.pending += state.src.slice(state.pos, end);
        state.pos = end; return true;
    });
    md.inline.ruler.before('escape', 'paper_math', function (state, silent) {
        const math = mathAt(state.src, state.pos, state.posMax);
        if (!math) return false;
        if (!silent) {
            const token = state.push(math.pending ? 'text' : 'paper_math', '', 0);
            token.content = math.pending ? math.raw : math.body;
            token.meta = math;
        }
        state.pos = math.end; return true;
    });
    md.block.ruler.before('fence', 'paper_math_block', function (state, startLine, endLine, silent) {
        const start = state.bMarks[startLine] + state.tShift[startLine];
        if (!state.src.startsWith('$$', start) && !state.src.startsWith('\\[', start)) return false;
        const math = mathAt(state.src, start, state.bMarks[endLine] ?? state.src.length);
        if (!math || math.pending) return false;
        let lastLine = startLine;
        while (lastLine + 1 < endLine && state.bMarks[lastLine + 1] < math.end) lastLine++;
        if (state.src.slice(math.end, state.eMarks[lastLine]).trim()) return false;
        if (silent) return true;
        const token = state.push('paper_math_block', '', 0);
        token.content = math.body; token.meta = math; token.block = true;
        token.map = [startLine, lastLine + 1]; state.line = lastLine + 1; return true;
    }, { alt: ['paragraph', 'reference', 'blockquote', 'list'] });
    function renderMath(tokens, index) {
        const token = tokens[index];
        try {
            return katex.renderToString(token.content, {
                displayMode: token.meta.display, throwOnError: true, trust: false,
                strict: 'ignore', maxSize: 20, maxExpand: 1000, output: 'htmlAndMathml', macros: {}
            });
        } catch (_) {
            return '<code class="math-fallback" title="公式尚未完整或含有不支持的语法">' + escape(token.meta.raw) + '</code>';
        }
    }
    md.renderer.rules.paper_math = renderMath;
    md.renderer.rules.paper_math_block = (tokens, i) => '<div class="math-block">' + renderMath(tokens, i) + '</div>\n';
    md.inline.ruler.before('link', 'paper_source', function (state, silent) {
        if (state.src[state.pos] !== '[') return false;
        const end = state.src.indexOf(']', state.pos + 1);
        if (end < 0 || end >= state.posMax) return false;
        const id = state.src.slice(state.pos + 1, end);
        const source = state.env.sources?.find(s => s.id === id);
        if (!source) return false;
        if (!silent) {
            const token = state.push('paper_source', '', 0); token.meta = source;
        }
        state.pos = end + 1; return true;
    });
    function visualHTML(visual) {
        const id = escape(visual.id), label = '第 ' + (visual.page + 1) + ' 页原文';
        // Only app-supplied JPEG data may become an image; model Markdown images stay disabled.
        const valid = /^data:image\/jpeg;base64,[A-Za-z0-9+/=]+$/.test(visual.dataURL || '');
        const image = valid ? '<img src="' + visual.dataURL + '" alt="' + label + '页面预览" />' : '<span class="visual-placeholder">原文页面预览</span>';
        return '<figure class="paper-visual"><button class="visual-image" data-visual="' + id + '" data-action="preview" aria-label="放大查看' + label + '">' + image + '</button>' +
            '<figcaption><strong>' + label + '</strong><span>' + escape(visual.caption) + '</span></figcaption>' +
            '<div class="visual-actions"><button data-visual="' + id + '" data-action="preview">放大查看</button><button data-visual="' + id + '" data-action="pdf">在 PDF 中展示</button></div></figure>';
    }
    md.block.ruler.before('paragraph', 'paper_visual', function (state, startLine, endLine, silent) {
        const start = state.bMarks[startLine] + state.tShift[startLine];
        const line = state.src.slice(start, state.eMarks[startLine]).trim();
        const match = /^\[visual:(p\d+)\]$/.exec(line);
        const visual = match && state.env.visuals?.find(v => v.id === match[1]);
        if (!visual) return false;
        if (silent) return true;
        const token = state.push('paper_visual', '', 0); token.meta = visual; token.block = true;
        token.map = [startLine, startLine + 1]; state.line = startLine + 1; return true;
    }, { alt: ['paragraph', 'reference', 'blockquote', 'list'] });
    md.renderer.rules.paper_visual = (tokens, i, options, env) => {
        const visual = tokens[i].meta;
        if (env.shownVisuals.has(visual.id)) return '';
        env.shownVisuals.add(visual.id);
        return visualHTML(visual);
    };
    md.inline.ruler.before('paper_source', 'paper_visual_link', function (state, silent) {
        const match = /^\[visual:(p\d+)\]/.exec(state.src.slice(state.pos));
        const visual = match && state.env.visuals?.find(v => v.id === match[1]);
        if (!visual) return false;
        if (!silent) { const token = state.push('paper_visual_link', '', 0); token.meta = visual; }
        state.pos += match[0].length; return true;
    });
    md.renderer.rules.paper_visual_link = (tokens, i, options, env) => {
        env.referencedVisuals.add(tokens[i].meta.id);
        return '<button class="visual-inline" data-visual="' + escape(tokens[i].meta.id) + '" data-action="preview">查看第 ' + (tokens[i].meta.page + 1) + ' 页配图</button>';
    };
    md.renderer.rules.paper_source = (tokens, i) => {
        const source = tokens[i].meta;
        return '<a class="citation" href="paperdesk://source/' + encodeURIComponent(source.id) + '">第 ' + (source.page + 1) + ' 页</a>';
    };
    md.renderer.rules.link_open = (tokens, i, options, env) => {
        const href = tokens[i].attrGet('href') || '';
        const source = env.sources?.find(s => href === 'paperdesk://source/' + encodeURIComponent(s.id));
        return source ? '<a class="citation" href="' + escape(href) + '">' : '<a>';
    };
    // Model output cannot load remote images, execute HTML, or navigate the embedded reader.
    md.renderer.rules.image = (tokens, i) => escape(tokens[i].content);
    return { render: (text, sources = [], visuals = []) => {
        const env = { sources, visuals, shownVisuals: new Set(), referencedVisuals: new Set() };
        let html = md.render(text, env);
        // Inline markers also receive a full card after the response, without invalid nested HTML.
        for (const visual of visuals) {
            if (env.referencedVisuals.has(visual.id) && !env.shownVisuals.has(visual.id)) {
                html += visualHTML(visual); env.shownVisuals.add(visual.id);
            }
        }
        return html;
    }, mathAt };
});
