'use strict';

const PLANS = {
  'Claude Max 20x': { color: '--plan-claude', short: 'Claude', vendor: 'anthropic' },
  'ChatGPT Pro': { color: '--plan-openai', short: 'ChatGPT', vendor: 'openai' },
  'Google (Antigravity)': { color: '--plan-google', short: 'Antigravity', vendor: 'google' },
};
const PLAN_ORDER = ['Claude Max 20x', 'ChatGPT Pro', 'Google (Antigravity)'];
const ICONS = {
  good: '<svg viewBox="0 0 12 12" aria-hidden="true"><circle cx="6" cy="6" r="5" fill="currentColor"/><path d="M3.5 6.2l1.7 1.6 3.3-3.4" stroke="#fff" stroke-width="1.5" fill="none"/></svg>',
  warning: '<svg viewBox="0 0 12 12" aria-hidden="true"><path d="M6 1l5 9.5H1z" fill="currentColor"/><path d="M6 4.5v2.6M6 8.4v.2" stroke="#000" stroke-width="1.3"/></svg>',
  critical: '<svg viewBox="0 0 12 12" aria-hidden="true"><circle cx="6" cy="6" r="5" fill="currentColor"/><path d="M4 4l4 4M8 4l-4 4" stroke="#fff" stroke-width="1.5"/></svg>',
};

const state = { range: readPref('range', '7d'), metric: 'cost', group: new URLSearchParams(location.search).get('group') || readPref('group', 'plan'), data: null, showTable: false,
  automatedOnly: readPref('automatedOnly', 'false') === 'true', expanded: new Set() };

function readPref(key, fallback) {
  try { return localStorage.getItem('ai-usage.' + key) || fallback; } catch (e) { return fallback; }
}
function writePref(key, value) {
  try { localStorage.setItem('ai-usage.' + key, value); } catch (e) { /* private mode */ }
}
const $ = (sel) => document.querySelector(sel);
const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

function usd(v) {
  if (v == null) return '–';
  if (v === 0) return '$0';
  if (v < 0.01) return '<$0.01';
  if (v < 100) return '$' + v.toFixed(2);
  return '$' + Math.round(v).toLocaleString();
}
function tokens(v) {
  if (!v) return '0';
  if (v >= 1e9) return (v / 1e9).toFixed(v >= 1e10 ? 0 : 1) + 'B';
  if (v >= 1e6) return (v / 1e6).toFixed(v >= 1e7 ? 0 : 1) + 'M';
  if (v >= 1e3) return (v / 1e3).toFixed(v >= 1e4 ? 0 : 1) + 'K';
  return String(v);
}
function ago(ts) {
  if (!ts) return 'never';
  const s = Math.max(0, Date.now() / 1000 - ts);
  if (s < 60) return 'just now';
  if (s < 3600) return Math.round(s / 60) + ' min ago';
  if (s < 86400) return Math.round(s / 3600) + ' h ago';
  return Math.round(s / 86400) + ' d ago';
}
function until(ts) {
  if (!ts) return '';
  const s = ts - Date.now() / 1000;
  if (s <= 0) return 'reset due';
  const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
  const left = d ? `${d}d ${h}h` : h ? `${h}h ${m}m` : `${m}m`;
  const when = new Date(ts * 1000).toLocaleString([], d ? { weekday: 'short', hour: 'numeric', minute: '2-digit' } : { hour: 'numeric', minute: '2-digit' });
  return `resets in ${left} (${when})`;
}
function clock(ts) {
  const d = new Date(ts * 1000), today = new Date();
  const time = d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
  return d.toDateString() === today.toDateString() ? time : d.toLocaleDateString([], { month: 'short', day: 'numeric' }) + ' ' + time;
}
function level(left) {
  if (left <= 10) return ['critical', 'Almost out'];
  if (left <= 30) return ['warning', 'Running low'];
  return ['good', 'OK'];
}

async function load() {
  try {
    const res = await fetch('/api/summary?range=' + encodeURIComponent(state.range), { cache: 'no-store' });
    if (!res.ok) throw new Error((await res.json()).error || res.statusText);
    state.data = await res.json();
    $('#error').hidden = true;
    render();
  } catch (e) {
    $('#error').hidden = false;
    $('#error').textContent = 'Could not load usage: ' + e.message;
  }
}

function render() {
  const d = state.data;
  $('#host').textContent = d.host;
  $('#updated').textContent = 'logs read ' + ago(d.status.last_scan);
  const lag = Date.now() / 1000 - (d.status.last_scan || 0);
  if (lag > 300) {
    $('#error').hidden = false;
    $('#error').textContent = `Usage data is ${ago(d.status.last_scan).replace(' ago', '')} old. The collector on this Mac is behind, usually because the Mac is overloaded; it restarts itself if scans stop for 15 minutes.`;
  }
  document.querySelectorAll('[data-range]').forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.range === state.range)));
  document.querySelectorAll('[data-metric]').forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.metric === state.metric)));
  document.querySelectorAll('[data-group]').forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.group === state.group)));
  $('#chart-table-toggle').setAttribute('aria-pressed', String(state.showTable));
  $('#automated-only').checked = state.automatedOnly;
  renderPlans(d); renderTiles(d); renderChart(d); renderJobs(d); renderModels(d); renderPrices(d); renderRecent(d); renderSources(d);
}

function meter(limit) {
  const left = Math.max(0, Math.min(100, 100 - (limit.used_pct || 0)));
  const [lvl, word] = level(left);
  const stale = Date.now() / 1000 - limit.observed_at > 6 * 3600;
  return `<div class="meter">
    <div class="meter-top"><span>${esc(limit.label)}</span>
      <span><span class="status ${lvl}">${ICONS[lvl]}${word}</span> <span class="pct">${Math.round(left)}% left</span></span></div>
    <div class="meter-track" role="meter" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${Math.round(left)}" aria-label="${esc(limit.label)} remaining">
      <div class="meter-fill" style="width:${left}%;background:var(--${lvl})"></div></div>
    <div class="meter-sub"><span>${esc(until(limit.resets_at))}</span><span${stale ? ' class="status warning"' : ''}>as of ${esc(ago(limit.observed_at))}</span></div>
  </div>`;
}

function renderPlans(d) {
  const html = PLAN_ORDER.map((name) => {
    const meta = PLANS[name];
    const plan = d.plans.find((p) => p.plan === name) || {};
    const limits = d.limits.filter((l) => l.vendor === meta.vendor);
    let body = '';
    let group = null;
    limits.forEach((l) => {
      if (l.group && l.group !== group) body += `<div class="group">${esc(l.group)}</div>`;
      group = l.group;
      body += meter(l);
    });
    if (meta.vendor === 'anthropic' && limits.length) {
      const extra = limits[0].extra || {};
      if (extra.overageStatus) body += `<div class="meter-sub"><span>Extra usage: ${extra.overageStatus === 'rejected' ? 'off' : esc(extra.overageStatus)}${extra.isUsingOverage ? ' (in use)' : ''}</span></div>`;
    }
    if (!limits.length) {
      body = meta.vendor === 'google'
        ? '<p class="muted">No limit reading yet. Limits are read from the Antigravity app while it is open on this Mac.</p>'
        : '<p class="muted">No limit reading yet.</p>';
    }
    if (meta.vendor === 'anthropic' && d.status.probe_error) body += `<p class="status warning">${ICONS.warning} Probe: ${esc(d.status.probe_error)}</p>`;
    if (meta.vendor === 'openai' && d.status.codex_limits_error) body += `<p class="status warning">${ICONS.warning} ${esc(d.status.codex_limits_error)}</p>`;
    if (meta.vendor === 'google' && d.status.antigravity_quota_error) body += `<p class="status warning">${ICONS.warning} ${esc(d.status.antigravity_quota_error)}</p>`;
    const title = plan.label || (meta.vendor === 'google' && d.status.antigravity_tier ? `${d.status.antigravity_tier} (Antigravity)` : name);
    const value = plan.cost || 0;
    const compare = plan.prorated_usd ? ` vs <b>${usd(plan.prorated_usd)}</b> of plan price` : '';
    return `<article class="plan">
      <div class="plan-head"><span class="swatch" style="background:var(${meta.color})"></span><strong>${esc(title)}</strong>
        <span class="price">${plan.monthly_usd ? '$' + plan.monthly_usd + '/mo' : 'price not set'}</span></div>
      ${body}
      <div class="plan-foot">
        <span><b>${usd(value)}</b> at API prices${compare}</span>
        <span>${(plan.requests || 0).toLocaleString()} requests · ${tokens(plan.tokens)} tokens on this Mac</span>
      </div>
    </article>`;
  }).join('');
  $('#plans').innerHTML = html;
}

function renderTiles(d) {
  const t = d.totals;
  const auto = d.jobs.filter((j) => j.automated).reduce((a, j) => a + j.cost, 0);
  const top = d.jobs.find((j) => j.automated);
  const cacheShare = t.tokens ? Math.round((t.cache_read / t.tokens) * 100) : 0;
  const tiles = [
    ['API-equivalent value', usd(t.cost), `${t.unpriced ? t.unpriced + ' requests unpriced · ' : ''}${rangeLabel()}`],
    ['Model requests', t.requests.toLocaleString(), `${tokens(t.output)} output tokens`],
    ['Tokens processed', tokens(t.tokens), `${cacheShare}% served from cache`],
    ['Background jobs', usd(auto), top ? `top: ${top.job} (${usd(top.cost)})` : 'no job usage in this range'],
  ];
  $('#tiles').innerHTML = tiles.map(([label, value, hint]) =>
    `<div class="tile"><div class="label">${esc(label)}</div><div class="value">${esc(value)}</div><div class="hint">${esc(hint)}</div></div>`).join('');
}

function rangeLabel() {
  return { today: 'today', '7d': 'last 7 days', '30d': 'last 30 days', all: 'all recorded' }[state.range];
}

function bucketLabel(key, short) {
  if (state.data.bucket === 'hour') {
    const h = Number(key.slice(11, 13));
    return h === 0 ? '12a' : h < 12 ? h + 'a' : h === 12 ? '12p' : (h - 12) + 'p';
  }
  const [y, m, day] = key.split('-').map(Number);
  const date = new Date(y, m - 1, day);
  return date.toLocaleDateString([], short ? { month: 'short', day: 'numeric' } : { weekday: 'short', month: 'short', day: 'numeric' });
}

function niceMax(v) {
  if (v <= 0) return 1;
  const p = Math.pow(10, Math.floor(Math.log10(v)));
  const n = v / p;
  return (n <= 1 ? 1 : n <= 2 ? 2 : n <= 2.5 ? 2.5 : n <= 5 ? 5 : 10) * p;
}

const GROUP_NAMES = { plan: 'plan', model: 'model', effort: 'effort' };

function chartGroups(d) {
  const named = d.series[state.group] || {};
  if (state.group === 'plan') {
    return PLAN_ORDER.filter((p) => named[p]).map((p) => ({ key: p, label: p, short: PLANS[p].short, color: `var(${PLANS[p].color})` }));
  }
  if (state.group === 'model') {
    return d.series_order.model.filter((m) => named[m]).map((m, i) => ({
      key: m, label: m, short: m, color: m === 'Other models' ? 'var(--cat-other)' : `var(--cat-${i + 1})` }));
  }
  return d.series_order.effort.filter((e) => named[e]).map((e) => ({
    key: e, label: EFFORT_LABELS[e] || e, short: EFFORT_LABELS[e] || e, color: `var(--e-${e})` }));
}

function renderChart(d) {
  const groups = chartGroups(d);
  const series = d.series[state.group] || {};
  $('#legend').innerHTML = groups.map((g) => `<span><span class="swatch" style="background:${g.color}"></span>${esc(g.label)}</span>`).join('');
  $('#chart-h').textContent = (state.metric === 'cost' ? 'API-equivalent cost by ' : 'Tokens by ') + GROUP_NAMES[state.group];
  const value = (pt) => (pt ? (state.metric === 'cost' ? pt.cost : pt.tokens) : 0);
  const n = d.buckets.length;
  const totals = d.buckets.map((_, i) => groups.reduce((a, g) => a + value(series[g.key][i]), 0));
  renderChartTable(d, groups, series, value, totals);

  const box = $('#chart');
  const W = Math.max(box.clientWidth, 280), H = box.clientHeight || 260;
  const m = { top: 8, right: 4, bottom: 24, left: 52 };
  const iw = W - m.left - m.right, ih = H - m.top - m.bottom;
  const max = niceMax(Math.max(...totals, 0));
  const fmt = state.metric === 'cost' ? usd : tokens;
  const step = iw / Math.max(n, 1);
  const bw = Math.max(2, Math.min(36, step * 0.68));
  const y = (v) => m.top + ih - (v / max) * ih;
  let svg = `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="${esc($('#chart-h').textContent)}, ${esc(rangeLabel())}">`;
  svg += '<g class="grid axis">';
  for (let i = 0; i <= 4; i++) {
    const v = (max / 4) * i, yy = y(v);
    if (i) svg += `<line x1="${m.left}" x2="${W - m.right}" y1="${yy}" y2="${yy}"/>`;
    svg += `<text x="${m.left - 8}" y="${yy + 4}" text-anchor="end">${esc(fmt(v))}</text>`;
  }
  svg += '</g>';
  const every = Math.ceil(n / Math.max(1, Math.floor(iw / 64)));
  svg += '<g class="axis">';
  d.buckets.forEach((key, i) => {
    if (i % every === 0) svg += `<text x="${m.left + step * i + step / 2}" y="${H - 6}" text-anchor="middle">${esc(bucketLabel(key, true))}</text>`;
  });
  svg += '</g>';
  d.buckets.forEach((_, i) => {
    const x = m.left + step * i + (step - bw) / 2;
    svg += `<rect class="band" data-i="${i}" x="${m.left + step * i}" y="${m.top}" width="${step}" height="${ih}"/>`;
    let base = 0;
    const segs = groups.map((g) => [g, value(series[g.key][i])]).filter(([, v]) => v > 0);
    segs.forEach(([p, v], k) => {
      const bottom = y(base) - (k ? 2 : 0), top = Math.min(y(base + v), bottom - 1);
      const h = bottom - top;
      const last = k === segs.length - 1;
      const r = last ? Math.min(4, bw / 2, h) : 0;
      // A rounded data end on the top segment only; a 2px gap separates stacked segments.
      const path = r
        ? `M${x},${bottom}V${top + r}Q${x},${top} ${x + r},${top}H${x + bw - r}Q${x + bw},${top} ${x + bw},${top + r}V${bottom}Z`
        : `M${x},${bottom}V${top}H${x + bw}V${bottom}Z`;
      svg += `<path d="${path}" fill="${p.color}"/>`;
      base += v;
    });
  });
  svg += `<line class="baseline" x1="${m.left}" x2="${W - m.right}" y1="${m.top + ih}" y2="${m.top + ih}"/>`;
  if (!totals.some((v) => v > 0)) svg += `<text class="empty" x="${m.left + iw / 2}" y="${m.top + ih / 2}" text-anchor="middle">No usage in this range</text>`;
  d.buckets.forEach((_, i) => { svg += `<rect class="hit" data-i="${i}" x="${m.left + step * i}" y="${m.top}" width="${step}" height="${ih + m.bottom}"/>`; });
  svg += '</svg>';
  box.innerHTML = svg;

  const tip = $('#tooltip');
  const show = (evt) => {
    const i = Number(evt.target.dataset.i);
    if (Number.isNaN(i)) return;
    box.querySelectorAll('.band').forEach((b) => b.classList.toggle('on', Number(b.dataset.i) === i));
    const rows = groups.map((g) => {
      const pt = series[g.key][i];
      return pt ? `<div class="t-row"><span><span class="swatch" style="background:${g.color}"></span>${esc(g.short)}</span><span>${esc(fmt(value(pt)))} · ${pt.requests} req</span></div>` : '';
    }).join('');
    tip.innerHTML = `<div class="t-head">${esc(bucketLabel(d.buckets[i]))}${d.bucket === 'hour' ? ' hour' : ''}</div>${rows || '<div class="muted">No requests</div>'}<div class="t-row t-total"><span>Total</span><span>${esc(fmt(totals[i]))}</span></div>`;
    tip.hidden = false;
    const px = evt.clientX ?? evt.target.getBoundingClientRect().left, py = evt.clientY ?? evt.target.getBoundingClientRect().top;
    const tw = tip.offsetWidth, th = tip.offsetHeight;
    tip.style.left = Math.min(window.innerWidth - tw - 8, Math.max(8, px + 12)) + 'px';
    tip.style.top = Math.max(8, py - th - 12) + 'px';
  };
  const hide = () => { tip.hidden = true; box.querySelectorAll('.band').forEach((b) => b.classList.remove('on')); };
  box.querySelectorAll('.hit').forEach((r) => {
    r.addEventListener('pointermove', show);
    r.addEventListener('pointerdown', show);
    r.addEventListener('pointerleave', hide);
  });
}

function renderChartTable(d, groups, series, value, totals) {
  const wrap = $('#chart-table');
  wrap.hidden = !state.showTable;
  if (!state.showTable) return;
  const fmt = state.metric === 'cost' ? usd : tokens;
  const head = `<tr><th>${d.bucket === 'hour' ? 'Hour' : 'Day'}</th>${groups.map((g) => `<th class="num">${esc(g.short)}</th>`).join('')}<th class="num">Total</th></tr>`;
  const body = d.buckets.map((key, i) => totals[i] ? `<tr><td>${esc(bucketLabel(key))}</td>${groups.map((g) => `<td class="num">${esc(fmt(value(series[g.key][i])))}</td>`).join('')}<td class="num">${esc(fmt(totals[i]))}</td></tr>` : '').reverse().join('');
  wrap.innerHTML = `<table><thead>${head}</thead><tbody>${body || `<tr><td colspan="${groups.length + 2}" class="muted">No usage in this range</td></tr>`}</tbody></table>`;
}

function planDot(tools) {
  const plan = tools.includes('Codex') ? 'ChatGPT Pro' : tools.some((t) => t.startsWith('Antigravity')) ? 'Google (Antigravity)' : 'Claude Max 20x';
  return `<span class="dot" style="background:var(${PLANS[plan].color})"></span>`;
}

function renderJobs(d) {
  const list = d.jobs.filter((j) => !state.automatedOnly || j.automated);
  const rows = list.map((j) => {
    const key = j.job;
    const open = state.expanded.has(key);
    const details = j.details.length ? `<div class="detail">${esc(j.details.slice(0, 3).join(' · '))}</div>` : '';
    let html = `<tr class="expandable" tabindex="0" data-job="${esc(key)}" aria-expanded="${open}">
      <td class="wrap"><span class="chev">›</span> ${planDot(j.tools)}${esc(j.job)}${j.automated ? '' : '<span class="tag">you</span>'}${details}</td>
      <td class="hide-sm">${esc(j.tools.join(', '))}</td>
      <td class="num">${j.requests.toLocaleString()}</td>
      <td class="num hide-sm">${tokens(j.tokens)}</td>
      <td class="num hide-sm">${tokens(j.output)}</td>
      <td class="num"><b>${usd(j.cost)}</b></td>
      <td class="hide-sm">${esc(ago(j.last))}</td></tr>`;
    if (open) {
      html += j.models.map((mo) => `<tr class="child"><td>${esc(mo.model)}${mo.effort !== 'unknown' ? ` · ${esc(EFFORT_LABELS[mo.effort] || mo.effort)}` : ''}</td><td class="hide-sm"></td><td class="num">${mo.requests.toLocaleString()}</td><td class="num hide-sm">${tokens(mo.tokens)}</td><td class="num hide-sm">${tokens(mo.output)}</td><td class="num">${usd(mo.cost)}</td><td class="hide-sm"></td></tr>`).join('');
    }
    return html;
  }).join('');
  $('#jobs').innerHTML = `<table><thead><tr><th>Job or app</th><th class="hide-sm">Tool</th><th class="num">Requests</th><th class="num hide-sm">Tokens</th><th class="num hide-sm">Output</th><th class="num">API value</th><th class="hide-sm">Last request</th></tr></thead>
    <tbody>${rows || '<tr><td colspan="7" class="muted">No usage in this range</td></tr>'}</tbody></table>`;
  $('#jobs').querySelectorAll('tr.expandable').forEach((tr) => {
    const toggle = () => {
      const key = tr.dataset.job;
      state.expanded.has(key) ? state.expanded.delete(key) : state.expanded.add(key);
      renderJobs(state.data);
    };
    tr.addEventListener('click', toggle);
    tr.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggle(); } });
  });
}

const EFFORT_LABELS = { low: 'Low', medium: 'Medium', high: 'High', xhigh: 'Extra high', max: 'Max', auto: 'Auto', unknown: 'Not recorded' };

function effortTag(effort) {
  return `<span class="effort e-${esc(effort)}">${esc(EFFORT_LABELS[effort] || effort)}</span>`;
}

function perRequest(x) {
  return x.requests ? usd(x.cost / x.requests) : '–';
}

function priceLine(price) {
  if (!price) return '';
  const cached = price.cache_read != null ? ` · cached ${money(price.cache_read)}` : '';
  return `<div class="detail">${money(price.input)} in · ${money(price.output)} out${cached} per 1M tokens</div>`;
}

function renderEffortMix(d) {
  const total = d.efforts.reduce((a, e) => a + e.cost, 0);
  if (!total) { $('#effort-mix').innerHTML = ''; return; }
  const bar = d.efforts.filter((e) => e.cost > 0).map((e) =>
    `<span class="seg e-${esc(e.effort)}" style="width:${(e.cost / total) * 100}%" title="${esc(EFFORT_LABELS[e.effort] || e.effort)}: ${usd(e.cost)}"></span>`).join('');
  const legend = d.efforts.map((e) =>
    `<span>${effortTag(e.effort)} ${usd(e.cost)} <span class="muted">· ${Math.round((e.cost / total) * 100)}% · ${e.requests.toLocaleString()} req · ${perRequest(e)}/req</span></span>`).join('');
  $('#effort-mix').innerHTML = `<div class="mix-label">Share of API value by effort</div><div class="mix-bar" role="img" aria-label="Share of API value by effort">${bar}</div><div class="mix-legend">${legend}</div>`;
}

function renderModelEffortChart(d) {
  const box = $('#model-effort-chart');
  const models = d.models.filter((m) => m.cost > 0);
  if (!models.length) { box.innerHTML = ''; return; }
  const max = Math.max(...models.map((m) => m.cost));
  box.innerHTML = '<div class="mix-label">API value by model, split by effort</div>' + models.map((m, r) => `
    <div class="me-row">
      <div class="me-name">${esc(m.model)}</div>
      <div class="me-track"><div class="me-bar" style="width:${Math.max((m.cost / max) * 100, 0.5)}%">${m.efforts.filter((e) => e.cost > 0).map((e) =>
        `<span class="seg e-${esc(e.effort)}" style="width:${(e.cost / m.cost) * 100}%" data-m="${r}" data-e="${esc(e.effort)}"></span>`).join('')}</div></div>
      <div class="me-value">${usd(m.cost)}</div>
    </div>`).join('');
  const tip = $('#tooltip');
  box.querySelectorAll('.seg').forEach((seg) => {
    const show = (evt) => {
      const m = models[Number(seg.dataset.m)];
      const e = m.efforts.find((x) => x.effort === seg.dataset.e);
      tip.innerHTML = `<div class="t-head">${esc(m.model)}</div>
        <div class="t-row"><span>${effortTag(e.effort)}</span><span>${usd(e.cost)}</span></div>
        <div class="t-row"><span>Share of model</span><span>${Math.round((e.cost / m.cost) * 100)}%</span></div>
        <div class="t-row"><span>Requests</span><span>${e.requests.toLocaleString()}</span></div>
        <div class="t-row t-total"><span>Per request</span><span>${perRequest(e)}</span></div>`;
      tip.hidden = false;
      const tw = tip.offsetWidth, th = tip.offsetHeight;
      tip.style.left = Math.min(window.innerWidth - tw - 8, Math.max(8, evt.clientX + 12)) + 'px';
      tip.style.top = Math.max(8, evt.clientY - th - 12) + 'px';
    };
    seg.addEventListener('pointermove', show);
    seg.addEventListener('pointerdown', show);
    seg.addEventListener('pointerleave', () => { tip.hidden = true; });
  });
}

function renderModels(d) {
  renderEffortMix(d);
  renderModelEffortChart(d);
  const plansCell = (mo) => mo.plans.map((p) => `<span class="dot" style="background:var(${(PLANS[p] || PLANS['Claude Max 20x']).color})"></span>${esc(PLANS[p] ? PLANS[p].short : p)}`).join(' ');
  const cells = (x) => `<td class="num hide-sm">${x.requests.toLocaleString()}</td>
    <td class="num">${perRequest(x)}</td>
    <td class="num hide-sm">${tokens(x.input + x.cache_write)}</td>
    <td class="num hide-sm">${tokens(x.cache_read)}</td>
    <td class="num hide-sm">${tokens(x.output)}</td>`;
  const rows = d.models.map((mo) => {
    const single = mo.efforts.length === 1;
    let html = `<tr class="model-row">
      <td class="wrap">${esc(mo.model)}${single ? ' ' + effortTag(mo.efforts[0].effort) : ''}${mo.priced ? '' : '<span class="tag">no price</span>'}${priceLine(mo.price)}</td>
      <td class="hide-sm">${plansCell(mo)}</td>${cells(mo)}<td class="num"><b>${usd(mo.cost)}</b></td></tr>`;
    if (!single) {
      html += mo.efforts.map((e) => `<tr class="child"><td>${effortTag(e.effort)}</td><td class="hide-sm"></td>${cells(e)}<td class="num">${usd(e.cost)}</td></tr>`).join('');
    }
    return html;
  }).join('');
  $('#models').innerHTML = `<table><thead><tr><th>Model and effort</th><th class="hide-sm">Paid by</th><th class="num hide-sm">Requests</th><th class="num">Per request</th><th class="num hide-sm">Input</th><th class="num hide-sm">Cached input</th><th class="num hide-sm">Output</th><th class="num">API value</th></tr></thead>
    <tbody>${rows || '<tr><td colspan="8" class="muted">No usage in this range</td></tr>'}</tbody></table>`;
}

const MODEL_NAMES = { 'gpt-6.1-sol': 'GPT-6.1 Sol', 'gpt-6-sol': 'GPT-6 Sol', 'gpt-6-astra': 'GPT-6 Astra', 'gpt-6-luna': 'GPT-6 Luna',
  'gemini-3.8-flash': 'Gemini 3.8 Flash', 'gemini-4-argon': 'Gemini 4 Argon', 'claude-opus-5-5': 'Claude Opus 5.5',
  'claude-fable-5-1': 'Claude Fable 5.1', 'claude-sonnet-5-5': 'Claude Sonnet 5.5', 'claude-haiku-5-5': 'Claude Haiku 5.5' };
const COMPANIES = { anthropic: 'Anthropic', openai: 'OpenAI', google: 'Google' };

function money(v) {
  if (v == null) return '–';
  if (v >= 1) return '$' + v.toFixed(2).replace(/\.00$/, '');
  const short = String(Number(v.toPrecision(2)));
  return '$' + ((short.split('.')[1] || '').length < 2 ? v.toFixed(2) : short);
}

function smallUsd(v) {
  return v != null && v > 0 && v < 0.01 ? money(v) : usd(v);
}

function renderPrices(d) {
  const efforts = ['low', 'medium', 'high', 'xhigh', 'max'];
  const rows = d.price_table.map((r) => {
    const p = r.price || {};
    const effortCells = efforts.map((e) => {
      const x = r.efforts[e];
      return `<td class="num">${x ? `${smallUsd(x.per_request)}<div class="detail">${x.requests.toLocaleString()} req</div>` : '<span class="muted">–</span>'}</td>`;
    }).join('');
    return `<tr><td class="wrap sticky"><b>${esc(MODEL_NAMES[r.model] || r.model)}</b>${p.note ? `<div class="detail">${esc(p.note)}</div>` : ''}</td>
      <td class="hide-sm">${esc(COMPANIES[r.vendor] || r.vendor)}</td>
      <td class="num">${money(p.input)}</td><td class="num">${money(p.cache_read)}</td><td class="num"><b>${money(p.output)}</b></td>${effortCells}</tr>`;
  }).join('');
  const links = Object.entries(d.pricing.urls || {}).map(([v, u]) => `<a href="${esc(u)}" target="_blank" rel="noopener noreferrer">${esc(COMPANIES[v] || v)}</a>`).join(' · ');
  $('#prices').innerHTML = `<table class="prices"><thead>
      <tr><th rowspan="2" class="sticky">Model</th><th rowspan="2" class="hide-sm">Company</th><th colspan="3" class="group-h">Quoted price per 1M tokens</th><th colspan="5" class="group-h">Your average per request, by effort</th></tr>
      <tr><th class="num">Input</th><th class="num">Cached</th><th class="num">Output</th>${efforts.map((e) => `<th class="num">${effortTag(e)}</th>`).join('')}</tr>
    </thead><tbody>${rows}</tbody></table>
    <p class="note">Prices checked ${esc(d.pricing.checked)} on the official pages: ${links}.</p>`;
}

function renderRecent(d) {
  const rows = d.recent.slice(0, 25).map((r) => `<tr>
    <td>${esc(clock(r.ts))}</td>
    <td class="wrap">${esc(r.job)}${r.detail ? `<div class="detail">${esc(r.detail)}</div>` : ''}</td>
    <td class="hide-sm">${esc(r.model)}</td>
    <td class="num hide-sm">${tokens(r.tokens)}</td>
    <td class="num">${usd(r.cost)}</td></tr>`).join('');
  $('#recent').innerHTML = `<table><thead><tr><th>When</th><th>Job or app</th><th class="hide-sm">Model</th><th class="num hide-sm">Tokens</th><th class="num">API value</th></tr></thead><tbody>${rows}</tbody></table>`;
}

function renderSources(d) {
  const names = { claude_transcript: 'Claude Code logs', codex_rollout: 'Codex session logs', antigravity_ide: 'Antigravity IDE', antigravity_cli: 'Antigravity CLI (agy)', otel_claude: 'Claude telemetry (no-log calls)', otel_codex: 'Codex telemetry (no-log calls)' };
  const cards = d.sources.map((s) => `<div class="source"><b>${esc(names[s.source] || s.source)}</b><br>${s.requests.toLocaleString()} requests since ${esc(new Date(s.first * 1000).toLocaleDateString([], { month: 'short', day: 'numeric' }))}<br>latest ${esc(ago(s.last))}</div>`);
  if (!d.sources.some((s) => s.source.startsWith('otel'))) cards.push('<div class="source"><b>Telemetry</b><br>No no-log calls received yet</div>');
  $('#sources').className = 'sources';
  $('#sources').innerHTML = cards.join('');
  const p = d.pricing;
  $('#pricing-note').textContent = `API prices checked ${p.checked}. Claude: ${p.sources.anthropic}. OpenAI: ${p.sources.openai}. Google: ${p.sources.google}. Edit ai_usage/pricing.json to change them.`;
}

document.querySelectorAll('[data-range]').forEach((b) => b.addEventListener('click', () => {
  state.range = b.dataset.range; writePref('range', state.range); load();
}));
document.querySelectorAll('[data-group]').forEach((b) => b.addEventListener('click', () => {
  state.group = b.dataset.group; writePref('group', state.group); render();
}));
document.querySelectorAll('[data-metric]').forEach((b) => b.addEventListener('click', () => {
  state.metric = b.dataset.metric; render();
}));
$('#chart-table-toggle').addEventListener('click', () => { state.showTable = !state.showTable; render(); });
$('#automated-only').addEventListener('change', (e) => {
  state.automatedOnly = e.target.checked; writePref('automatedOnly', String(state.automatedOnly)); renderJobs(state.data);
});
let resizeTimer;
window.addEventListener('resize', () => { clearTimeout(resizeTimer); resizeTimer = setTimeout(() => state.data && renderChart(state.data), 120); });
window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => state.data && render());
load();
setInterval(load, 60000);
