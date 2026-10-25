/* PolarBear Web — vanilla ES2020, no dependencies, same-origin API only. */
'use strict';

(function () {
  const RESUME_KEY = 'polarbear-resume';
  const PAGE_SIZE = 100;

  const $ = (sel, root) => (root || document).querySelector(sel);
  const $$ = (sel, root) => Array.from((root || document).querySelectorAll(sel));

  const esc = (value) => {
    if (value === null || value === undefined) return '';
    return String(value).replace(/[&<>"']/g, (ch) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
    })[ch]);
  };

  /* ---------------- formatting ---------------- */

  function fmtDuration(seconds) {
    if (seconds === null || seconds === undefined || !isFinite(seconds) || seconds < 0) return '--:--';
    const total = Math.floor(seconds);
    const h = Math.floor(total / 3600);
    const m = Math.floor((total % 3600) / 60);
    const s = total % 60;
    const pad = (n) => String(n).padStart(2, '0');
    return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${m}:${pad(s)}`;
  }

  function fmtClock(ms) {
    if (!isFinite(ms)) return '--:--';
    return fmtDuration(ms / 1000);
  }

  function fmtBytes(bytes) {
    if (bytes === null || bytes === undefined || !isFinite(bytes) || bytes <= 0) return null;
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    let i = 0;
    let n = bytes;
    while (n >= 1024 && i < units.length - 1) { n /= 1024; i += 1; }
    return `${n >= 100 || i === 0 ? n.toFixed(0) : n.toFixed(1)} ${units[i]}`;
  }

  function fmtDateTime(value) {
    if (!value) return null;
    const date = typeof value === 'number' ? new Date(value < 1e11 ? value * 1000 : value) : new Date(value);
    if (Number.isNaN(date.getTime())) return String(value);
    const diff = Date.now() - date.getTime();
    if (diff < 60000) return '刚刚';
    if (diff < 3600000) return `${Math.floor(diff / 60000)} 分钟前`;
    if (diff < 86400000) return `${Math.floor(diff / 3600000)} 小时前`;
    if (diff < 604800000) return `${Math.floor(diff / 86480000)} 天前`;
    return date.toLocaleString('zh-CN', {
      year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit'
    });
  }

  /* ---------------- state ---------------- */

  const state = {
    status: null,
    folders: [],
    collectionCache: new Map(),
    trackCache: new Map(),
    resume: {},
    route: { name: 'library', folderId: '', id: '', query: '' },
    renderToken: 0,
    retry: null,
    tracks: { id: '', page: 0, items: [], total: 0, loading: false },
    player: { track: null, subtitle: '', source: '', playing: false, pendingResume: null, scrubbing: false },
    coverUrls: new Map(),
    lastSearch: null
  };

  const audio = $('#audio');

  /* ---------------- api ---------------- */

  class ApiError extends Error {
    constructor(message, status, code) {
      super(message);
      this.name = 'ApiError';
      this.status = status;
      this.code = code;
    }
  }

  function buildUrl(path, params) {
    const search = new URLSearchParams();
    if (params) {
      Object.keys(params).forEach((key) => {
        const value = params[key];
        if (value !== undefined && value !== null && value !== '') search.set(key, String(value));
      });
    }
    const query = search.toString();
    return query ? `${path}?${query}` : path;
  }

  function apiGet(path, params) {
    const url = buildUrl(path, params);
    return fetch(url, {
      method: 'GET',
      headers: { Accept: 'application/json' },
      cache: 'no-store'
    }).then(async (res) => {
      if (!res.ok) {
        let message = `请求失败（HTTP ${res.status}）`;
        let code = 'HTTP_ERROR';
        try {
          const body = await res.json();
          const payload = body && (body.error || body.detail || body);
          if (payload && payload.message) message = String(payload.message);
          if (payload && payload.code) code = String(payload.code);
        } catch (err) { /* non-JSON error body */ }
        throw new ApiError(message, res.status, code);
      }
      return res.json();
    }, () => {
      throw new ApiError('无法连接到服务器，请检查网络或服务是否在运行。', 0, 'NETWORK');
    });
  }

  /* ---------------- local storage ---------------- */

  function loadResume() {
    try {
      const raw = localStorage.getItem(RESUME_KEY);
      const parsed = raw ? JSON.parse(raw) : {};
      return parsed && typeof parsed === 'object' ? parsed : {};
    } catch (err) {
      return {};
    }
  }

  function persistResume() {
    try { localStorage.setItem(RESUME_KEY, JSON.stringify(state.resume)); } catch (err) { /* ignore */ }
  }

  function rememberPosition(trackId, position, duration) {
    if (!trackId) return;
    const prev = state.resume[trackId] || {};
    state.resume[trackId] = {
      position: Math.max(0, Math.floor(position || 0)),
      duration: duration || prev.duration || null,
      updatedAt: Date.now()
    };
    persistResume();
  }

  function savedPosition(trackId) {
    const entry = state.resume[trackId];
    if (!entry) return 0;
    const pos = Number(entry.position) || 0;
    const dur = Number(entry.duration) || 0;
    if (dur > 0 && pos >= dur - 5) return 0; // 已听完 → 从头开始
    return pos;
  }

  /* ---------------- routing ---------------- */

  function parseRoute() {
    const hash = (location.hash || '').replace(/^#/, '');
    const [pathPart, queryPart] = hash.split('?');
    const segments = pathPart.split('/').filter(Boolean);
    const query = queryPart ? new URLSearchParams(queryPart).get('q') || '' : '';
    const base = { folderId: '', id: '', query };
    if (!segments.length) return { name: 'library', ...base };
    if (segments[0] === 'library') {
      const folderId = segments[1] === 'folder' ? (segments[2] || '') : (segments[1] || '');
      return { name: 'library', folderId, id: '', query };
    }
    if (segments[0] === 'collection') return { name: 'collection', folderId: '', id: segments[1] || '', query };
    if (segments[0] === 'continue') return { name: 'continue', ...base };
    if (segments[0] === 'favorites') return { name: 'favorites', ...base };
    if (segments[0] === 'archived') return { name: 'archived', ...base };
    if (segments[0] === 'search') return { name: 'search', ...base };
    if (segments[0] === 'track') return { name: 'track', folderId: '', id: segments[1] || '', query };
    return { name: 'library', ...base };
  }

  function navigate(hash) {
    if (location.hash === hash) renderRoute();
    else location.hash = hash;
  }

  window.addEventListener('hashchange', () => {
    closeDrawer();
    renderRoute();
  });

  /* ---------------- drawer ---------------- */

  const scrim = $('#scrim');
  const menuButton = $('#menu-button');

  function openDrawer() {
    app.classList.add('drawer-open');
    scrim.hidden = false;
    menuButton.setAttribute('aria-expanded', 'true');
    document.body.classList.add('no-scroll');
  }

  function closeDrawer() {
    app.classList.remove('drawer-open');
    scrim.hidden = true;
    menuButton.setAttribute('aria-expanded', 'false');
    document.body.classList.remove('no-scroll');
  }

  menuButton.addEventListener('click', () => {
    if (app.classList.contains('drawer-open')) closeDrawer();
    else openDrawer();
  });
  $('#drawer-close').addEventListener('click', closeDrawer);
  scrim.addEventListener('click', closeDrawer);
  document.addEventListener('keydown', (event) => {
    if (event.key !== 'Escape') return;
    if (!$('#modal-root').hidden) { closeModal(); return; }
    closeDrawer();
  });

  /* ---------------- sidebar ---------------- */

  function folderName(folderId) {
    const folder = state.folders.find((item) => item.id === folderId);
    return folder ? folder.name : '';
  }

  function renderSidebar() {
    const list = $('#folder-list');
    const count = $('#folder-count');
    count.textContent = state.folders.length ? `${state.folders.length} 个` : '';
    const parts = [];
    const allActive = state.route.name === 'library' && !state.route.folderId;
    parts.push(`<button class="folder-item ${allActive ? 'active' : ''}" type="button" data-action="nav" data-href="#/library">
      <span class="folder-dot" style="background:#7f8896"></span><span class="name">全部合集</span></button>`);
    state.folders.forEach((folder) => {
      const active = state.route.name === 'library' && state.route.folderId === folder.id;
      parts.push(`<button class="folder-item ${active ? 'active' : ''}" type="button" data-action="nav" data-href="#/library/folder/${encodeURIComponent(folder.id)}">
        <span class="folder-dot"></span><span class="name">${esc(folder.name)}</span></button>`);
    });
    const hasUnfiled = Array.from(state.collectionCache.values()).some((item) => !item.folderId);
    if (hasUnfiled) {
      const active = state.route.name === 'library' && state.route.folderId === '__other__';
      parts.push(`<button class="folder-item ${active ? 'active' : ''}" type="button" data-action="nav" data-href="#/library/folder/__other__">
        <span class="folder-dot" style="background:#9e8a5b"></span><span class="name">未分类</span></button>`);
    }
    list.innerHTML = parts.join('');
  }

  function updateNavActive() {
    $$('.nav-item').forEach((item) => {
      const route = item.dataset.route.replace('#/', '');
      const name = route.split('/')[0];
      item.classList.toggle('active', name === state.route.name);
    });
  }

  /* ---------------- status strip ---------------- */

  function renderStatus() {
    const strip = $('#status-strip');
    const status = state.status;
    if (!status) {
      strip.innerHTML = '<span>状态未知</span>';
      return;
    }
    const bits = [];
    bits.push(status.dbReady ? '<span class="ok">书库就绪</span>' : '<span class="bad">书库未就绪</span>');
    bits.push(`<span>${Number(status.collections) || 0} 个合集</span>`);
    bits.push(`<span>${Number(status.tracks) || 0} 个曲目</span>`);
    const snapshot = fmtDateTime(status.snapshotTime);
    if (snapshot) bits.push(`<span>快照 ${esc(snapshot)}</span>`);
    if (status.error) bits.push(`<span class="bad">${esc(status.error)}</span>`);
    strip.innerHTML = bits.join('');
  }

  async function loadStatus() {
    try {
      state.status = await apiGet('/v1/library/status');
    } catch (err) {
      state.status = { dbReady: false, snapshotTime: null, sourceMtime: null, tracks: 0, collections: 0, error: err.message };
    }
    renderStatus();
  }

  /* ---------------- covers ---------------- */

  function coverHtml(collection) {
    if (!collection || !collection.id) return '<div class="cover cover-placeholder">🐻</div>';
    return `<div class="cover cover-placeholder" data-cover="${esc(collection.id)}" data-cover-title="${esc(collection.title || '封面')}">🐻</div>`;
  }

  function replaceCover(node, url, title) {
    if (!node.parentNode) return;
    const img = document.createElement('img');
    img.className = 'cover';
    img.alt = title || '封面';
    img.decoding = 'async';
    img.src = url;
    node.parentNode.replaceChild(img, node);
  }

  function fallbackCover(node, id, title) {
    if (!node.parentNode) return;
    const img = document.createElement('img');
    img.className = 'cover';
    img.alt = title || '封面';
    img.decoding = 'async';
    img.addEventListener('error', () => {
      if (img.parentNode) img.parentNode.replaceChild(node, img);
    }, { once: true });
    img.src = `/v1/library/covers/${encodeURIComponent(id)}`;
    node.parentNode.replaceChild(img, node);
  }

  /* Covers are plain same-origin GETs, so a plain <img src> works. */
  async function loadCover(node) {
    const id = node.dataset.cover;
    const title = node.dataset.coverTitle || '封面';
    const cached = state.coverUrls.get(id);
    if (cached) { replaceCover(node, cached, title); return; }
    try {
      const res = await fetch(`/v1/library/covers/${encodeURIComponent(id)}`, { cache: 'no-store' });
      if (!res.ok) throw new Error(String(res.status));
      const type = res.headers.get('content-type') || '';
      if (type && !type.startsWith('image/')) throw new Error('unexpected content type');
      const blob = await res.blob();
      const url = URL.createObjectURL(blob);
      const previous = state.coverUrls.get(id);
      state.coverUrls.set(id, url);
      if (previous) URL.revokeObjectURL(previous);
      replaceCover(node, url, title);
    } catch (err) {
      fallbackCover(node, id, title);
    }
  }

  function hydrateCovers(root) {
    $$('[data-cover]', root).forEach((node) => { loadCover(node); });
  }

  /* ---------------- shared templates ---------------- */

  function loadingHtml(label) {
    return `<div class="state"><p>${esc(label || '加载中…')}</p></div>`;
  }

  function emptyHtml(title, hint) {
    return `<div class="state"><h2>${esc(title)}</h2>${hint ? `<p>${esc(hint)}</p>` : ''}</div>`;
  }

  function errorBoxHtml(err) {
    const message = err && err.message ? err.message : '未知错误';
    return `<div class="error-box"><strong>加载失败</strong><p>${esc(message)}</p>
      <button class="btn" type="button" data-action="retry">重试</button></div>`;
  }

  function collectionCardHtml(collection) {
    const pct = Math.round((collection.progress || 0) * 100);
    const meta = [`${Number(collection.trackCount) || 0} 曲目`];
    if (collection.listenedCount) meta.push(`已听 ${collection.listenedCount}`);
    if (pct > 0) meta.push(`${pct}%`);
    return `<button class="card" type="button" data-action="collection" data-id="${esc(collection.id)}">
      ${coverHtml(collection)}
      <div class="card-body">
        <h3>${esc(collection.title)}</h3>
        <p class="author">${esc(collection.author || '未知作者')}</p>
        <div class="card-meta">${meta.map((item) => `<span>${esc(item)}</span>`).join('')}</div>
        ${pct > 0 ? `<div class="progress"><i style="width:${pct}%"></i></div>` : ''}
      </div>
    </button>`;
  }

  function trackProgressPct(track) {
    const playback = track && track.playback;
    if (!playback || !playback.duration) return 0;
    return Math.max(0, Math.min(100, (Number(playback.position) || 0) / playback.duration * 100));
  }

  function trackRowHtml(track, subtitle) {
    const pct = trackProgressPct(track);
    const isText = track.locationType === 'text' || track.locationType === 'cachedText';
    const label = track.displayName || track.filename || '未命名曲目';
    const sub = subtitle || track.chapter || track.filename || '';
    return `<div class="track-row ${track.isArchived ? 'archived' : ''}" data-track-id="${esc(track.id)}">
      <button class="play-btn ${isText ? 'text' : ''}" type="button" data-action="play" data-id="${esc(track.id)}"
        aria-label="${isText ? '阅读' : '播放'} ${esc(label)}" title="${isText ? '阅读文本' : '播放'}">${isText ? '▤' : '▶'}</button>
      <div class="track-info">
        <strong>${esc(label)}</strong>
        ${sub ? `<small>${esc(sub)}</small>` : ''}
        ${pct > 0 ? `<div class="progress"><i style="width:${pct.toFixed(1)}%"></i></div>` : ''}
      </div>
      <div class="track-side">
        ${track.isFavorite ? '<span class="star-btn on" title="已收藏" aria-label="已收藏">★</span>' : '<span class="star-btn" title="未收藏" aria-label="未收藏">☆</span>'}
        ${track.isArchived ? '<span class="badge archived">已归档</span>' : ''}
        <span class="track-duration">${fmtDuration(track.duration)}</span>
        <button class="icon-btn info-btn" type="button" data-action="track" data-id="${esc(track.id)}" aria-label="查看曲目详情" title="曲目详情">ⓘ</button>
      </div>
    </div>`;
  }

  function locationLabel(type) {
    const labels = { baidu: '百度网盘', external: '网络链接', text: '文本', cachedText: '缓存文本', local: '本地文件' };
    return labels[type] || type || '未知来源';
  }

  function mediaLabel(kind) {
    const labels = { audio: '音频', video: '视频' };
    return labels[kind] || kind || '未知';
  }

  /* ---------------- views ---------------- */

  const views = {};

  /* Views capture the current render token and bail out when a newer route
     took over, so a slow response can never overwrite a fresher view. */
  function stale(token) {
    return token !== state.renderToken;
  }

  views.library = async function (route) {
    const token = state.renderToken;
    const root = $('#view-root');
    root.innerHTML = loadingHtml('正在加载书库…');
    let collections = await apiGet('/v1/library/collections', { includeArchived: 0 });
    if (stale(token)) return;
    if (route.folderId === '__other__') {
      collections = collections.filter((item) => !item.folderId);
    } else if (route.folderId) {
      collections = collections.filter((item) => item.folderId === route.folderId);
    }
    collections.forEach((item) => state.collectionCache.set(item.id, item));
    const title = route.folderId === '__other__' ? '未分类' : (folderName(route.folderId) || '书库');
    const subtitle = route.folderId ? `${collections.length} 个合集` : `${collections.length} 个合集 · 共 ${Number(state.status && state.status.tracks) || 0} 个曲目`;
    root.innerHTML = `<div class="heading"><h1>${esc(title)}</h1><p>${esc(subtitle)}</p></div>` +
      (collections.length
        ? `<div class="grid">${collections.map(collectionCardHtml).join('')}</div>`
        : emptyHtml('暂无合集', '这个位置还没有可浏览的有声书。'));
    hydrateCovers(root);
    renderSidebar();
  };

  views.collection = async function (route) {
    const token = state.renderToken;
    const root = $('#view-root');
    root.innerHTML = loadingHtml('正在加载合集…');
    let collection = state.collectionCache.get(route.id);
    if (!collection) {
      const all = await apiGet('/v1/library/collections', { includeArchived: 1 });
      if (stale(token)) return;
      all.forEach((item) => state.collectionCache.set(item.id, item));
      collection = state.collectionCache.get(route.id) || null;
    }
    const page = await apiGet(`/v1/library/collections/${encodeURIComponent(route.id)}/tracks`, {
      page: 0, pageSize: PAGE_SIZE, includeArchived: 1
    });
    if (stale(token)) return;
    const tracks = (page.tracks || []).map(cacheTrack);
    state.tracks = { id: route.id, page: 0, items: tracks, total: page.total || tracks.length, loading: false };
    const title = collection ? collection.title : '合集';
    root.innerHTML = `
      <button class="back" type="button" data-action="nav" data-href="#/library">‹ 返回书库</button>
      <div class="detail-head">
        ${coverHtml(collection)}
        <div class="detail-head-text">
          <h1>${esc(title)}</h1>
          <p class="detail-sub">${esc(collection ? (collection.author || '未知作者') : '')}${collection ? ` · ${collection.trackCount} 曲目` : ''}</p>
          ${collection && collection.description ? `<p class="detail-sub">${esc(collection.description)}</p>` : ''}
        </div>
      </div>
      <div id="track-list" class="track-list">${tracks.length ? tracks.map((track) => trackRowHtml(track)).join('') : emptyHtml('这个合集没有曲目')}</div>
      <div id="track-more"></div>`;
    hydrateCovers(root);
    renderMoreTracks();
  };

  function cacheTrack(track) {
    state.trackCache.set(track.id, track);
    return track;
  }

  function renderMoreTracks() {
    const host = $('#track-more');
    if (!host) return;
    const loaded = state.tracks.items.length;
    if (loaded >= state.tracks.total) { host.innerHTML = ''; return; }
    host.innerHTML = `<button class="btn" type="button" data-action="more-tracks" style="margin-top:14px">加载更多（${loaded}/${state.tracks.total}）</button>`;
  }

  async function loadMoreTracks() {
    if (state.tracks.loading || !state.tracks.id) return;
    state.tracks.loading = true;
    const nextPage = state.tracks.page + 1;
    try {
      const page = await apiGet(`/v1/library/collections/${encodeURIComponent(state.tracks.id)}/tracks`, {
        page: nextPage, pageSize: PAGE_SIZE, includeArchived: 1
      });
      const more = (page.tracks || []).map(cacheTrack);
      state.tracks.page = nextPage;
      state.tracks.items = state.tracks.items.concat(more);
      const list = $('#track-list');
      if (list) list.insertAdjacentHTML('beforeend', more.map((track) => trackRowHtml(track)).join(''));
      renderMoreTracks();
    } catch (err) {
      showNotice('加载更多失败：' + err.message);
    } finally {
      state.tracks.loading = false;
    }
  }

  views.continue = async function () {
    const token = state.renderToken;
    const root = $('#view-root');
    root.innerHTML = loadingHtml('正在加载继续收听…');
    const items = await apiGet('/v1/library/tracks/continue', { limit: 50 });
    if (stale(token)) return;
    const tracks = (items || []).map(cacheTrack);
    root.innerHTML = `<div class="heading"><h1>继续收听</h1><p>${tracks.length} 个未听完的曲目</p></div>` +
      (tracks.length
        ? `<div class="track-list">${tracks.map((track) => trackRowHtml(track, track.collectionTitle)).join('')}</div>`
        : emptyHtml('还没有播放记录', '播放过的曲目会出现在这里。'));
  };

  views.favorites = async function () {
    const token = state.renderToken;
    const root = $('#view-root');
    root.innerHTML = loadingHtml('正在加载收藏…');
    const items = await apiGet('/v1/library/tracks/favorites', { limit: 200 });
    if (stale(token)) return;
    const tracks = (items || []).map(cacheTrack);
    root.innerHTML = `<div class="heading"><h1>收藏</h1><p>${tracks.length} 个收藏曲目</p></div>` +
      (tracks.length
        ? `<div class="track-list">${tracks.map((track) => trackRowHtml(track)).join('')}</div>`
        : emptyHtml('还没有收藏的曲目'));
  };

  views.archived = async function () {
    const token = state.renderToken;
    const root = $('#view-root');
    root.innerHTML = loadingHtml('正在加载归档…');
    const all = await apiGet('/v1/library/collections', { includeArchived: 1 });
    if (stale(token)) return;
    all.forEach((item) => state.collectionCache.set(item.id, item));
    const archived = all.filter((item) => item.isArchived);
    root.innerHTML = `<div class="heading"><h1>归档</h1><p>${archived.length} 个已归档合集</p></div>` +
      (archived.length
        ? `<div class="grid">${archived.map(collectionCardHtml).join('')}</div>`
        : emptyHtml('没有归档内容', '归档的合集会显示在这里。'));
    hydrateCovers(root);
    renderSidebar();
  };

  views.search = async function (route) {
    const token = state.renderToken;
    const root = $('#view-root');
    const query = (route.query || '').trim();
    if (state.lastSearch !== query) {
      state.lastSearch = query;
      $('#search-input').value = query;
    }
    if (!query) {
      root.innerHTML = `<div class="heading"><h1>搜索</h1><p>输入合集、作者或曲目名称</p></div>`;
      return;
    }
    root.innerHTML = loadingHtml('正在搜索…');
    const results = await apiGet('/v1/library/search', { q: query, limit: 100 });
    if (stale(token)) return;
    const collections = [];
    const tracks = [];
    (results || []).forEach((item) => {
      if (!item) return;
      if (item.type === 'collection') { state.collectionCache.set(item.data.id, item.data); collections.push(item.data); }
      else if (item.type === 'track') tracks.push(cacheTrack(item.data));
    });
    root.innerHTML = `<div class="heading"><h1>“${esc(query)}”</h1><p>${collections.length} 个合集 · ${tracks.length} 个曲目</p></div>` +
      (collections.length ? `<h2 class="section-title">合集</h2><div class="grid">${collections.map(collectionCardHtml).join('')}</div>` : '') +
      (tracks.length ? `<h2 class="section-title">曲目</h2><div class="track-list">${tracks.map((track) => trackRowHtml(track)).join('')}</div>` : '') +
      (!collections.length && !tracks.length ? emptyHtml('没有找到结果', '换个关键词试试。') : '');
    hydrateCovers(root);
  };

  views.track = async function (route) {
    const token = state.renderToken;
    const root = $('#view-root');
    root.innerHTML = loadingHtml('正在加载曲目详情…');
    const detail = await apiGet(`/v1/library/tracks/${encodeURIComponent(route.id)}`);
    if (stale(token)) return;
    if (!detail || !detail.track) throw new ApiError('未找到该曲目。', 404, 'NOT_FOUND');
    cacheTrack(detail.track);
    const track = detail.track;
    const collection = detail.collection || null;
    if (collection) state.collectionCache.set(collection.id, collection);
    const playback = detail.playback || track.playback || null;
    const pct = playback && playback.duration ? Math.max(0, Math.min(100, (Number(playback.position) || 0) / playback.duration * 100)) : 0;
    const info = [];
    info.push(['文件名', track.filename]);
    info.push(['来源', locationLabel(track.locationType)]);
    info.push(['类型', mediaLabel(track.mediaKind)]);
    info.push(['时长', fmtDuration(track.duration)]);
    if (track.fileSize !== null && track.fileSize !== undefined) info.push(['大小', fmtBytes(track.fileSize)]);
    if (track.characterCount !== null && track.characterCount !== undefined) info.push(['字数', Number(track.characterCount).toLocaleString()]);
    if (track.chapter) info.push(['章节', track.chapter]);
    if (track.trackNumber) info.push(['音轨', track.trackNumber]);
    if (track.checksum) info.push(['校验', track.checksum]);
    if (playback && playback.updatedAt) info.push(['上次播放', fmtDateTime(playback.updatedAt)]);
    const listening = detail.listening || { sessions: 0, totalSec: 0, lastListenedAt: null };
    if (listening.sessions) info.push(['收听次数', `${listening.sessions} 次`]);
    if (listening.lastListenedAt) info.push(['最后收听', fmtDateTime(listening.lastListenedAt)]);

    const summary = detail.summary;
    const metadata = track.metadata && typeof track.metadata === 'object' ? track.metadata : null;
    const metadataEntries = metadata ? Object.keys(metadata).map((key) => [key, metadata[key]]) : [];

    root.innerHTML = `
      <button class="back" type="button" data-action="nav" data-href="#/library">‹ 返回书库</button>
      <div class="detail-head">
        ${collection ? coverHtml(collection) : '<div class="cover cover-placeholder">🐻</div>'}
        <div class="detail-head-text">
          <h1>${esc(track.displayName || track.filename || '未命名曲目')}</h1>
          <p class="detail-sub">${esc(collection ? collection.title : '独立曲目')}${collection && collection.author ? ` · ${collection.author}` : ''}</p>
          <div class="badges">
            <span class="badge">${esc(mediaLabel(track.mediaKind))}</span>
            <span class="badge">${esc(locationLabel(track.locationType))}</span>
            ${track.isFavorite ? '<span class="badge star">★ 收藏</span>' : ''}
            ${track.isArchived ? '<span class="badge archived">已归档</span>' : ''}
          </div>
          <div class="player-controls">
            <button class="btn btn-primary" type="button" data-action="play" data-id="${esc(track.id)}">
              ${track.locationType === 'text' || track.locationType === 'cachedText' ? '▤ 阅读文本' : '▶ 播放'}
            </button>
          </div>
        </div>
      </div>

      ${playback && playback.duration ? `<section class="detail-section"><h2>播放进度</h2>
        <div class="progress" style="height:8px"><i style="width:${pct.toFixed(1)}%"></i></div>
        <p class="detail-sub">${fmtDuration(playback.position)} / ${fmtDuration(playback.duration)}</p></section>` : ''}

      <section class="detail-section"><h2>曲目信息</h2>
        <div class="info-grid">${info.filter((entry) => entry[1] !== null && entry[1] !== undefined && entry[1] !== '')
          .map((entry) => `<div class="info-item"><label>${esc(entry[0])}</label><span class="${entry[0] === '校验' ? 'mono' : ''}">${esc(entry[1])}</span></div>`).join('')}</div>
      </section>

      ${track.description ? `<section class="detail-section"><h2>曲目描述</h2><p class="summary-body">${esc(track.description)}</p></section>` : ''}

      ${metadataEntries.length ? `<section class="detail-section"><h2>元数据</h2>
        <div class="info-grid">${metadataEntries.map((entry) => `<div class="info-item"><label>${esc(entry[0])}</label><span>${esc(entry[1])}</span></div>`).join('')}</div></section>` : ''}

      <section class="detail-section"><h2>AI 摘要</h2>
        ${summary ? `<div class="summary-block">
          ${summary.title ? `<h3 class="summary-title">${esc(summary.title)}</h3>` : ''}
          ${summary.body ? `<p class="summary-body">${esc(summary.body)}</p>` : ''}
          ${summary.keywords && summary.keywords.length ? `<div class="keywords">${summary.keywords.map((word) => `<span>${esc(word)}</span>`).join('')}</div>` : ''}
          ${summary.sections && summary.sections.length ? `<details class="summary-sections"><summary>${summary.sections.length} 个章节摘要</summary>
            ${summary.sections.map((section) => `<div class="summary-section"><b>${esc(section.title || fmtClock(section.startMs))}</b><p>${esc(section.summary)}</p></div>`).join('')}
          </details>` : ''}
        </div>` : '<p class="detail-sub">这个曲目还没有生成摘要。</p>'}
      </section>

      <section class="detail-section"><h2>转录</h2><div id="transcript-body">${loadingHtml('正在加载转录…')}</div></section>`;
    hydrateCovers(root);
    loadTranscript(track.id);
  };

  async function loadTranscript(trackId) {
    const host = $('#transcript-body');
    if (!host) return;
    if (state.route.name !== 'track' || state.route.id !== trackId) return;
    try {
      const data = await apiGet(`/v1/library/tracks/${encodeURIComponent(trackId)}/transcript`, { fullText: 0 });
      if (!data) { host.innerHTML = '<p class="detail-sub">这个曲目没有转录内容。</p>'; return; }
      const segments = data.segments || [];
      host.innerHTML = `
        <p class="detail-sub">${segments.length} 段 · ${esc(data.language || '未知语言')}</p>
        ${segments.length ? `<div class="transcript-segments">${segments.map((segment) => `
          <div class="segment">
            <time>${fmtClock(segment.startMs)}</time>
            <div class="seg-text">${segment.speaker ? `<span class="speaker">${esc(segment.speaker)}</span>` : ''}${esc(segment.text)}</div>
          </div>`).join('')}</div>` : '<p class="detail-sub">转录没有分段内容。</p>'}
        <div class="player-controls" style="margin-top:12px">
          <button class="btn btn-sm" type="button" data-action="transcript-full">显示全文</button>
        </div>`;
    } catch (err) {
      host.innerHTML = `<div class="error-box"><strong>转录加载失败</strong><p>${esc(err.message)}</p>
        <button class="btn" type="button" data-action="retry-transcript">重试</button></div>`;
    }
  }

  async function showTranscriptFullText(trackId) {
    const host = $('#transcript-body');
    if (!host) return;
    const button = $('[data-action="transcript-full"]', host);
    if (button) { button.disabled = true; button.textContent = '加载中…'; }
    try {
      const data = await apiGet(`/v1/library/tracks/${encodeURIComponent(trackId)}/transcript`, { fullText: 1 });
      if (!data || !data.fullText) {
        showNotice('这个转录没有全文内容。');
        if (button) { button.disabled = false; button.textContent = '显示全文'; }
        return;
      }
      const segments = data.segments || [];
      host.innerHTML = `
        <p class="detail-sub">${segments.length} 段 · ${esc(data.language || '未知语言')}</p>
        <pre class="transcript-full">${esc(data.fullText)}</pre>
        <div class="player-controls" style="margin-top:12px">
          <button class="btn btn-sm" type="button" data-action="transcript-segments">查看分段</button>
        </div>`;
    } catch (err) {
      showNotice('加载全文失败：' + err.message);
      if (button) { button.disabled = false; button.textContent = '显示全文'; }
    }
  }

  /* ---------------- notice bar ---------------- */

  function ensureNoticeBar() {
    if ($('#notice-bar')) return $('#notice-bar');
    const bar = document.createElement('div');
    bar.id = 'notice-bar';
    bar.className = 'notice-host';
    bar.addEventListener('click', (event) => {
      const button = event.target.closest('[data-action="dismiss-notice"]');
      if (button) bar.innerHTML = '';
    });
    const main = $('.main');
    main.insertBefore(bar, $('#view-root'));
    return bar;
  }

  function showNotice(text, kind) {
    const bar = ensureNoticeBar();
    bar.innerHTML = `<div class="notice ${kind === 'warn' ? 'warn' : ''}"><span>${esc(text)}</span>
      <button class="icon-btn" type="button" data-action="dismiss-notice" aria-label="关闭提示">✕</button></div>`;
  }

  function clearNotice() {
    const bar = $('#notice-bar');
    if (bar) bar.innerHTML = '';
  }

  /* ---------------- playback ---------------- */

  async function playTrack(trackId) {
    const track = state.trackCache.get(trackId);
    if (!track) {
      try {
        const detail = await apiGet(`/v1/library/tracks/${encodeURIComponent(trackId)}`);
        if (!detail || !detail.track) throw new ApiError('未找到该曲目。', 404, 'NOT_FOUND');
        cacheTrack(detail.track);
        playTrack(trackId);
        return;
      } catch (err) {
        showNotice('无法加载曲目：' + err.message);
        return;
      }
    }
    if (track.playable === false) {
      showNotice('这个曲目当前不可播放。');
      return;
    }
    const kind = track.locationType;
    if (kind === 'text' || kind === 'cachedText') {
      await openTextModal(track);
      return;
    }
    if (kind === 'baidu') {
      showNotice('百度网盘曲目目前只能在桌面端播放，网页端暂不支持。', 'warn');
      return;
    }
    let source;
    try {
      source = await apiGet(`/v1/library/tracks/${encodeURIComponent(track.id)}/playback`);
    } catch (err) {
      showNotice('无法获取播放地址：' + err.message);
      return;
    }
    if (!source || !source.value) {
      showNotice('这个曲目没有可用的播放地址。');
      return;
    }
    if (source.kind === 'baidu') {
      showNotice('百度网盘曲目目前只能在桌面端播放，网页端暂不支持。', 'warn');
      return;
    }
    startAudio(track, source.value);
  }

  function startAudio(track, url) {
    const apiPosition = track.playback ? Number(track.playback.position) || 0 : 0;
    const localPosition = savedPosition(track.id);
    const resumeAt = localPosition > 0 ? localPosition : apiPosition;
    const pending = resumeAt > 3 ? resumeAt : null;

    state.player.track = track;
    state.player.subtitle = track.chapter || track.filename || '';
    state.player.source = url;
    state.player.playing = false;
    state.player.pendingResume = pending;
    audio.src = url;
    renderPlayer();
  }

  function renderPlayer() {
    const player = $('#player');
    const current = state.player.track;
    if (!current) {
      player.hidden = true;
      app.classList.remove('has-player');
      syncPlayerHeight();
      return;
    }
    player.hidden = false;
    app.classList.add('has-player');
    const pending = state.player.pendingResume;
    const resumeRow = pending
      ? `<div class="player-resume"><span>上次播放到 ${fmtDuration(pending)}</span>
          <button class="btn btn-sm btn-primary" type="button" data-action="resume">继续播放</button>
          <button class="btn btn-sm" type="button" data-action="restart">从头开始</button></div>`
      : '';
    player.innerHTML = `${resumeRow}
      <div class="player-now">
        <div class="mini-cover">🐻</div>
        <div class="player-now-text">
          <b>${esc(current.displayName || current.filename || '未命名曲目')}</b>
          <small>${esc(state.player.subtitle || '')}</small>
        </div>
      </div>
      <div class="player-controls">
        <button class="icon-btn" type="button" data-action="restart" aria-label="从头开始" title="从头开始">↺</button>
        <button class="btn" type="button" data-action="toggle" aria-label="${state.player.playing ? '暂停' : '播放'}">${state.player.playing ? '❚❚' : '▶'}</button>
      </div>
      <div class="player-timeline">
        <span class="player-time" id="pos-time">0:00</span>
        <input type="range" id="seek" min="0" max="1" step="1" value="0" aria-label="播放进度">
        <span class="player-time" id="dur-time">0:00</span>
      </div>`;
    updatePlayerProgress();
    syncPlayerHeight();
  }

  function syncPlayerHeight() {
    const player = $('#player');
    const height = player && !player.hidden ? Math.ceil(player.getBoundingClientRect().height) : 0;
    document.documentElement.style.setProperty('--player-h', `${height}px`);
  }

  function updatePlayerProgress() {
    if (state.player.scrubbing) return;
    const seek = $('#seek');
    const pos = $('#pos-time');
    const dur = $('#dur-time');
    if (!seek) return;
    const duration = isFinite(audio.duration) && audio.duration > 0 ? audio.duration : (state.player.track && state.player.track.duration) || 0;
    seek.max = String(Math.max(1, Math.round(duration)));
    seek.value = String(Math.min(Math.round(audio.currentTime || 0), Number(seek.max)));
    if (pos) pos.textContent = fmtDuration(audio.currentTime || 0);
    if (dur) dur.textContent = fmtDuration(duration);
  }

  function togglePlayback() {
    if (!state.player.track) return;
    if (state.player.pendingResume !== null) { resumePlayback(); return; }
    if (audio.paused) {
      audio.play().catch(() => showNotice('播放失败，请检查网络连接。'));
    } else {
      audio.pause();
    }
  }

  function restartPlayback() {
    if (!state.player.track) return;
    state.player.pendingResume = null;
    const start = () => {
      try { audio.currentTime = 0; } catch (err) { /* ignore */ }
      audio.play().catch(() => showNotice('播放失败，请检查网络连接。'));
    };
    if (audio.readyState >= 1) start();
    else audio.addEventListener('loadedmetadata', start, { once: true });
    renderPlayer();
  }

  function resumePlayback() {
    if (!state.player.track) return;
    const target = state.player.pendingResume || 0;
    state.player.pendingResume = null;
    const start = () => {
      const limit = isFinite(audio.duration) && audio.duration > 0 ? Math.max(0, audio.duration - 1) : target;
      try { audio.currentTime = Math.max(0, Math.min(target, limit)); } catch (err) { /* ignore */ }
      audio.play().catch(() => showNotice('播放失败，请检查网络连接。'));
    };
    if (audio.readyState >= 1) start();
    else audio.addEventListener('loadedmetadata', start, { once: true });
    renderPlayer();
  }

  audio.addEventListener('loadedmetadata', () => {
    const pending = state.player.pendingResume;
    if (pending) {
      const limit = isFinite(audio.duration) && audio.duration > 0 ? Math.max(0, audio.duration - 1) : pending;
      try { audio.currentTime = Math.max(0, Math.min(pending, limit)); } catch (err) { /* ignore */ }
    }
    updatePlayerProgress();
  });
  audio.addEventListener('timeupdate', updatePlayerProgress);
  audio.addEventListener('play', () => { state.player.playing = true; renderPlayer(); });
  audio.addEventListener('pause', () => {
    state.player.playing = false;
    renderPlayer();
    if (state.player.track) rememberPosition(state.player.track.id, audio.currentTime, isFinite(audio.duration) ? audio.duration : null);
  });
  audio.addEventListener('ended', () => {
    state.player.playing = false;
    renderPlayer();
    if (state.player.track) rememberPosition(state.player.track.id, 0, isFinite(audio.duration) ? audio.duration : null);
  });
  audio.addEventListener('error', () => {
    if (!state.player.track) return;
    showNotice('播放失败：音频地址无法访问。');
  });
  window.addEventListener('beforeunload', () => {
    if (state.player.track) rememberPosition(state.player.track.id, audio.currentTime, isFinite(audio.duration) ? audio.duration : null);
  });

  setInterval(() => {
    if (!state.player.track || audio.paused) return;
    rememberPosition(state.player.track.id, audio.currentTime, isFinite(audio.duration) ? audio.duration : null);
  }, 3000);

  /* ---------------- text modal ---------------- */

  const modalRoot = $('#modal-root');

  function openModal(html) {
    modalRoot.innerHTML = `<div class="modal" role="dialog" aria-modal="true">${html}</div>`;
    modalRoot.hidden = false;
    document.body.classList.add('no-scroll');
  }

  function closeModal() {
    if (!modalRoot || modalRoot.hidden) return;
    modalRoot.hidden = true;
    modalRoot.innerHTML = '';
    document.body.classList.remove('no-scroll');
  }

  modalRoot.addEventListener('click', (event) => {
    if (event.target === modalRoot || event.target.closest('[data-action="close-modal"]')) closeModal();
  });

  async function openTextModal(track) {
    let content = '';
    try {
      const data = await apiGet(`/v1/library/tracks/${encodeURIComponent(track.id)}/text`);
      content = data && data.content ? data.content : '';
    } catch (err) {
      content = '';
      showNotice('读取文本失败：' + err.message);
    }
    openModal(`<div class="modal-head">
        <div class="modal-head-text"><h2>${esc(track.displayName || track.filename || '文本')}</h2>
          <p>${esc(track.chapter || '文本阅读')}</p></div>
        <button class="icon-btn" type="button" data-action="close-modal" aria-label="关闭">✕</button>
      </div>
      <div class="modal-body">${content ? `<pre>${esc(content)}</pre>` : '<p class="detail-sub">这个文本曲目没有内容。</p>'}</div>`);
  }

  /* ---------------- search form ---------------- */

  $('#search-form').addEventListener('submit', (event) => {
    event.preventDefault();
    const query = $('#search-input').value.trim();
    if (!query) return;
    navigate('#/search?q=' + encodeURIComponent(query));
  });

  /* ---------------- delegated actions ---------------- */

  document.addEventListener('click', (event) => {
    const target = event.target.closest('[data-action]');
    if (!target) return;
    const action = target.dataset.action;
    const id = target.dataset.id;
    switch (action) {
      case 'nav':
        navigate(target.dataset.href);
        break;
      case 'collection':
        navigate('#/collection/' + encodeURIComponent(id));
        break;
      case 'track':
        navigate('#/track/' + encodeURIComponent(id));
        break;
      case 'play':
        playTrack(id);
        break;
      case 'more-tracks':
        loadMoreTracks();
        break;
      case 'retry':
        if (state.retry) state.retry();
        break;
      case 'toggle':
        togglePlayback();
        break;
      case 'restart':
        restartPlayback();
        break;
      case 'resume':
        resumePlayback();
        break;
      case 'transcript-full':
        showTranscriptFullText(state.route.id);
        break;
      case 'transcript-segments':
        loadTranscript(state.route.id);
        break;
      case 'retry-transcript':
        loadTranscript(state.route.id);
        break;
      case 'close-modal':
        closeModal();
        break;
      case 'dismiss-notice':
        clearNotice();
        break;
      default:
        break;
    }
  });

  $('#player').addEventListener('input', (event) => {
    if (event.target.id !== 'seek') return;
    state.player.scrubbing = true;
    const value = Number(event.target.value) || 0;
    const pos = $('#pos-time');
    if (pos) pos.textContent = fmtDuration(value);
  });

  $('#player').addEventListener('change', (event) => {
    if (event.target.id !== 'seek') return;
    const value = Number(event.target.value) || 0;
    state.player.scrubbing = false;
    if (isFinite(audio.duration)) audio.currentTime = Math.min(value, audio.duration);
    updatePlayerProgress();
  });

  /* ---------------- render orchestration ---------------- */

  async function renderRoute() {
    const token = ++state.renderToken;
    const route = parseRoute();
    state.route = route;
    updateNavActive();
    renderSidebar();
    const root = $('#view-root');
    clearNotice();
    root.innerHTML = loadingHtml();
    state.retry = () => renderRoute();
    try {
      await views[route.name](route);
    } catch (err) {
      if (token !== state.renderToken) return;
      root.innerHTML = errorBoxHtml(err);
    }
  }

  async function bootstrap() {
    state.resume = loadResume();
    await Promise.all([loadStatus(), loadFolders()]);
    renderSidebar();
    await renderRoute();
  }

  async function loadFolders() {
    try {
      state.folders = await apiGet('/v1/library/folders') || [];
    } catch (err) {
      state.folders = [];
    }
    renderSidebar();
  }

  /* ---------------- boot ---------------- */

  function boot() {
    apiGet('/v1/library/status')
      .then((status) => {
        state.status = status;
        return bootstrap();
      })
      .catch((err) => {
        state.status = { dbReady: false, snapshotTime: null, sourceMtime: null, tracks: 0, collections: 0, error: err.message };
        bootstrap();
      });
  }

  setInterval(() => {
    if (document.hidden) return;
    loadStatus();
  }, 60000);

  boot();
})();
