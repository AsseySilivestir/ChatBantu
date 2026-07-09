// ═══════════════════════════════════════════════════════════════
// ChatBantu v2 — Frontend API + Real-Time WebSocket Manager
// Zero polling. All real-time via WebSocket relay.
// ═══════════════════════════════════════════════════════════════

const api = {
  base: '',

  token() {
    return localStorage.getItem('cb_token') || '';
  },

  user() {
    try {
      return JSON.parse(localStorage.getItem('cb_user') || 'null');
    } catch (e) { return null; }
  },

  setSession(token, user) {
    localStorage.setItem('cb_token', token);
    localStorage.setItem('cb_user', JSON.stringify(user));
  },

  clearSession() {
    localStorage.removeItem('cb_token');
    localStorage.removeItem('cb_user');
  },

  async request(method, path, body) {
    const headers = { 'Content-Type': 'application/json' };
    const tok = this.token();
    if (tok) headers['Authorization'] = 'Bearer ' + tok;
    const opts = { method, headers };
    if (body !== undefined && body !== null) {
      opts.body = JSON.stringify(body);
    }
    let res;
    try {
      res = await fetch(this.base + path, opts);
    } catch (e) {
      throw new Error('Network error: ' + e.message);
    }
    let data = null;
    const ct = res.headers.get('Content-Type') || '';
    if (ct.indexOf('json') !== -1) {
      data = await res.json();
    } else {
      data = await res.text();
    }
    if (res.status === 401) {
      this.clearSession();
      if (!window.location.pathname.endsWith('index.html') && !window.location.pathname.endsWith('/')) {
        window.location.href = '/';
      }
    }
    return data;
  },

  get(path)  { return this.request('GET',  path); },
  post(path, body) { return this.request('POST', path, body); },
  put(path, body)  { return this.request('PUT',  path, body); },
  del(path)        { return this.request('DELETE', path); },
};

// ═══════════════════════════════════════════════════════════════
//  REAL-TIME WEBSOCKET MANAGER
//  Connects to wsrelay on the same host, port 8081.
//  Dispatches: message, call_offer, call_answer, call_ice,
//              call_hangup, presence, notification, typing
// ═══════════════════════════════════════════════════════════════

const WS = {
  _ws: null,
  _reconnectTimer: null,
  _listeners: {},       // { eventType: [callback, ...] }
  _onlineUsers: {},     // { userId: { id, username, displayName } }
  _connected: false,
  _relayPort: 8081,

  // ── Connect ──────────────────────────────────────────────
  connect() {
    if (!api.token()) return;
    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    const url = proto + '//' + location.hostname + ':' + this._relayPort + '/ws?token=' + encodeURIComponent(api.token());
    this._ws = new WebSocket(url);

    this._ws.onopen = () => {
      console.log('[WS] Connected to relay');
      this._connected = true;
      this._emit('connected', {});
      // Clear any reconnect timer
      if (this._reconnectTimer) { clearTimeout(this._reconnectTimer); this._reconnectTimer = null; }
    };

    this._ws.onmessage = (evt) => {
      try {
        const msg = JSON.parse(evt.data);
        this._dispatch(msg);
      } catch (e) {
        console.warn('[WS] Parse error:', e);
      }
    };

    this._ws.onclose = () => {
      console.log('[WS] Disconnected');
      this._connected = false;
      this._onlineUsers = {};
      this._emit('disconnected', {});
      // Reconnect after 2s
      this._reconnectTimer = setTimeout(() => this.connect(), 2000);
    };

    this._ws.onerror = (err) => {
      console.warn('[WS] Error', err);
    };
  },

  disconnect() {
    if (this._reconnectTimer) { clearTimeout(this._reconnectTimer); this._reconnectTimer = null; }
    if (this._ws) { try { this._ws.close(); } catch(e) {} this._ws = null; }
    this._connected = false;
  },

  // ── Send a message through the WebSocket ────────────────
  send(to, type, data) {
    if (!this._ws || this._ws.readyState !== WebSocket.OPEN) return false;
    const payload = { to, type, data };
    this._ws.send(JSON.stringify(payload));
    return true;
  },

  // ── Event system ─────────────────────────────────────────
  on(event, callback) {
    if (!this._listeners[event]) this._listeners[event] = [];
    this._listeners[event].push(callback);
  },

  off(event, callback) {
    if (!this._listeners[event]) return;
    this._listeners[event] = this._listeners[event].filter(cb => cb !== callback);
  },

  _emit(event, data) {
    (this._listeners[event] || []).forEach(cb => {
      try { cb(data); } catch (e) { console.warn('[WS] Handler error:', e); }
    });
  },

  // ── Internal dispatch ────────────────────────────────────
  _dispatch(msg) {
    switch (msg.type) {
      case 'connected':
        // Welcome message from relay — we're authenticated
        break;

      case 'presence':
        // Full online user list broadcast
        this._onlineUsers = {};
        if (msg.online) {
          msg.online.forEach(u => { this._onlineUsers[u.id] = u; });
        }
        this._emit('presence', msg);
        break;

      case 'message':
        // Real-time chat message from another user
        this._emit('message', msg);
        break;

      case 'call_offer':
        // Incoming WebRTC call offer
        this._emit('call_offer', msg);
        break;

      case 'call_answer':
        // WebRTC answer from callee
        this._emit('call_answer', msg);
        break;

      case 'call_ice':
        // ICE candidate from peer
        this._emit('call_ice', msg);
        break;

      case 'call_hangup':
        // Peer ended the call
        this._emit('call_hangup', msg);
        break;

      default:
        console.log('[WS] Unknown type:', msg.type, msg);
    }
  },

  isConnected() {
    return this._connected;
  },

  isUserOnline(userId) {
    return !!this._onlineUsers[userId];
  },

  getOnlineUsers() {
    return Object.values(this._onlineUsers);
  }
};

// ─── Utilities ──────────────────────────────────────────────

function avatarLetter(name) {
  if (!name) return '?';
  return name.trim().charAt(0).toUpperCase();
}

function timeAgo(iso) {
  if (!iso) return '';
  const d = new Date(iso.endsWith('Z') ? iso : iso.replace(' ', 'T') + 'Z');
  const now = new Date();
  const diff = Math.floor((now - d) / 1000);
  if (diff < 60)    return 'just now';
  if (diff < 3600)  return Math.floor(diff / 60) + 'm ago';
  if (diff < 86400) return Math.floor(diff / 3600) + 'h ago';
  if (diff < 604800) return Math.floor(diff / 86400) + 'd ago';
  return d.toLocaleDateString();
}

function toast(message, ms = 3000) {
  const el = document.createElement('div');
  el.className = 'toast';
  el.textContent = message;
  document.body.appendChild(el);
  setTimeout(() => el.remove(), ms);
}

function requireAuth() {
  if (!api.token()) {
    window.location.href = '/';
    return false;
  }
  return true;
}

// Inject sidebar into any page that has <div id="sidebar"></div>
function renderSidebar(active) {
  const el = document.getElementById('sidebar');
  if (!el) return;
  const u = api.user() || { displayName: '?', username: '' };
  el.innerHTML = `
    <div class="brand"><span class="logo">💬</span> ChatBantu</div>
    <div class="nav-item ${active === 'feed' ? 'active' : ''}" onclick="location.href='/feed.html'">
      <span class="icon">📰</span><span>Feed</span>
    </div>
    <div class="nav-item ${active === 'chat' ? 'active' : ''}" onclick="location.href='/chat.html'">
      <span class="icon">💬</span><span>Messages</span>
      <span class="badge" id="nav-unread">0</span>
    </div>
    <div class="nav-item ${active === 'people' ? 'active' : ''}" onclick="location.href='/people.html'">
      <span class="icon">👥</span><span>People</span>
    </div>
    <div class="nav-item ${active === 'notifications' ? 'active' : ''}" onclick="location.href='/notifications.html'">
      <span class="icon">🔔</span><span>Notifications</span>
      <span class="badge" id="nav-notif">0</span>
    </div>
    <div class="me">
      <div class="avatar">${avatarLetter(u.displayName)}</div>
      <div class="info">
        <div class="name">${escapeHtml(u.displayName || '')}</div>
        <div class="uname">@${escapeHtml(u.username || '')}</div>
      </div>
      <button class="logout" title="Sign out" onclick="doLogout()">⏻</button>
    </div>
  `;

  // Real-time unread badge updates via WebSocket
  WS.on('message', () => refreshBadges());

  refreshBadges();
}

async function refreshBadges() {
  try {
    const r = await api.get('/api/unread');
    if (r && !r.error) {
      const m = document.getElementById('nav-unread');
      const n = document.getElementById('nav-notif');
      if (m) m.textContent = r.unreadMessages > 0 ? r.unreadMessages : '';
      if (n) n.textContent = r.unreadNotifications > 0 ? r.unreadNotifications : '';
    }
  } catch (e) { /* ignore */ }
}

function doLogout() {
  WS.disconnect();
  api.clearSession();
  window.location.href = '/';
}

function escapeHtml(s) {
  if (s == null) return '';
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

// ─── Global WebSocket Init ──────────────────────────────────
// Every authenticated page connects to the relay on load.
if (api.token()) {
  WS.connect();
}

// Cleanup on unload
window.addEventListener('beforeunload', () => {
  WS.disconnect();
});