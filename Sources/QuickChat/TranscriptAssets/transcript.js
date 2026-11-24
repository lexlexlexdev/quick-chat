(function () {
    "use strict";

    var transcript = document.getElementById("transcript");
    if (!transcript) {
        return;
    }

    const states = new Map();
    let turns = [];
    let chatID = null;
    let selecting = false;

    var hasMarkdown = typeof window.markdownit === "function";
    var highlighter = window.hljs && typeof window.hljs.highlight === "function" ? window.hljs : null;
    var md = null;

    var HTML_ESCAPES = {
        "&": "&amp;",
        "<": "&lt;",
        ">": "&gt;",
        '"': "&quot;",
        "'": "&#39;"
    };

    function escapeHtml(value) {
        return String(value).replace(/[&<>"']/g, function (character) {
            return HTML_ESCAPES[character];
        });
    }

    function renderCode(raw, language, label) {
        var highlighted = null;
        var languageClass = "";

        if (highlighter && language) {
            try {
                if (highlighter.getLanguage(language)) {
                    highlighted = highlighter.highlight(raw, {
                        language: language,
                        ignoreIllegals: true
                    }).value;
                    languageClass = " language-" + escapeHtml(label);
                }
            } catch (error) {
                highlighted = null;
            }
        }

        if (highlighted === null) {
            highlighted = escapeHtml(raw);
        }

        return '<div class="code-block">' +
            '<div class="code-bar">' +
            (label ? '<span class="code-lang">' + escapeHtml(label) + "</span>" : "") +
            '<button type="button" class="copy-code" aria-label="Copy code">Copy</button>' +
            "</div>" +
            '<pre class="code-pre"><code class="hljs' + languageClass + '">' + highlighted + "</code></pre>" +
            "</div>";
    }

    function installMath(markdown, katex) {
        function closingDelimiter(source, delimiter, start, limit) {
            for (let i = start; i < limit; i++) {
                if (source.startsWith(delimiter, i)) return i;
                if (source[i] === "\\") i++;
            }
            return -1;
        }

        markdown.inline.ruler.before("escape", "math_inline", (state, silent) => {
            const { src, pos, posMax } = state;
            const dollar = src[pos] === "$" && src[pos - 1] !== "$" && src[pos + 1] !== "$";
            if (!dollar && !src.startsWith("\\(", pos)) return false;
            const start = pos + (dollar ? 1 : 2);
            const closer = dollar ? "$" : "\\)";
            const end = closingDelimiter(src, closer, start, posMax);
            if (end <= start || end + closer.length > posMax) return false;
            const content = src.slice(start, end);
            if (dollar && (content.trim() !== content || /[\n`]/.test(content) ||
                /[\d$]/.test(src.charAt(end + 1)))) return false;
            if (!content.trim()) return false;
            if (!silent) {
                const token = state.push("math_inline", "", 0);
                token.content = content;
                token.markup = dollar ? "$" : "\\(";
            }
            state.pos = end + closer.length;
            return true;
        });

        markdown.block.ruler.before("fence", "math_block", (state, startLine, endLine, silent) => {
            if (state.sCount[startLine] - state.blkIndent >= 4) return false;
            const indent = state.sCount[startLine];
            const first = state.getLines(startLine, startLine + 1, indent, false);
            const opener = first.startsWith("$$") ? "$$" : first.startsWith("\\[") ? "\\[" : "";
            if (!opener) return false;
            const closer = opener === "$$" ? "$$" : "\\]";
            let line = startLine;
            let text = first.slice(opener.length);
            let end;
            for (;;) {
                end = closingDelimiter(text, closer, 0, text.length);
                if (end !== -1) {
                    if (text.slice(end + closer.length).trim()) return false;
                    break;
                }
                if (++line >= endLine || (state.sCount[line] < state.blkIndent && !state.isEmpty(line))) return false;
                text = state.getLines(line, line + 1, indent, false);
            }
            const content = line === startLine ? text.slice(0, end) :
                first.slice(opener.length) + "\n" + state.getLines(startLine + 1, line, indent, true) + text.slice(0, end);
            if (!content.trim()) return false;
            if (silent) return true;
            const token = state.push("math_block", "", 0);
            token.block = true;
            token.content = content;
            token.markup = opener;
            token.map = [startLine, line + 1];
            state.line = line + 1;
            return true;
        }, { alt: ["paragraph", "reference", "blockquote", "list"] });

        function renderMath(token, displayMode) {
            let result;
            try {
                // WebKit renders MathML natively, with no KaTeX stylesheet or font downloads.
                result = katex.renderToString(token.content, {
                    displayMode, output: "mathml", trust: false, maxExpand: 200, maxSize: 20
                });
            } catch {
                const close = { "\\(": "\\)", "\\[": "\\]" }[token.markup] || token.markup;
                result = escapeHtml(token.markup + token.content + close);
            }
            return displayMode ? '<div class="math-display">' + result + "</div>\n" : result;
        }

        markdown.renderer.rules.math_inline = (tokens, index) => renderMath(tokens[index], false);
        markdown.renderer.rules.math_block = (tokens, index) => renderMath(tokens[index], true);
    }

    if (hasMarkdown) {
        md = window.markdownit({
            html: false,
            xhtmlOut: false,
            breaks: true,
            linkify: true,
            typographer: false
        });

        installMath(md, window.katex);

        md.validateLink = function (url) {
            return /^https:\/\/[^\s<>"']+$/i.test(url);
        };

        if (md.linkify && typeof md.linkify.set === "function") {
            md.linkify.set({ fuzzyEmail: false });
        }

        md.renderer.rules.image = function (tokens, index) {
            return escapeHtml(tokens[index].content || "");
        };

        md.renderer.rules.fence = function (tokens, index) {
            var token = tokens[index];
            var info = token.info ? token.info.trim() : "";
            var language = info ? info.split(/\s+/)[0] : "";
            var label = language.toLowerCase();
            return renderCode(token.content, language, label);
        };

        md.renderer.rules.code_block = function (tokens, index) {
            return renderCode(tokens[index].content, "", "");
        };

        md.renderer.rules.link_open = function (tokens, index, options, env, self) {
            var token = tokens[index];
            var href = token.attrGet("href");

            if (href && /^https:\/\//i.test(href)) {
                token.attrSet("rel", "noopener noreferrer");
            } else {
                token.attrs = (token.attrs || []).filter(function (attribute) {
                    return attribute[0] !== "href";
                });
                token.attrJoin("class", "link-blocked");
            }

            return self.renderToken(tokens, index, options);
        };
    }

    function createTurn(turn) {
        const element = document.createElement("article");
        element.className = "turn";
        element.innerHTML = `
            <section class="prompt" aria-label="You"><div class="prompt-text"></div></section>
            <section class="reply" aria-label="Assistant">
                <div class="activity" role="status" hidden>
                    <div class="loader" aria-hidden="true">
                        <span class="loader-bar loader-bar-1"></span><span class="loader-bar loader-bar-2"></span>
                        <span class="loader-bar loader-bar-3"></span><span class="loader-bar loader-bar-4"></span>
                        <span class="loader-bar loader-bar-5"></span>
                    </div><span class="activity-text"></span>
                </div>
                <div class="md" hidden></div>
                <details class="reply-summary" hidden>
                    <summary class="summary-toggle">Reasoning summary</summary><div class="summary-text"></div>
                </details>
                <div class="reply-error" role="alert" hidden></div>
                <div class="reply-stopped" hidden>Reply stopped</div>
            </section>`;
        element.querySelector(".prompt-text").textContent = turn.prompt;
        transcript.appendChild(element);
        return {
            reply: element.querySelector(".reply"),
            markdown: element.querySelector(".md"),
            activity: element.querySelector(".activity"),
            activityText: element.querySelector(".activity-text"),
            summary: element.querySelector(".reply-summary"),
            summaryText: element.querySelector(".summary-text"),
            error: element.querySelector(".reply-error"),
            stopped: element.querySelector(".reply-stopped"),
            previous: null,
            pending: null
        };
    }

    function selectionRange() {
        const selection = window.getSelection();
        return selection && selection.rangeCount && !selection.isCollapsed ? selection.getRangeAt(0) : null;
    }

    function patch(state, turn, text, range) {
        const previous = state.previous;
        if (!state.pending && text === previous?.text && turn.summary === previous.summary
            && turn.status === previous.status && turn.activity === previous.activity
            && turn.error === previous.error) return;
        if (selecting || range?.intersectsNode(state.reply)) {
            state.pending = { turn, text };
            return;
        }
        state.pending = null;
        if (text !== previous?.text) {
            state.markdown.innerHTML = md ? md.render(text) : escapeHtml(text);
            state.markdown.classList.toggle("md-plain", !md);
            state.markdown.hidden = !text;
        }
        if (turn.summary !== previous?.summary) {
            state.summaryText.textContent = turn.summary;
            state.summary.hidden = !turn.summary;
            if (!previous?.summary) state.summary.open = turn.status === "replying";
        }
        if (previous?.status === "replying" && turn.status !== "replying") state.summary.open = false;
        state.activity.hidden = turn.status !== "replying" || !!text;
        const label = turn.activity === "thinking" ? "Thinking…" : "Waiting for a reply…";
        if (!state.activity.hidden && state.activityText.textContent !== label) state.activityText.textContent = label;
        state.error.hidden = turn.status !== "failed";
        if (turn.error !== previous?.error) state.error.textContent = turn.error;
        state.stopped.hidden = turn.status !== "stopped";
        state.previous = { ...turn, text };
    }

    function atBottom() {
        const root = document.scrollingElement;
        return root.scrollHeight - root.scrollTop - root.clientHeight <= 56;
    }

    function follow() {
        document.scrollingElement.scrollTop = document.scrollingElement.scrollHeight;
    }

    window.updateTranscript = function (nextChatID, updatedTurns, snapshot) {
        const switched = chatID !== nextChatID;
        if (switched) {
            chatID = nextChatID;
            window.getSelection()?.removeAllRanges();
            transcript.replaceChildren();
            states.clear();
            turns = [];
            selecting = false;
        }
        const range = selectionRange();
        const following = switched || (!selecting && !range && atBottom());
        if (updatedTurns !== null) {
            turns = updatedTurns;
            for (const turn of turns) {
                let state = states.get(turn.id);
                if (!state) {
                    state = createTurn(turn);
                    states.set(turn.id, state);
                }
                patch(state, turn, turn.status === "replying" ? snapshot : turn.reply, range);
            }
        } else {
            const turn = turns.at(-1);
            if (turn?.status === "replying") patch(states.get(turn.id), turn, snapshot, range);
        }
        if (following) follow();
        return true;
    };

    function flushPending() {
        if (selecting) return;
        const range = selectionRange();
        for (const state of states.values()) {
            if (!state.pending || range?.intersectsNode(state.reply)) continue;
            const { turn, text } = state.pending;
            patch(state, turn, text, range);
        }
    }

    // Keep the selected DOM in place until the native selection no longer touches it.
    document.addEventListener("mousedown", event => {
        if (event.button === 0) selecting = true;
    });
    window.addEventListener("mouseup", () => {
        selecting = false;
        flushPending();
    });
    window.addEventListener("blur", () => {
        selecting = false;
        flushPending();
    });
    document.addEventListener("selectionchange", flushPending);

    transcript.addEventListener("click", event => {
        const button = event.target.closest(".copy-code");
        if (!event.isTrusted || !button) return;
        const code = button.closest(".code-block").querySelector("code").textContent;
        window.webkit.messageHandlers.copyCode.postMessage(code);
        button.textContent = "Copied";
        button.setAttribute("aria-label", "Copied");
        button.classList.add("copied");
        clearTimeout(button.copyResetTimer);
        button.copyResetTimer = setTimeout(() => {
            button.textContent = "Copy";
            button.setAttribute("aria-label", "Copy code");
            button.classList.remove("copied");
        }, 1500);
    });
})();
