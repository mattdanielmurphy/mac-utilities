-- ~/.hammerspoon/modules/logic_editor.lua
-- Bespoke Logic Symbol Editor & Always-Visible Cheat Sheet HUD
-- Allows rapid writing of logical formulas with live macro expansion,
-- one-click symbol cards, Option-number shortcuts, and 1-stroke app pasting.

local M = {
  id = "logic_editor",
  name = "Logic Symbol Editor & Cheat Sheet",
  defaultEnabled = true
}

_G.activeWatchers = _G.activeWatchers or {}
local activeWatchers = _G.activeWatchers

local log = hs.logger.new("logic_editor", "info")

M.previousApp = nil
M.isVisible = false

-- ── HTML UI Content ─────────────────────────────────────────────────────────────

local HTML_CONTENT = [[
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Logic Symbol Editor</title>
<style>
  :root {
    --bg-main: #121214;
    --bg-header: #1a1a1e;
    --bg-card: #202025;
    --bg-card-hover: #2a2a32;
    --bg-card-active: #151518;
    --border: rgba(255, 255, 255, 0.1);
    --border-accent: #00e5ff;
    --text-main: #f4f4f5;
    --text-muted: #a1a1aa;
    --accent-cyan: #00e5ff;
    --accent-blue: #3b82f6;
    --accent-emerald: #10b981;
    --accent-amber: #f59e0b;
    --accent-purple: #a855f7;
  }

  * {
    box-sizing: border-box;
    margin: 0;
    padding: 0;
    user-select: none;
    -webkit-user-select: none;
    -webkit-font-smoothing: antialiased;
  }

  input, textarea {
    user-select: text;
    -webkit-user-select: text;
  }

  body {
    background: var(--bg-main);
    color: var(--text-main);
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Roboto, sans-serif;
    height: 100vh;
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }

  /* ── Header ────────────────────────────────────────────────────────── */
  .header {
    background: var(--bg-header);
    border-bottom: 1px solid var(--border);
    padding: 10px 16px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
  }

  .header-left {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .title {
    font-size: 13px;
    font-weight: 700;
    letter-spacing: 0.5px;
    color: #ffffff;
    text-transform: uppercase;
  }

  .hotkey-badge {
    font-size: 10px;
    background: rgba(255, 255, 255, 0.08);
    border: 1px solid var(--border);
    border-radius: 4px;
    padding: 2px 6px;
    color: var(--accent-cyan);
    font-family: ui-monospace, 'SF Mono', monospace;
    font-weight: 600;
  }

  .header-actions {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .btn {
    border: 1px solid transparent;
    border-radius: 6px;
    padding: 5px 12px;
    font-size: 12px;
    font-weight: 600;
    cursor: pointer;
    transition: all 0.12s ease;
    display: inline-flex;
    align-items: center;
    gap: 6px;
    outline: none;
  }

  .btn-subtle {
    background: rgba(255, 255, 255, 0.05);
    border-color: var(--border);
    color: var(--text-muted);
  }
  .btn-subtle:hover {
    background: rgba(255, 255, 255, 0.1);
    color: #ffffff;
  }

  .btn-secondary {
    background: #27272a;
    border-color: rgba(255, 255, 255, 0.14);
    color: #ffffff;
  }
  .btn-secondary:hover {
    background: #323238;
    border-color: rgba(255, 255, 255, 0.25);
  }

  .btn-primary {
    background: linear-gradient(135deg, #0284c7 0%, #0369a1 100%);
    border-color: #38bdf8;
    color: #ffffff;
    box-shadow: 0 2px 8px rgba(2, 132, 199, 0.4);
  }
  .btn-primary:hover {
    background: linear-gradient(135deg, #0369a1 0%, #0284c7 100%);
    box-shadow: 0 3px 12px rgba(2, 132, 199, 0.6);
  }
  .btn-primary:active {
    transform: translateY(1px);
  }

  .btn-icon {
    background: transparent;
    border: none;
    color: var(--text-muted);
    font-size: 14px;
    padding: 4px 8px;
    border-radius: 4px;
  }
  .btn-icon:hover {
    background: rgba(255, 255, 255, 0.1);
    color: #ffffff;
  }

  /* ── Cheat Sheet ───────────────────────────────────────────────────── */
  .cheat-sheet-container {
    background: #161619;
    border-bottom: 1px solid var(--border);
    padding: 10px 14px 12px 14px;
    display: flex;
    flex-direction: column;
    gap: 8px;
  }

  .cheat-sheet-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    font-size: 10px;
    text-transform: uppercase;
    letter-spacing: 0.6px;
    color: var(--text-muted);
    font-weight: 700;
  }

  .cs-hint {
    color: var(--accent-cyan);
    font-size: 10px;
    font-weight: 500;
    text-transform: none;
    letter-spacing: normal;
  }

  .groups-wrapper {
    display: flex;
    flex-direction: column;
    gap: 8px;
  }

  .group-row {
    display: flex;
    align-items: center;
    gap: 10px;
  }

  .group-tag {
    font-size: 9px;
    font-weight: 700;
    color: #71717a;
    width: 82px;
    flex-shrink: 0;
    text-transform: uppercase;
    letter-spacing: 0.5px;
  }

  .keycaps-grid {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
    flex: 1;
  }

  .keycap {
    background: var(--bg-card);
    border: 1px solid var(--border);
    box-shadow: 0 2px 0 rgba(0, 0, 0, 0.5);
    border-radius: 6px;
    padding: 4px 7px;
    cursor: pointer;
    display: inline-flex;
    align-items: center;
    gap: 6px;
    transition: all 0.1s cubic-bezier(0.2, 0, 0, 1);
    color: var(--text-main);
  }

  .keycap:hover {
    background: var(--bg-card-hover);
    border-color: var(--accent-cyan);
    transform: translateY(-1px);
    box-shadow: 0 3px 0 rgba(0, 0, 0, 0.6), 0 0 8px rgba(0, 229, 255, 0.25);
  }

  .keycap:active, .keycap.flash {
    transform: translateY(2px);
    box-shadow: 0 0 0 transparent;
    background: var(--bg-card-active);
    border-color: var(--accent-cyan);
  }

  .keycap .sym {
    font-family: "SF Pro Text", -apple-system, sans-serif;
    font-size: 16px;
    font-weight: 700;
    line-height: 1;
    color: #ffffff;
    min-width: 14px;
    text-align: center;
  }

  .keycap .badge {
    font-family: ui-monospace, 'SF Mono', monospace;
    font-size: 10px;
    font-weight: 500;
    background: rgba(255, 255, 255, 0.07);
    color: var(--accent-cyan);
    border-radius: 3px;
    padding: 1px 4px;
    line-height: 1.2;
  }

  .keycap .opt {
    font-family: ui-monospace, 'SF Mono', monospace;
    font-size: 9px;
    font-weight: 600;
    color: #fbbf24;
    background: rgba(245, 158, 11, 0.12);
    border-radius: 3px;
    padding: 1px 4px;
    line-height: 1.2;
  }

  /* ── Editor ────────────────────────────────────────────────────────── */
  .editor-wrapper {
    flex: 1;
    display: flex;
    flex-direction: column;
    padding: 12px 14px;
    background: var(--bg-main);
    overflow: hidden;
  }

  #editor {
    flex: 1;
    width: 100%;
    background: #18181b;
    border: 1px solid var(--border);
    border-radius: 8px;
    color: #fafafa;
    font-family: 'SF Mono', Menlo, Monaco, Consolas, monospace;
    font-size: 18px;
    line-height: 1.6;
    padding: 14px 16px;
    outline: none;
    resize: none;
    transition: border-color 0.15s ease;
  }

  #editor:focus {
    border-color: #38bdf8;
    box-shadow: 0 0 0 2px rgba(56, 189, 248, 0.2);
  }

  #editor::placeholder {
    color: #52525b;
    font-size: 14px;
    line-height: 1.5;
  }

  /* ── Footer ────────────────────────────────────────────────────────── */
  .footer {
    background: #161619;
    border-top: 1px solid var(--border);
    padding: 9px 16px;
    display: flex;
    justify-content: space-between;
    align-items: center;
    font-size: 11px;
    color: var(--text-muted);
  }

  .footer-hints {
    display: flex;
    align-items: center;
    gap: 12px;
    flex-wrap: nowrap;
    overflow: hidden;
  }

  .footer-hint-item {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    white-space: nowrap;
  }

  .footer-hint-item kbd {
    font-family: ui-monospace, 'SF Mono', monospace;
    background: rgba(255, 255, 255, 0.08);
    border: 1px solid rgba(255, 255, 255, 0.12);
    padding: 1px 5px;
    border-radius: 4px;
    color: var(--accent-cyan);
    font-size: 10px;
    font-weight: 600;
  }

  .footer-stats {
    font-family: ui-monospace, 'SF Mono', monospace;
    font-size: 11px;
    color: #71717a;
    white-space: nowrap;
    margin-left: 16px;
    flex-shrink: 0;
  }

  /* ── Toast Notification ────────────────────────────────────────────── */
  .toast {
    position: fixed;
    bottom: 45px;
    right: 20px;
    background: #10b981;
    color: #ffffff;
    font-size: 12px;
    font-weight: 600;
    padding: 8px 16px;
    border-radius: 6px;
    box-shadow: 0 4px 14px rgba(0, 0, 0, 0.5);
    opacity: 0;
    transform: translateY(10px);
    transition: all 0.2s cubic-bezier(0.16, 1, 0.3, 1);
    pointer-events: none;
    z-index: 999;
  }

  .toast.show {
    opacity: 1;
    transform: translateY(0);
  }
</style>
</head>
<body>

  <!-- Header -->
  <div class="header">
    <div class="header-left">
      <span style="font-size: 15px;">⚡️</span>
      <span class="title">Logic Symbol Editor</span>
      <span class="hotkey-badge">⌃⌘L</span>
    </div>
    <div class="header-actions">
      <button class="btn btn-subtle" id="clearBtn" title="Clear Editor (⌘K)">Clear</button>
      <button class="btn btn-secondary" id="copyBtn" title="Copy to Clipboard (⌘C)">Copy ⌘C</button>
      <button class="btn btn-primary" id="pasteBtn" title="Copy & Paste into Active App (⌘↵)">Paste into App ⌘↵</button>
      <button class="btn btn-icon" id="closeBtn" title="Close (Esc)">✕</button>
    </div>
  </div>

  <!-- Cheat Sheet (Always-Visible Keycaps) -->
  <div class="cheat-sheet-container">
    <div class="cheat-sheet-header">
      <span>Always-Visible Cheat Sheet</span>
      <span class="cs-hint">Click keycap or type macro/shortcut</span>
    </div>

    <div class="groups-wrapper">
      <!-- Group 1: Connectives -->
      <div class="group-row">
        <span class="group-tag">Connectives</span>
        <div class="keycaps-grid">
          <button class="keycap" data-sym="¬" title="Negation (NOT) • Type: ~ or ! or \neg">
            <span class="sym">¬</span><span class="badge">~</span><span class="opt">⌥1</span>
          </button>
          <button class="keycap" data-sym="∧" title="Conjunction (AND) • Type: & or ^ or \and">
            <span class="sym">∧</span><span class="badge">&amp;</span><span class="opt">⌥2</span>
          </button>
          <button class="keycap" data-sym="∨" title="Disjunction (OR) • Type: | or \or">
            <span class="sym">∨</span><span class="badge">|</span><span class="opt">⌥3</span>
          </button>
          <button class="keycap" data-sym="→" title="Implication (IF-THEN) • Type: -> or =>">
            <span class="sym">→</span><span class="badge">-&gt;</span><span class="opt">⌥4</span>
          </button>
          <button class="keycap" data-sym="↔" title="Biconditional (IFF) • Type: <-> or <=>>">
            <span class="sym">↔</span><span class="badge">&lt;-&gt;</span><span class="opt">⌥5</span>
          </button>
          <button class="keycap" data-sym="⊕" title="Exclusive OR (XOR) • Type: (+) or \xor">
            <span class="sym">⊕</span><span class="badge">(+)</span><span class="opt">⌥6</span>
          </button>
        </div>
      </div>

      <!-- Group 2: Quantifiers & Proofs -->
      <div class="group-row">
        <span class="group-tag">Proofs / FO</span>
        <div class="keycaps-grid">
          <button class="keycap" data-sym="∀" title="Universal Quantifier (FOR ALL) • Type: \A or \forall">
            <span class="sym">∀</span><span class="badge">\A</span><span class="opt">⌥7</span>
          </button>
          <button class="keycap" data-sym="∃" title="Existential Quantifier (EXISTS) • Type: \E or \exists">
            <span class="sym">∃</span><span class="badge">\E</span><span class="opt">⌥8</span>
          </button>
          <button class="keycap" data-sym="⊢" title="Provable / Turnstile • Type: |-">
            <span class="sym">⊢</span><span class="badge">|-</span><span class="opt">⌥9</span>
          </button>
          <button class="keycap" data-sym="⊨" title="Models / Semantic Entailment • Type: |=">
            <span class="sym">⊨</span><span class="badge">|=</span><span class="opt">⌥0</span>
          </button>
          <button class="keycap" data-sym="⊥" title="Contradiction / Falsehood (Bottom) • Type: _|_ or \bot">
            <span class="sym">⊥</span><span class="badge">_|_</span><span class="opt">⌥-</span>
          </button>
          <button class="keycap" data-sym="⊤" title="Tautology / Truth (Top) • Type: \top">
            <span class="sym">⊤</span><span class="badge">\top</span><span class="opt">⌥=</span>
          </button>
          <button class="keycap" data-sym="∴" title="Therefore • Type: .: or ..">
            <span class="sym">∴</span><span class="badge">.:</span>
          </button>
          <button class="keycap" data-sym="∵" title="Because • Type: ::">
            <span class="sym">∵</span><span class="badge">::</span>
          </button>
        </div>
      </div>

      <!-- Group 3: Sets & Relations -->
      <div class="group-row">
        <span class="group-tag">Sets / Rel</span>
        <div class="keycaps-grid">
          <button class="keycap" data-sym="∈" title="Element Of • Type: \in">
            <span class="sym">∈</span><span class="badge">\in</span>
          </button>
          <button class="keycap" data-sym="∉" title="Not Element Of • Type: !in or \notin">
            <span class="sym">∉</span><span class="badge">!in</span>
          </button>
          <button class="keycap" data-sym="⊆" title="Subset or Equal • Type: sub= or \subseteq">
            <span class="sym">⊆</span><span class="badge">sub=</span>
          </button>
          <button class="keycap" data-sym="⊂" title="Proper Subset • Type: sub or \subset">
            <span class="sym">⊂</span><span class="badge">sub</span>
          </button>
          <button class="keycap" data-sym="∩" title="Intersection (Cap) • Type: cap or \cap">
            <span class="sym">∩</span><span class="badge">cap</span>
          </button>
          <button class="keycap" data-sym="∪" title="Union (Cup) • Type: cup or \cup">
            <span class="sym">∪</span><span class="badge">cup</span>
          </button>
          <button class="keycap" data-sym="∅" title="Empty Set • Type: \0 or \empty">
            <span class="sym">∅</span><span class="badge">\0</span>
          </button>
          <button class="keycap" data-sym="≠" title="Not Equal • Type: !=">
            <span class="sym">≠</span><span class="badge">!=</span>
          </button>
          <button class="keycap" data-sym="≡" title="Equivalent / Identical • Type: == or \equiv">
            <span class="sym">≡</span><span class="badge">==</span>
          </button>
          <button class="keycap" data-sym="≈" title="Approx / Isomorphic • Type: ~=">
            <span class="sym">≈</span><span class="badge">~=</span>
          </button>
        </div>
      </div>
    </div>
  </div>

  <!-- Text Editor -->
  <div class="editor-wrapper">
    <textarea id="editor" placeholder="Type logic formulas here...&#10;• Live typing macros: ~(P & Q) -> ~P | ~Q or \A x (P(x) -> Q(x))&#10;• Press ⌥1..0 for quick symbols • Press ⌘↵ to Paste into whatever app you were using!" autofocus></textarea>
  </div>

  <!-- Footer -->
  <div class="footer">
    <div class="footer-hints">
      <span class="footer-hint-item"><kbd>⌥1..0</kbd> Quick Symbols</span>
      <span class="footer-hint-item"><kbd>⌘↵</kbd> Paste into App</span>
      <span class="footer-hint-item"><kbd>⌘C</kbd> Copy</span>
      <span class="footer-hint-item"><kbd>⌘K</kbd> Clear</span>
      <span class="footer-hint-item"><kbd>Esc</kbd> Close</span>
    </div>
    <div class="footer-stats" id="stats">0 chars</div>
  </div>

  <div id="toast" class="toast">Copied to clipboard!</div>

  <script>
    const editor = document.getElementById('editor');
    const stats = document.getElementById('stats');
    const toast = document.getElementById('toast');

    // ── Macro Dictionary ──────────────────────────────────────────────
    // Sorted by trigger length descending so longest patterns match first.
    const macroMap = [
      { trigger: "<->", sym: "↔" },
      { trigger: "<=>", sym: "↔" },
      { trigger: "\\iff", sym: "↔" },
      { trigger: "->", sym: "→" },
      { trigger: "=>", sym: "→" },
      { trigger: "\\to", sym: "→" },
      { trigger: "\\imp", sym: "→" },
      { trigger: "\\forall", sym: "∀" },
      { trigger: "\\exists", sym: "∃" },
      { trigger: "\\neg", sym: "¬" },
      { trigger: "\\and", sym: "∧" },
      { trigger: "\\or", sym: "∨" },
      { trigger: "\\vdash", sym: "⊢" },
      { trigger: "\\models", sym: "⊨" },
      { trigger: "\\bot", sym: "⊥" },
      { trigger: "\\top", sym: "⊤" },
      { trigger: "\\therefore", sym: "∴" },
      { trigger: "\\because", sym: "∵" },
      { trigger: "\\notin", sym: "∉" },
      { trigger: "\\in", sym: "∈" },
      { trigger: "\\subseteq", sym: "⊆" },
      { trigger: "\\subset", sym: "⊂" },
      { trigger: "\\cap", sym: "∩" },
      { trigger: "\\cup", sym: "∪" },
      { trigger: "\\emptyset", sym: "∅" },
      { trigger: "\\empty", sym: "∅" },
      { trigger: "\\equiv", sym: "≡" },
      { trigger: "\\xor", sym: "⊕" },
      { trigger: "(+)", sym: "⊕" },
      { trigger: "_|_", sym: "⊥" },
      { trigger: "_∨_", sym: "⊥" },
      { trigger: "|-", sym: "⊢" },
      { trigger: "∨-", sym: "⊢" },
      { trigger: "|=", sym: "⊨" },
      { trigger: "∨=", sym: "⊨" },
      { trigger: "!=", sym: "≠" },
      { trigger: "==", sym: "≡" },
      { trigger: "~=", sym: "≈" },
      { trigger: ".:", sym: "∴" },
      { trigger: "..", sym: "∴" },
      { trigger: "::", sym: "∵" },
      { trigger: "!in", sym: "∉" },
      { trigger: "sub=", sym: "⊆" },
      { trigger: "sub", sym: "⊂" },
      { trigger: "cap", sym: "∩" },
      { trigger: "cup", sym: "∪" },
      { trigger: "\\A", sym: "∀" },
      { trigger: "\\E", sym: "∃" },
      { trigger: "\\0", sym: "∅" },
      { trigger: "~", sym: "¬" },
      { trigger: "&", sym: "∧" },
      { trigger: "^", sym: "∧" },
      { trigger: "|", sym: "∨" }
    ];
    macroMap.sort((a, b) => b.trigger.length - a.trigger.length);

    // ── Helper: Insert Symbol at Caret with Native Undo Support ───────
    function insertSymbol(sym) {
      editor.focus();
      document.execCommand('insertText', false, sym);
      updateStats();
    }

    // ── Helper: Check Macros on Input ────────────────────────────────
    function checkMacros() {
      const pos = editor.selectionStart;
      if (pos === null || editor.selectionEnd !== pos) return;
      const val = editor.value;

      for (const { trigger, sym } of macroMap) {
        const len = trigger.length;
        if (pos >= len && val.slice(pos - len, pos) === trigger) {
          editor.setSelectionRange(pos - len, pos);
          document.execCommand('insertText', false, sym);
          break;
        }
      }
    }

    function updateStats() {
      const len = editor.value.length;
      stats.textContent = len + (len === 1 ? ' char' : ' chars');
    }

    function showToast(msg) {
      toast.textContent = msg;
      toast.classList.add('show');
      setTimeout(() => toast.classList.remove('show'), 1500);
    }

    function postHammerspoon(action, payload) {
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.logicEditor) {
        window.webkit.messageHandlers.logicEditor.postMessage({
          action: action,
          text: editor.value,
          selectedText: editor.value.substring(editor.selectionStart, editor.selectionEnd) || editor.value,
          ...(payload || {})
        });
      }
    }

    function copyToClipboard() {
      const textToCopy = editor.value.substring(editor.selectionStart, editor.selectionEnd) || editor.value;
      if (!textToCopy) return;
      postHammerspoon('copy', { text: textToCopy });
      showToast('Copied to clipboard!');
    }

    function pasteToApp() {
      const textToPaste = editor.value.substring(editor.selectionStart, editor.selectionEnd) || editor.value;
      postHammerspoon('paste_to_app', { text: textToPaste });
    }

    function clearEditor() {
      editor.value = '';
      updateStats();
      editor.focus();
    }

    function closeWindow() {
      postHammerspoon('close');
    }

    // ── Event Listeners ──────────────────────────────────────────────
    editor.addEventListener('input', () => {
      checkMacros();
      updateStats();
    });

    editor.addEventListener('keydown', (e) => {
      // ⌥1..0, ⌥-, ⌥=
      if (e.altKey && !e.metaKey && !e.ctrlKey) {
        const codeMap = {
          'Digit1': '¬',
          'Digit2': '∧',
          'Digit3': '∨',
          'Digit4': '→',
          'Digit5': '↔',
          'Digit6': '⊕',
          'Digit7': '∀',
          'Digit8': '∃',
          'Digit9': '⊢',
          'Digit0': '⊨',
          'Minus': '⊥',
          'Equal': '⊤'
        };
        const sym = codeMap[e.code];
        if (sym) {
          e.preventDefault();
          insertSymbol(sym);
          return;
        }
      }

      // ⌘↵ -> Paste into active app
      if (e.metaKey && e.key === 'Enter') {
        e.preventDefault();
        pasteToApp();
        return;
      }

      // ⌘K -> Clear
      if (e.metaKey && (e.key === 'k' || e.key === 'K')) {
        e.preventDefault();
        clearEditor();
        return;
      }

      // Escape -> Close
      if (e.key === 'Escape') {
        e.preventDefault();
        closeWindow();
        return;
      }
    });

    // Keycap Clicks
    document.querySelectorAll('.keycap').forEach(btn => {
      btn.addEventListener('click', (e) => {
        e.preventDefault();
        const sym = btn.getAttribute('data-sym');
        if (sym) {
          insertSymbol(sym);
          btn.classList.add('flash');
          setTimeout(() => btn.classList.remove('flash'), 120);
        }
      });
    });

    // Buttons
    document.getElementById('pasteBtn').addEventListener('click', pasteToApp);
    document.getElementById('copyBtn').addEventListener('click', copyToClipboard);
    document.getElementById('clearBtn').addEventListener('click', clearEditor);
    document.getElementById('closeBtn').addEventListener('click', closeWindow);

    window.addEventListener('DOMContentLoaded', () => {
      editor.focus();
      updateStats();
    });
  </script>
</body>
</html>
]]

-- ── Window & Webview Management ──────────────────────────────────────────────────

local function getCenteredFrame()
  local screen = hs.screen.mainScreen():frame()
  local w = 840
  local h = 540
  local x = math.floor(screen.x + (screen.w - w) / 2)
  local y = math.floor(screen.y + (screen.h - h) / 3) -- Natural viewing height
  return { x = x, y = y, w = w, h = h }
end

local function handleWebviewMessage(msg)
  local data = msg.body
  if type(data) ~= "table" then return end

  local action = data.action
  local text = data.text or ""

  if action == "paste_to_app" then
    hs.pasteboard.setContents(text)
    M.hide()
    if M.previousApp and M.previousApp:isRunning() then
      M.previousApp:activate()
      hs.timer.doAfter(0.12, function()
        hs.eventtap.keyStroke({"cmd"}, "v", 0, M.previousApp)
      end)
    else
      hs.timer.doAfter(0.12, function()
        hs.eventtap.keyStroke({"cmd"}, "v")
      end)
    end
  elseif action == "copy" then
    hs.pasteboard.setContents(text)
  elseif action == "close" then
    M.hide()
    if M.previousApp and M.previousApp:isRunning() then
      M.previousApp:activate()
    end
  end
end

local function createWebview()
  if activeWatchers.logicEditorWebview then
    return activeWatchers.logicEditorWebview
  end

  local uc = hs.webview.usercontent.new("logicEditor")
  uc:setCallback(handleWebviewMessage)
  activeWatchers.logicEditorUC = uc

  local rect = getCenteredFrame()
  local wv = hs.webview.new(rect, { developerExtrasEnabled = true }, uc)
  wv:windowTitle("Logic Symbol Editor")
  wv:windowStyle({ "titled", "closable", "resizable", "utility" })
  wv:level(hs.canvas.windowLevels.floating)
  wv:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
  wv:html(HTML_CONTENT)

  wv:windowCallback(function(action, webview)
    if action == "closing" then
      activeWatchers.logicEditorWebview = nil
      M.isVisible = false
      if M.previousApp and M.previousApp:isRunning() then
        M.previousApp:activate()
      end
    end
  end)

  activeWatchers.logicEditorWebview = wv
  return wv
end

function M.show()
  local frontApp = hs.application.frontmostApplication()
  if frontApp and frontApp:bundleID() ~= "org.hammerspoon.Hammerspoon" then
    M.previousApp = frontApp
  end

  local wv = createWebview()
  wv:show()
  M.isVisible = true

  -- Focus editor input
  hs.timer.doAfter(0.05, function()
    wv:evaluateJavaScript("const el = document.getElementById('editor'); if (el) { el.focus(); el.select(); }")
  end)
end

function M.hide()
  if activeWatchers.logicEditorWebview then
    activeWatchers.logicEditorWebview:hide()
  end
  M.isVisible = false
end

function M.toggle()
  if M.isVisible and activeWatchers.logicEditorWebview then
    M.hide()
  else
    M.show()
  end
end

-- ── Lifecycle ───────────────────────────────────────────────────────────────────

function M.start()
  M.stop()

  -- Register global hotkey: Ctrl + Cmd + L
  activeWatchers.logicEditorHotkey = hs.hotkey.bind({"ctrl", "cmd"}, "L", function()
    M.toggle()
  end)

  log.i("Logic Editor module started (Hotkey: ⌃⌘L)")
end

function M.stop()
  if activeWatchers.logicEditorHotkey then
    activeWatchers.logicEditorHotkey:delete()
    activeWatchers.logicEditorHotkey = nil
  end

  if activeWatchers.logicEditorWebview then
    activeWatchers.logicEditorWebview:delete()
    activeWatchers.logicEditorWebview = nil
  end

  activeWatchers.logicEditorUC = nil
  M.isVisible = false
end

return M
