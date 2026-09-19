// Floating "Chat with Alice" website widget - a drop-in embed script backing the new
// chatbot-web-reply Edge Function (public/anonymous-callable twin of the real Facebook Messenger
// bot, see that function's header comment for the full architecture). Add
// `<script src="js/chatWidget.js" defer></script>` to any public page (after js/config.js) to get
// the floating bubble - it injects its own markup/CSS into the page, so no other per-page setup
// is needed.
//
// A visitor is identified by a random UUID generated once and kept in localStorage
// (rsps_chat_visitor_id) - NOT tied to any staff/customer login, since this widget is anonymous
// and public. The same id is what lets a returning visitor's conversation history be restored.
(function () {
  'use strict';

  if (window.__rspsChatWidgetLoaded) return;
  window.__rspsChatWidgetLoaded = true;

  const VISITOR_ID_KEY = 'rsps_chat_visitor_id';
  const GREETED_KEY = 'rsps_chat_greeted';

  function getVisitorId() {
    try {
      let id = localStorage.getItem(VISITOR_ID_KEY);
      if (!id) {
        id = crypto.randomUUID();
        localStorage.setItem(VISITOR_ID_KEY, id);
      }
      return id;
    } catch {
      // Private browsing / storage blocked - fall back to an in-memory id for this page view only.
      return crypto.randomUUID();
    }
  }

  function injectStyles() {
    const style = document.createElement('style');
    style.textContent = `
      .rsps-chat-launcher {
        position: fixed;
        right: 20px;
        bottom: 20px;
        width: 60px;
        height: 60px;
        border-radius: 50%;
        border: none;
        cursor: pointer;
        background: linear-gradient(135deg, #16e0bd, #1d4f91);
        box-shadow: 0 8px 24px rgba(21, 52, 94, 0.35);
        display: flex;
        align-items: center;
        justify-content: center;
        font-size: 26px;
        z-index: 99998;
        transition: transform 150ms ease;
      }
      .rsps-chat-launcher:hover { transform: scale(1.06); }
      .rsps-chat-panel {
        position: fixed;
        right: 20px;
        bottom: 92px;
        width: 340px;
        max-width: calc(100vw - 32px);
        height: 480px;
        max-height: calc(100vh - 140px);
        background: #ffffff;
        border-radius: 16px;
        box-shadow: 0 20px 50px rgba(0, 0, 0, 0.28);
        display: none;
        flex-direction: column;
        overflow: hidden;
        z-index: 99999;
        font-family: "Segoe UI", Tahoma, Geneva, Verdana, sans-serif;
      }
      .rsps-chat-panel.open { display: flex; }
      .rsps-chat-header {
        background: linear-gradient(135deg, #16e0bd, #1d4f91);
        color: #fff;
        padding: 14px 16px;
        display: flex;
        align-items: center;
        justify-content: space-between;
        flex: none;
      }
      .rsps-chat-header-title { font-weight: 700; font-size: 15px; }
      .rsps-chat-header-sub { font-size: 11px; opacity: 0.85; margin-top: 1px; }
      .rsps-chat-close {
        background: rgba(255, 255, 255, 0.18);
        border: none;
        color: #fff;
        width: 26px;
        height: 26px;
        border-radius: 50%;
        cursor: pointer;
        font-size: 14px;
        line-height: 1;
      }
      .rsps-chat-messages {
        flex: 1;
        overflow-y: auto;
        padding: 14px;
        display: flex;
        flex-direction: column;
        gap: 8px;
        background: #f4f7fb;
      }
      .rsps-chat-msg {
        max-width: 82%;
        padding: 8px 12px;
        border-radius: 14px;
        font-size: 13px;
        line-height: 1.4;
        white-space: pre-wrap;
        word-break: break-word;
      }
      .rsps-chat-msg-user {
        align-self: flex-end;
        background: #1d4f91;
        color: #fff;
        border-bottom-right-radius: 4px;
      }
      .rsps-chat-msg-assistant {
        align-self: flex-start;
        background: #ffffff;
        color: #1b355e;
        border: 1px solid #e2e8f4;
        border-bottom-left-radius: 4px;
      }
      .rsps-chat-msg-error {
        align-self: flex-start;
        background: #fff0f0;
        color: #8a2626;
        border: 1px solid #e0a8a8;
      }
      .rsps-chat-typing {
        align-self: flex-start;
        font-size: 12px;
        color: #6a7a93;
        padding: 2px 4px;
      }
      .rsps-chat-input-row {
        flex: none;
        display: flex;
        gap: 8px;
        padding: 10px;
        border-top: 1px solid #e2e8f4;
        background: #fff;
      }
      .rsps-chat-input {
        flex: 1;
        border: 1px solid #c7d3e6;
        border-radius: 20px;
        padding: 9px 14px;
        font-size: 13px;
        outline: none;
        min-width: 0;
      }
      .rsps-chat-send {
        border: none;
        background: #1d4f91;
        color: #fff;
        width: 36px;
        height: 36px;
        border-radius: 50%;
        cursor: pointer;
        font-size: 15px;
        flex: none;
      }
      .rsps-chat-send:disabled { opacity: 0.5; cursor: default; }
      @media (max-width: 420px) {
        .rsps-chat-panel { right: 12px; left: 12px; width: auto; bottom: 84px; }
        .rsps-chat-launcher { right: 14px; bottom: 14px; }
      }
    `;
    document.head.appendChild(style);
  }

  function buildMarkup() {
    const launcher = document.createElement('button');
    launcher.className = 'rsps-chat-launcher';
    launcher.setAttribute('aria-label', 'Chat with Alice');
    launcher.textContent = '\u{1F4AC}';

    const panel = document.createElement('div');
    panel.className = 'rsps-chat-panel';
    panel.innerHTML = `
      <div class="rsps-chat-header">
        <div>
          <div class="rsps-chat-header-title">Chat with Alice</div>
          <div class="rsps-chat-header-sub">RS Pet Stop's AI assistant</div>
        </div>
        <button type="button" class="rsps-chat-close" aria-label="Close chat">&times;</button>
      </div>
      <div class="rsps-chat-messages"></div>
      <div class="rsps-chat-input-row">
        <input type="text" class="rsps-chat-input" placeholder="Ask about products, orders, delivery..." maxlength="4000" />
        <button type="button" class="rsps-chat-send" aria-label="Send">&#10148;</button>
      </div>
    `;

    document.body.appendChild(launcher);
    document.body.appendChild(panel);
    return { launcher, panel };
  }

  function init() {
    if (!window.APP_CONFIG || !window.APP_CONFIG.SUPABASE_URL) {
      console.error('rsps chat widget: window.APP_CONFIG is missing - load js/config.js first.');
      return;
    }

    injectStyles();
    const { launcher, panel } = buildMarkup();
    const messagesEl = panel.querySelector('.rsps-chat-messages');
    const inputEl = panel.querySelector('.rsps-chat-input');
    const sendBtn = panel.querySelector('.rsps-chat-send');
    const closeBtn = panel.querySelector('.rsps-chat-close');
    const visitorId = getVisitorId();

    let historyLoaded = false;
    let sending = false;

    function appendMessage(role, text) {
      const bubble = document.createElement('div');
      bubble.className = `rsps-chat-msg rsps-chat-msg-${role}`;
      bubble.textContent = text;
      messagesEl.appendChild(bubble);
      messagesEl.scrollTop = messagesEl.scrollHeight;
      return bubble;
    }

    function showTyping() {
      const typing = document.createElement('div');
      typing.className = 'rsps-chat-typing';
      typing.textContent = 'Alice is typing...';
      messagesEl.appendChild(typing);
      messagesEl.scrollTop = messagesEl.scrollHeight;
      return typing;
    }

    async function callWidget(payload) {
      const response = await fetch(`${window.APP_CONFIG.SUPABASE_URL}/functions/v1/chatbot-web-reply`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${window.APP_CONFIG.SUPABASE_ANON_KEY}`,
          'apikey': window.APP_CONFIG.SUPABASE_ANON_KEY
        },
        body: JSON.stringify(payload)
      });
      const body = await response.json().catch(() => null);
      if (!response.ok) throw new Error(body?.error || `Request failed (${response.status}).`);
      return body;
    }

    async function loadHistory() {
      if (historyLoaded) return;
      historyLoaded = true;
      try {
        const body = await callWidget({ visitor_id: visitorId, action: 'history' });
        const rows = body?.messages || [];
        if (rows.length === 0) {
          let greeted = false;
          try { greeted = localStorage.getItem(GREETED_KEY) === '1'; } catch { /* ignore */ }
          appendMessage('assistant', "Hi, I'm Alice! \u{1F44B} Ask me anything about our aquariums, pet supplies, orders, or delivery.");
          if (!greeted) {
            try { localStorage.setItem(GREETED_KEY, '1'); } catch { /* ignore */ }
          }
          return;
        }
        rows.forEach((row) => {
          const role = row.Role === 'user' ? 'user' : 'assistant';
          appendMessage(role, row.Content);
        });
      } catch (err) {
        appendMessage('error', 'Could not load your previous conversation - you can still send a new message.');
      }
    }

    async function sendMessage() {
      const text = inputEl.value.trim();
      if (!text || sending) return;
      sending = true;
      sendBtn.disabled = true;
      inputEl.value = '';
      appendMessage('user', text);
      const typing = showTyping();
      try {
        const body = await callWidget({ visitor_id: visitorId, message: text });
        typing.remove();
        if (body?.paused) {
          appendMessage('assistant', "A team member is handling this conversation directly - they'll reply here shortly.");
        } else if (body?.reply) {
          appendMessage('assistant', body.reply);
        }
      } catch (err) {
        typing.remove();
        appendMessage('error', err instanceof Error ? err.message : 'Something went wrong - please try again.');
      } finally {
        sending = false;
        sendBtn.disabled = false;
        inputEl.focus();
      }
    }

    launcher.addEventListener('click', () => {
      panel.classList.toggle('open');
      if (panel.classList.contains('open')) {
        loadHistory();
        inputEl.focus();
      }
    });
    closeBtn.addEventListener('click', () => panel.classList.remove('open'));
    sendBtn.addEventListener('click', sendMessage);
    inputEl.addEventListener('keydown', (event) => {
      if (event.key === 'Enter') sendMessage();
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
