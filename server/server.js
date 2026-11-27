// Pillot sync service: keeps the latest snapshot from the app and runs a private Telegram bot.
// Plain Node, no dependencies. Every setting comes from environment variables, nothing secret lives in the repo.
import { createServer } from 'node:http';
import { readFileSync, writeFileSync, renameSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { timingSafeEqual } from 'node:crypto';
import { setDefaultAutoSelectFamilyAttemptTimeout } from 'node:net';

// Node tries each address family for only 250 ms by default. On a host without IPv6 and about 200 ms from Telegram,
// that aborts the IPv4 attempt about half the time ("fetch failed", ETIMEDOUT). Two seconds is plenty.
setDefaultAutoSelectFamilyAttemptTimeout(2000);

const VN_OFFSET_MS = 7 * 3600 * 1000;
const WEEKDAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const DOSES_PER_DAY = [1, 2, 3, 4, 6];
const MESSAGE_LIMIT = 300;
const MEDICATION_LIMIT = 30;
const TELEGRAM_TEXT_LIMIT = 4096;
const reportDate = new Intl.DateTimeFormat('en-GB', {
  day: '2-digit', month: 'short', year: 'numeric', timeZone: 'Asia/Ho_Chi_Minh',
});
const nameSegments = new Intl.Segmenter(undefined, { granularity: 'grapheme' });
/// Same as the app's late tolerance: a dose this soon after the deadline is still on time.
const NUDGE_AFTER_MS = 15 * 60 * 1000;

// MARK: Formatting (Vietnam time, fixed UTC+7 with no daylight saving)

const pad = (n) => String(n).padStart(2, '0');
const vn = (iso) => new Date(Date.parse(iso) + VN_OFFSET_MS);

/// Telegram HTML: only these three characters need escaping in text.
export const esc = (text) => String(text).replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' })[c]);

export function vnTime(iso) {
  const d = vn(iso);
  return `${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}`;
}

export function vnDay(iso) {
  const d = vn(iso);
  return `${WEEKDAYS[d.getUTCDay()]} ${pad(d.getUTCDate())}/${pad(d.getUTCMonth() + 1)}`;
}

export function vnDateKey(ms) {
  const d = new Date(ms + VN_OFFSET_MS);
  return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}`;
}

function reportHeading(now) {
  const vnNow = new Date(now + VN_OFFSET_MS);
  return [
    '☀️ <b>Pillot</b>',
    '<b>Daily report · Medication check-in</b>',
    `${reportDate.format(now)} · ${pad(vnNow.getUTCHours())}:${pad(vnNow.getUTCMinutes())} ICT`,
  ].join('\n');
}

const plural = (n, word) => `${n} ${word}${n === 1 ? '' : 's'}`;
const frequency = (n) => (n === 1 ? 'daily' : `${n}× a day`);

function displayName(value) {
  const name = value.trim().replace(/[\r\n]+/g, ' ');
  if (name.length <= 512) return esc(name);
  // A grapheme can contain thousands of code units. Keep it whole and bound its rendered name.
  let end = 0;
  for (const { index, segment } of nameSegments.segment(name)) {
    if (index + segment.length > 512) break;
    end = index + segment.length;
  }
  return esc(`${name.slice(0, end)}…`);
}

/// The user's name sent with the snapshot, or a neutral word without one. Already escaped.
export const who = (s) => displayName((typeof s?.name === 'string' && s.name.trim()) || 'They');
const medName = (m) => `<b>${displayName(m.name?.trim() || 'Their pill')}</b>`;

// MARK: Snapshots

/// Version 1 (one schedule, before medications had names) becomes version 2 with a single medication.
/// Snapshots stored before the upgrade go through here too.
export function normalize(s) {
  if (!s || s.schemaVersion !== 1) return s;
  return {
    schemaVersion: 2,
    name: s.name ?? null,
    updatedAt: s.updatedAt,
    medications: [{
      id: 'default', name: '', dosesPerDay: 1, lastTakenAt: s.lastTakenAt, nextDueAt: s.nextDueAt, deadlineAt: s.deadlineAt,
      takenCount: s.daysTaken, missedCount: s.missedCount, lateCount: s.lateCount ?? 0, madeUpCount: s.madeUpCount ?? 0,
      pillsTotal: s.pillsTotal, pillsRemaining: s.pillsRemaining, refillReminder: s.refillReminder, pausedUntil: s.pausedUntil,
    }],
  };
}

const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;
const isCount = (v) => Number.isInteger(v) && v >= 0;
function isShortName(value) {
  if (typeof value !== 'string') return false;
  if (value.length <= 60) return true;
  let count = 0;
  for (const _ of nameSegments.segment(value)) {
    if (++count > 60) return false;
  }
  return true;
}

function isTimestamp(value) {
  if (typeof value !== 'string' || !ISO.test(value)) return false;
  const ms = Date.parse(value);
  return Number.isFinite(ms) && new Date(ms).toISOString() === `${value.slice(0, -1)}.000Z`;
}

function validateMedicationFields(m, { requireId }) {
  if (requireId && (typeof m.id !== 'string' || !m.id || m.id.length > 64)) return 'id must be a short string';
  for (const key of ['nextDueAt', 'deadlineAt']) {
    if (!isTimestamp(m[key])) return `${key} must be a UTC ISO 8601 timestamp`;
  }
  for (const key of ['lastTakenAt', 'pausedUntil']) {
    if (m[key] !== null && !isTimestamp(m[key])) return `${key} must be a timestamp or null`;
  }
  for (const key of ['pillsTotal', 'pillsRemaining']) {
    if (m[key] !== null && !isCount(m[key])) return `${key} must be a non-negative integer or null`;
  }
  const r = m.refillReminder;
  if (!r || typeof r.enabled !== 'boolean' || !Number.isInteger(r.daysBefore)) return 'refillReminder is invalid';
  return null;
}

/// Checks the contract in docs/spec.md (version 2, or the older version 1). Returns the first problem found, or null.
export function validateSnapshot(s) {
  if (!s || typeof s !== 'object') return 'body must be a JSON object';
  if (s.name != null && !isShortName(s.name)) return 'name must be a short string or null';
  if (!isTimestamp(s.updatedAt)) return 'updatedAt must be a UTC ISO 8601 timestamp';
  if (s.schemaVersion === 1) {
    for (const key of ['daysTaken', 'missedCount']) if (!isCount(s[key])) return `${key} must be a non-negative integer`;
    for (const key of ['lateCount', 'madeUpCount']) {
      if (s[key] !== undefined && !isCount(s[key])) return `${key} must be a non-negative integer`;
    }
    return validateMedicationFields(s, { requireId: false });
  }
  if (s.schemaVersion !== 2) return 'schemaVersion must be 1 or 2';
  if (!Array.isArray(s.medications) || s.medications.length > MEDICATION_LIMIT) return `medications must be a list of at most ${MEDICATION_LIMIT}`;
  const ids = new Set();
  for (const [i, m] of s.medications.entries()) {
    if (!m || typeof m !== 'object') return `medications[${i}] must be an object`;
    if (!isShortName(m.name)) return `medications[${i}].name must be a short string`;
    if (!DOSES_PER_DAY.includes(m.dosesPerDay)) return `medications[${i}].dosesPerDay must be one of ${DOSES_PER_DAY.join(', ')}`;
    for (const key of ['takenCount', 'missedCount', 'lateCount', 'madeUpCount']) {
      if (!isCount(m[key])) return `medications[${i}].${key} must be a non-negative integer`;
    }
    // Sent since 0.3.0.
    if (m.skippedCount !== undefined && !isCount(m.skippedCount)) return `medications[${i}].skippedCount must be a non-negative integer`;
    // Sent since 0.5.0.
    for (const key of ['asNeeded', 'courseEnded']) {
      if (m[key] !== undefined && typeof m[key] !== 'boolean') return `medications[${i}].${key} must be a boolean`;
    }
    for (const key of ['pillsPerDose', 'takenToday']) {
      if (m[key] !== undefined && !isCount(m[key])) return `medications[${i}].${key} must be a non-negative integer`;
    }
    const problem = validateMedicationFields(m, { requireId: true });
    if (problem) return `medications[${i}].${problem}`;
    if (ids.has(m.id)) return `medications[${i}].id must be unique`;
    ids.add(m.id);
  }
  return null;
}

// MARK: Texts

const needsRefill = (m) => m?.pillsTotal != null && m.refillReminder?.enabled && m.pillsRemaining <= m.refillReminder.daysBefore;

function medicationStatus(m, now) {
  const each = m.pillsPerDose > 1 ? ` · ${m.pillsPerDose} pills each` : '';
  const lines = [`${medName(m)} · ${m.asNeeded ? 'as needed' : frequency(m.dosesPerDay)}${each}`];
  lines.push(m.lastTakenAt ? `✅ Last taken ${vnTime(m.lastTakenAt)} · ${vnDay(m.lastTakenAt)}` : '🌱 No doses logged yet');
  if (m.asNeeded) {
    lines.push(`🩹 Taken ${plural(m.takenToday ?? 0, 'time')} today`);
  } else if (m.courseEnded) {
    lines.push('🏁 Course finished, no more reminders');
  } else if (m.pausedUntil && Date.parse(m.pausedUntil) > now) {
    lines.push(`⏸️ Paused until ${vnTime(m.pausedUntil)} · ${vnDay(m.pausedUntil)}`);
  } else {
    lines.push(`⏰ Next ${vnTime(m.nextDueAt)} · ${vnDay(m.nextDueAt)}, deadline ${vnTime(m.deadlineAt)}`);
  }
  const notMadeUp = m.missedCount - m.madeUpCount;
  if (m.asNeeded) {
    if (m.pillsTotal != null) lines.push(`💊 ${m.pillsRemaining} of ${m.pillsTotal} pills left${needsRefill(m) ? ' · 🛒 time to buy more' : ''}`);
    return lines.join('\n');
  }
  lines.push(`📊 ${m.takenCount} taken · ${m.lateCount} late · ${notMadeUp} missed${m.madeUpCount ? ` · ${m.madeUpCount} made up` : ''}${m.skippedCount ? ` · ${m.skippedCount} skipped` : ''}`);
  if (m.pillsTotal != null) lines.push(`💊 ${m.pillsRemaining} of ${m.pillsTotal} pills left${needsRefill(m) ? ' · 🛒 time to buy more' : ''}`);
  return lines.join('\n');
}

function statusParts(snapshot, now) {
  const s = normalize(snapshot);
  if (!s) return ['📭 Nothing here yet. Once the app is connected with /link, its updates show up here.'];
  const title = s.name?.trim() ? `💊 <b>${displayName(s.name)}'s meds</b>` : "💊 <b>Pillot</b>";
  const blocks = s.medications.length
    ? s.medications.map((m) => medicationStatus(m, now))
    : ['No medications set up in the app yet.'];
  const age = now - Date.parse(s.updatedAt);
  const footer = age > 24 * 3600 * 1000
    ? `⚠️ Not synced since ${vnTime(s.updatedAt)} · ${vnDay(s.updatedAt)}. The app sends updates whenever it's online.`
    : `🕘 Updated ${vnTime(s.updatedAt)} VN time`;
  return [title, ...blocks, footer];
}

/// Full status for /check and the 09:00 report. All times are Vietnam time.
export function statusText(snapshot, now = Date.now()) {
  return statusParts(snapshot, now).join('\n\n');
}

function splitByLength(parts, separator, limit) {
  const chunks = [];
  for (const part of parts) {
    const last = chunks.at(-1);
    if (last !== undefined && last.length + separator.length + part.length <= limit) {
      chunks[chunks.length - 1] = `${last}${separator}${part}`;
    } else {
      chunks.push(part);
    }
  }
  return chunks;
}

function statusPages(snapshot, now) {
  const [title, ...blocks] = statusParts(snapshot, now);
  if (!blocks.length) return [title];
  const footer = blocks.pop();
  const fixedLength = title.length + footer.length + reportHeading(now).length + 6;
  return splitByLength(blocks, '\n\n', TELEGRAM_TEXT_LIMIT - fixedLength)
    .map((page) => [title, page, footer].join('\n\n'));
}

/// Message sent on new data. Only for things worth knowing, not on every app launch.
export function changeText(previousSnapshot, nextSnapshot) {
  const previous = normalize(previousSnapshot);
  const next = normalize(nextSnapshot);
  if (!previous) {
    return "🔗 Pillot is connected! I'll let you know when doses are taken, late or missed. Try /check any time.";
  }
  const name = who(next);
  const before = new Map(previous.medications.map((m) => [m.id, m]));
  // After the upgrade from version 1, the old single schedule becomes the first medication.
  if (before.has('default') && next.medications[0] && !before.has(next.medications[0].id)) {
    before.set(next.medications[0].id, before.get('default'));
    before.delete('default');
  }
  const parts = [];
  for (const m of next.medications) {
    const p = before.get(m.id);
    before.delete(m.id);
    if (!p) {
      parts.push(`🆕 ${name} added ${medName(m)} (${frequency(m.dosesPerDay)}).`);
      continue;
    }
    const taken = (x) => (x?.lastTakenAt ? Date.parse(x.lastTakenAt) : 0);
    if (taken(m) > taken(p)) {
      parts.push(`✅ ${name} took ${medName(m)} at ${vnTime(m.lastTakenAt)}${m.pillsTotal != null ? ` · ${plural(m.pillsRemaining, 'pill')} left` : ''}`);
    } else if (taken(m) < taken(p)) {
      // The latest take moved back: an undo, or an edit to an earlier time in History.
      parts.push(`↩️ ${name} undid or edited the last ${medName(m)} dose.`);
    }
    if (m.lateCount > p.lateCount) parts.push(`🟡 ${medName(m)} was taken late (${m.lateCount} late so far).`);
    if (m.missedCount > p.missedCount) parts.push(`🔴 A dose of ${medName(m)} was missed (${m.missedCount - m.madeUpCount} not made up).`);
    if (m.madeUpCount > p.madeUpCount) {
      parts.push(`🔵 ${name} made up a missed ${medName(m)} dose (${m.missedCount - m.madeUpCount} still to make up).`);
    }
    if ((m.skippedCount ?? 0) > (p.skippedCount ?? 0)) parts.push(`⏭️ ${name} skipped a dose of ${medName(m)} on purpose.`);
    if (m.pausedUntil && m.pausedUntil !== p.pausedUntil) {
      parts.push(`⏸️ ${medName(m)} reminders are paused until ${vnTime(m.pausedUntil)} · ${vnDay(m.pausedUntil)}.`);
    }
    if (needsRefill(m) && !needsRefill(p)) parts.push(`🛒 ${medName(m)} is running low: ${plural(m.pillsRemaining, 'pill')} left.`);
  }
  for (const m of before.values()) parts.push(`🗑️ ${name} removed ${medName(m)}.`);
  return parts.length ? parts.join('\n') : null;
}

export const HELP = [
  "💊 <b>Pillot</b>",
  'I keep you in the loop on the meds in the app: taken, late or missed, plus a check-in every morning at 09:00 Vietnam time.',
  '',
  '/check · how things stand right now',
  '/msg <i>text</i> · leave a note on the app\'s Today screen',
  '/clearmsg · remove the note',
  '/link · the code that connects the app',
  '/help · this list',
].join('\n');

// MARK: State

export function createStore(dir) {
  mkdirSync(dir, { recursive: true });
  const file = join(dir, 'state.json');
  let state = { snapshot: null, message: null, lastReportDay: null, offset: 0 };
  try {
    state = { ...state, ...JSON.parse(readFileSync(file, 'utf8')) };
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  return {
    get: () => state,
    set(patch) {
      const next = { ...state, ...patch };
      // Write a temporary file and rename it, so a half-written file never exists.
      writeFileSync(`${file}.tmp`, JSON.stringify(next, null, 2));
      renameSync(`${file}.tmp`, file);
      state = next;
    },
  };
}

// MARK: HTTP

function sameToken(header, token) {
  const given = Buffer.from(header?.startsWith('Bearer ') ? header.slice(7) : '');
  const expected = Buffer.from(token);
  return given.length === expected.length && timingSafeEqual(given, expected);
}

export function createApp({ store, apiToken, notify = () => {} }) {
  return createServer((req, res) => {
    const send = (status, body) => {
      res.writeHead(status, { 'content-type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify(body));
    };
    const path = new URL(req.url, 'http://local').pathname;
    if (path === '/healthz') return send(200, { ok: true });
    if (path !== '/v1/snapshot') return send(404, { error: 'not found' });
    if (!sameToken(req.headers.authorization, apiToken)) return send(401, { error: 'unauthorized' });

    if (req.method === 'GET') {
      const { snapshot } = store.get();
      return snapshot ? send(200, normalize(snapshot)) : send(404, { error: 'no snapshot yet' });
    }
    if (req.method !== 'POST') return send(405, { error: 'method not allowed' });

    let body = '';
    req.setEncoding('utf8');
    req.on('data', (chunk) => {
      body += chunk;
      if (body.length > 64 * 1024) req.destroy();
    });
    req.on('end', () => {
      let snapshot;
      try {
        snapshot = JSON.parse(body);
      } catch {
        return send(400, { error: 'invalid JSON' });
      }
      const problem = validateSnapshot(snapshot);
      if (problem) return send(400, { error: problem });
      snapshot = normalize(snapshot);
      const { snapshot: previous, message } = store.get();
      // Keep only the newest; older ones (sent late after being offline) are ignored.
      if (previous && isTimestamp(previous.updatedAt) && Date.parse(snapshot.updatedAt) <= Date.parse(previous.updatedAt)) {
        return send(200, { stale: true, message });
      }
      try {
        store.set({ snapshot });
      } catch (error) {
        console.error('snapshot write', error.code ?? error.name);
        return send(503, { error: 'could not save snapshot' });
      }
      const text = changeText(previous, snapshot);
      if (text) notify(text);
      send(200, { stale: false, message });
    });
  });
}

// MARK: Telegram bot

export function createBot({ token, chatId, store, publicUrl, apiToken, fetchImpl = fetch }) {
  const call = async (method, params) => {
    const response = await fetchImpl(`https://api.telegram.org/bot${token}/${method}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(params),
      signal: AbortSignal.timeout(method === 'getUpdates' ? 65_000 : 15_000),
    });
    const json = await response.json();
    if (!json.ok) throw new Error(`${method}: ${json.description}`);
    return json.result;
  };
  const refreshButton = { inline_keyboard: [[{ text: '🔄 Refresh', callback_data: 'refresh' }]] };
  const say = async (text, extra = {}) => {
    const chunks = text.length <= TELEGRAM_TEXT_LIMIT ? [text] : splitByLength(text.split('\n'), '\n', TELEGRAM_TEXT_LIMIT);
    let result;
    for (const [index, chunk] of chunks.entries()) {
      result = await call('sendMessage', {
        chat_id: chatId, text: chunk, parse_mode: 'HTML', link_preview_options: { is_disabled: true },
        ...(index === chunks.length - 1 ? extra : {}),
      });
    }
    return result;
  };

  const statusView = (page = 0, now = Date.now()) => {
    const pages = statusPages(store.get().snapshot, now);
    page = Math.min(page, pages.length - 1);
    const button = (text, index) => ({ text, callback_data: index === 0 ? 'refresh' : `status:${index}` });
    const controls = [button('🔄 Refresh', page)];
    if (page > 0) controls.unshift(button('‹ Previous', page - 1));
    if (page < pages.length - 1) controls.push(button('Next ›', page + 1));
    return { text: pages[page], reply_markup: { inline_keyboard: [controls] } };
  };

  const handle = async (text) => {
    const trimmed = text.trim();
    if (!trimmed.startsWith('/')) return say('💬 Want that to show up in the app? Send it as <code>/msg your note</code>.');
    const [command] = trimmed.split(/\s+/);
    const argument = trimmed.slice(command.length).trim();
    switch (command.split('@')[0].toLowerCase()) {
      case '/start':
        return say(`👋 Hi! ${HELP}\n\nFirst step: send /link and paste the code into the app.`);
      case '/help':
        return say(HELP);
      case '/check': {
        const { text, reply_markup } = statusView();
        return say(text, { reply_markup });
      }
      case '/msg': {
        if (!argument) {
          const current = store.get().message;
          return say(current
            ? `💌 Current note:\n<i>${esc(current)}</i>\n\nSend <code>/msg new text</code> to change it, or /clearmsg to remove it.`
            : '💌 No note right now. Send <code>/msg your note</code> and it shows up on the app\'s Today screen.');
        }
        if (argument.length > MESSAGE_LIMIT) return say(`✂️ That's a bit long. Notes fit ${MESSAGE_LIMIT} characters, this one has ${argument.length}.`);
        store.set({ message: argument });
        return say(`💌 Saved! ${who(store.get().snapshot)} will see it in the app after the next sync:\n<i>${esc(argument)}</i>`);
      }
      case '/clearmsg':
        if (!store.get().message) return say('🧹 There was no note to remove.');
        store.set({ message: null });
        return say('🧹 Note removed. The app clears it on the next sync.');
      case '/link': {
        const code = `${publicUrl}#${apiToken}`;
        return say([
          '🔗 <b>Connection code</b>',
          'In Pillot, open <b>Settings → Shared tracking</b> and paste this:',
          '',
          `<code>${esc(code)}</code>`,
          '',
          '🔒 Keep it private: anyone with this code can send updates to this chat.',
        ].join('\n'), { reply_markup: { inline_keyboard: [[{ text: '📋 Copy code', copy_text: { text: code } }]] } });
      }
      default:
        return say(`🤔 I don't know ${esc(command.slice(0, 100))}. Here's what I can do:\n\n${HELP}`);
    }
  };

  /// The Refresh button under a status: redraws it in place.
  const handleCallback = async (query) => {
    const page = query.data === 'refresh' ? 0 : /^status:(\d{1,2})$/.exec(query.data)?.[1];
    if (page === undefined || !query.message) return call('answerCallbackQuery', { callback_query_id: query.id });
    try {
      await call('editMessageText', {
        chat_id: chatId, message_id: query.message.message_id, ...statusView(Number(page)),
        parse_mode: 'HTML', link_preview_options: { is_disabled: true },
      });
      return call('answerCallbackQuery', { callback_query_id: query.id, text: '🔄 Updated' });
    } catch (error) {
      if (!/not modified/.test(error.message)) throw error;
      return call('answerCallbackQuery', { callback_query_id: query.id, text: '✨ Already up to date' });
    }
  };

  const poll = async () => {
    for (;;) {
      try {
        const updates = await call('getUpdates', { offset: store.get().offset, timeout: 50, allowed_updates: ['message', 'callback_query'] });
        for (const update of updates) {
          store.set({ offset: update.update_id + 1 });
          // Only answer the configured chat; everyone else is ignored.
          const message = update.message;
          if (message?.text && String(message.chat.id) === String(chatId)) await handle(message.text);
          const query = update.callback_query;
          if (query && String(query.message?.chat.id) === String(chatId)) await handleCallback(query);
        }
      } catch (error) {
        console.error('poll', error.message);
        await new Promise((r) => setTimeout(r, 5000));
      }
    }
  };

  /// The 09:00 Vietnam time report, once a day even across restarts.
  let sendingReport = false;
  const dailyReport = async (now = Date.now()) => {
    const vnNow = new Date(now + VN_OFFSET_MS);
    const today = vnDateKey(now);
    if (sendingReport || vnNow.getUTCHours() < 9 || store.get().lastReportDay === today) return;
    sendingReport = true;
    try {
      const { text, reply_markup } = statusView(0, now);
      await say(`${reportHeading(now)}\n\n${text}`, { reply_markup });
      store.set({ lastReportDay: today });
    } finally {
      sendingReport = false;
    }
  };

  /// A heads-up to the partner when a dose is past its deadline and the app has not reported it. The snapshot carries
  /// the deadline, so this only compares times; the phone may just be offline, and the message says so. Once per deadline.
  let sendingNudges = false;
  const checkDeadlines = async (now = Date.now()) => {
    if (sendingNudges) return;
    const s = normalize(store.get().snapshot);
    if (!s) return;
    const nudged = { ...(store.get().nudged ?? {}) };
    const late = s.medications.filter((m) => {
      // Nothing is due for a medication taken when needed or a finished course.
      const resting = m.asNeeded || m.courseEnded || (m.pausedUntil && Date.parse(m.pausedUntil) > now);
      const reported = m.lastTakenAt && Date.parse(m.lastTakenAt) >= Date.parse(m.nextDueAt);
      return !resting && !reported && now > Date.parse(m.deadlineAt) + NUDGE_AFTER_MS && nudged[m.id] !== m.deadlineAt;
    });
    if (!late.length) return;
    const lines = late.map((m) => `⏰ ${medName(m)} passed its deadline at ${vnTime(m.deadlineAt)} and no dose has come in yet.`);
    sendingNudges = true;
    try {
      await say(`${lines.join('\n')}\nThe phone may just be offline, but a gentle nudge to ${who(s)} could help 💛`, { reply_markup: refreshButton });
      const sent = Object.fromEntries(late.map((m) => [m.id, m.deadlineAt]));
      store.set({ nudged: { ...nudged, ...sent } });
    } finally {
      sendingNudges = false;
    }
  };

  /// Command menu and profile texts, set on every start so they follow the code.
  const setProfile = () => Promise.all([
    call('setMyName', { name: 'Pillot' }),
    call('setMyCommands', { commands: [
      { command: 'check', description: 'View current medication status' },
      { command: 'msg', description: 'View or leave a note in the app' },
      { command: 'clearmsg', description: 'Clear the app note' },
      { command: 'link', description: 'Get the private app connection code' },
      { command: 'help', description: 'Show available commands' },
    ] }),
    call('setMyShortDescription', { short_description: 'Pillot · Medication check-ins, dose alerts and app notes.' }),
    call('setMyDescription', { description: [
      'Pillot',
      '',
      'Follow shared medication updates, check reported doses and low stock, and leave a note in the Pillot app.',
      '',
      'Daily report · 09:00 Vietnam time',
      'Commands · /help',
    ].join('\n') }),
  ]);

  return { say, handle, handleCallback, poll, dailyReport, checkDeadlines, setProfile };
}

// MARK: Main

if (import.meta.url === `file://${process.argv[1]}`) {
  const env = process.env;
  for (const key of ['API_TOKEN', 'PUBLIC_URL']) {
    if (!env[key]) throw new Error(`missing ${key}`);
  }
  const store = createStore(env.DATA_DIR ?? './data');
  const bot = env.BOT_TOKEN && env.CHAT_ID
    ? createBot({ token: env.BOT_TOKEN, chatId: env.CHAT_ID, store, publicUrl: env.PUBLIC_URL, apiToken: env.API_TOKEN })
    : null;
  const notify = (text) => bot?.say(text).catch((e) => console.error('notify', e.message));
  createApp({ store, apiToken: env.API_TOKEN, notify }).listen(Number(env.PORT ?? 8787), () => {
    console.log(`listening on ${env.PORT ?? 8787}, bot ${bot ? 'on' : 'off (BOT_TOKEN or CHAT_ID missing)'}`);
  });
  if (bot) {
    // Retried, because a failure here would leave the old command menu in Telegram until the next restart.
    const profile = (attempt = 1) => bot.setProfile().catch((e) => {
      console.error('profile', e.message);
      if (attempt < 10) setTimeout(() => profile(attempt + 1), 30 * 1000);
    });
    profile();
    bot.poll();
    setInterval(() => bot.dailyReport().catch((e) => console.error('report', e.message)), 60 * 1000);
    setInterval(() => bot.checkDeadlines().catch((e) => console.error('deadlines', e.message)), 60 * 1000);
  }
}
