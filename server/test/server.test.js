import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createApp, createBot, createStore, changeText, esc, normalize, statusText, validateSnapshot, vnTime } from '../server.js';

const pill = {
  id: '6F9619FF-8B86-D011-B42D-00C04FC964FF',
  name: 'Daily pill',
  dosesPerDay: 1,
  lastTakenAt: '2026-10-27T14:03:00Z',
  nextDueAt: '2026-10-28T14:00:00Z',
  deadlineAt: '2026-10-28T14:03:00Z',
  takenCount: 12,
  missedCount: 1,
  lateCount: 0,
  madeUpCount: 0,
  pillsTotal: 28,
  pillsRemaining: 16,
  refillReminder: { enabled: true, daysBefore: 7 },
  pausedUntil: null,
};

// The sample from docs/spec.md.
const spec = { schemaVersion: 2, name: 'Mai', updatedAt: '2026-10-27T14:03:00Z', medications: [pill] };

// The version 1 shape sent by app versions before 0.2.0.
const v1 = {
  schemaVersion: 1, name: 'Mai', updatedAt: '2026-10-27T14:03:00Z', lastTakenAt: '2026-10-27T14:03:00Z',
  nextDueAt: '2026-10-28T14:00:00Z', deadlineAt: '2026-10-28T14:03:00Z', daysTaken: 12, missedCount: 1, lateCount: 0,
  madeUpCount: 0, pillsTotal: 28, pillsRemaining: 16, refillReminder: { enabled: true, daysBefore: 7 }, pausedUntil: null,
};

const later = (snapshot, iso, patch = {}) => ({ ...snapshot, updatedAt: iso, medications: snapshot.medications.map((m) => ({ ...m, ...patch })) });
const tempStore = () => createStore(mkdtempSync(join(tmpdir(), 'ners-')));

async function withServer(store, run) {
  const sent = [];
  const server = createApp({ store, apiToken: 'secret-token', notify: (t) => sent.push(t) });
  await new Promise((r) => server.listen(0, r));
  const base = `http://127.0.0.1:${server.address().port}`;
  const request = (method, body, token = 'secret-token') => fetch(`${base}/v1/snapshot`, {
    method,
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  try {
    await run(request, sent);
  } finally {
    server.close();
  }
}

function fakeTelegram() {
  const calls = [];
  const fetchImpl = async (url, init) => {
    const method = url.split('/').pop();
    calls.push({ method, body: JSON.parse(init.body) });
    if (method === 'editMessageText' && calls.filter((c) => c.method === 'editMessageText').length > 1) {
      return { json: async () => ({ ok: false, description: 'Bad Request: message is not modified' }) };
    }
    return { json: async () => ({ ok: true, result: [] }) };
  };
  return { calls, fetchImpl };
}

test('times are shown in Vietnam time', () => {
  assert.equal(vnTime('2026-10-27T14:03:00Z'), '21:03');
  assert.equal(vnTime('2026-10-27T18:30:00Z'), '01:30');
});

test('spec example is valid, broken ones are not', () => {
  assert.equal(validateSnapshot(spec), null);
  assert.equal(validateSnapshot({ ...spec, medications: [] }), null);
  assert.match(validateSnapshot({ ...spec, updatedAt: '2026-10-27 14:03' }), /updatedAt/);
  assert.match(validateSnapshot({ ...spec, schemaVersion: 3 }), /schemaVersion/);
  assert.match(validateSnapshot(later(spec, spec.updatedAt, { pillsRemaining: -1 })), /medications\[0\]\.pillsRemaining/);
  assert.match(validateSnapshot(later(spec, spec.updatedAt, { dosesPerDay: 5 })), /dosesPerDay/);
  assert.match(validateSnapshot(later(spec, spec.updatedAt, { id: '' })), /id/);
  assert.match(validateSnapshot({ ...spec, medications: Array(31).fill(pill) }), /at most 30/);
  assert.match(validateSnapshot({ ...spec, name: 'x'.repeat(61) }), /name/);
});

test('timestamps must be real UTC dates and names count visible characters', () => {
  assert.match(validateSnapshot({ ...spec, updatedAt: '2026-02-30T00:00:00Z' }), /updatedAt/);
  assert.match(validateSnapshot(later(spec, spec.updatedAt, { deadlineAt: '2026-10-28T25:00:00Z' })), /deadlineAt/);
  assert.match(validateSnapshot(later(spec, spec.updatedAt, { lastTakenAt: '2025-02-29T00:00:00Z' })), /lastTakenAt/);
  assert.match(validateSnapshot({ ...spec, medications: [pill, pill] }), /id must be unique/);
  assert.equal(validateSnapshot({ ...spec, updatedAt: '2024-02-29T00:00:00Z', name: '👩🏽‍💻'.repeat(60) }), null);
  assert.equal(validateSnapshot(later(spec, spec.updatedAt, { name: '🇻🇳'.repeat(40) })), null);
});

test('version 1 from older apps is still accepted and stored as version 2', async () => {
  assert.equal(validateSnapshot(v1), null);
  assert.equal(validateSnapshot({ ...v1, lateCount: undefined }), null);
  assert.match(validateSnapshot({ ...v1, daysTaken: 'x' }), /daysTaken/);
  const store = tempStore();
  await withServer(store, async (request) => {
    assert.equal((await request('POST', v1)).status, 200);
    const stored = await (await request('GET')).json();
    assert.equal(stored.schemaVersion, 2);
    assert.equal(stored.medications[0].takenCount, 12);
  });
  // The first version 2 sync after the upgrade is not reported as a new and a removed medication.
  assert.equal(changeText(v1, later(spec, '2026-10-27T15:00:00Z')), null);
});

test('POST keeps only the newest snapshot and reports stale ones', async () => {
  const store = tempStore();
  await withServer(store, async (request, sent) => {
    assert.equal((await request('GET')).status, 404);
    assert.equal((await request('POST', spec, 'wrong')).status, 401);
    assert.equal((await request('POST', { ...spec, medications: 'x' })).status, 400);

    let res = await request('POST', spec);
    assert.deepEqual(await res.json(), { stale: false, message: null });
    assert.equal(sent.length, 1);
    assert.match(sent[0], /connected/);

    res = await request('POST', later(spec, '2026-10-27T13:00:00Z', { takenCount: 99 }));
    assert.equal((await res.json()).stale, true);
    assert.equal((await (await request('GET')).json()).medications[0].takenCount, 12);

    // A new dose is reported once; reopening the app with nothing new stays quiet.
    await request('POST', later(spec, '2026-10-28T14:01:00Z', { lastTakenAt: '2026-10-28T14:01:00Z', pillsRemaining: 15 }));
    assert.equal(sent.at(-1), '✅ Mai took <b>Daily pill</b> at 21:01 · 15 pills left');
    await request('POST', later(spec, '2026-10-28T15:00:00Z', { lastTakenAt: '2026-10-28T14:01:00Z', pillsRemaining: 15 }));
    assert.equal(sent.length, 2);
  });
});

test('message set by the bot comes back on the next sync', async () => {
  const store = tempStore();
  store.set({ message: 'Sleep early tonight' });
  await withServer(store, async (request) => {
    assert.deepEqual(await (await request('POST', spec)).json(), { stale: false, message: 'Sleep early tonight' });
  });
});

test('a failed disk write leaves the previous snapshot in place', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'ners-'));
  const store = createStore(dir);
  store.set({ snapshot: spec });
  mkdirSync(join(dir, 'state.json.tmp'));

  await withServer(store, async (request, sent) => {
    const updated = later(spec, '2026-10-28T15:00:00Z', { lastTakenAt: '2026-10-28T15:00:00Z' });
    assert.equal((await request('POST', updated)).status, 503);
    assert.deepEqual(await (await request('GET')).json(), spec);
    assert.deepEqual(sent, []);
  });
});

test('change text covers miss, late, make-up, pause, refill, added and removed', () => {
  const iron = { ...pill, id: 'iron', name: 'Iron <3', dosesPerDay: 2, pillsTotal: null, pillsRemaining: null };
  const before = { ...spec, medications: [{ ...pill, pillsRemaining: 8 }, iron] };
  const next = { ...spec, updatedAt: '2026-10-28T15:00:00Z', medications: [
    { ...pill, missedCount: 2, lateCount: 1, madeUpCount: 1, pillsRemaining: 7, pausedUntil: '2026-10-30T14:00:00Z' },
    { ...iron, id: 'zinc', name: 'Zinc' },
  ] };
  const text = changeText(before, next);
  assert.match(text, /🟡 <b>Daily pill<\/b> was taken late \(1 late so far\)\./);
  assert.match(text, /🔴 A dose of <b>Daily pill<\/b> was missed \(1 not made up\)\./);
  assert.match(text, /🔵 Mai made up a missed <b>Daily pill<\/b> dose \(1 still to make up\)\./);
  assert.match(text, /⏸️ <b>Daily pill<\/b> reminders are paused until 21:00 · Fri 30\/10\./);
  assert.match(text, /🛒 <b>Daily pill<\/b> is running low: 7 pills left\./);
  assert.match(text, /🆕 Mai added <b>Zinc<\/b> \(2× a day\)\./);
  assert.match(text, /🗑️ Mai removed <b>Iron &lt;3<\/b>\./);
  assert.equal(changeText(spec, later(spec, '2026-10-27T15:00:00Z')), null);
});

test('undo is reported as undo, not as a new dose at the older time', () => {
  const undone = later(spec, '2026-10-27T14:05:00Z', { lastTakenAt: '2026-10-26T14:01:00Z' });
  assert.equal(changeText(spec, undone), '↩️ Mai undid or edited the last <b>Daily pill</b> dose.');
});

test('names come from the app, with a neutral word without one, and are escaped', () => {
  const unnamed = { ...spec, name: null };
  assert.match(changeText(unnamed, later(unnamed, '2026-10-28T14:01:00Z', { lastTakenAt: '2026-10-28T14:01:00Z' })), /^✅ They took/);
  assert.match(statusText({ ...spec, name: 'Mai' }), /^💊 <b>Mai's meds<\/b>/);
  assert.match(statusText(unnamed), /^💊 <b>Pillot<\/b>/);
  assert.match(statusText({ ...spec, name: '<b>x</b>' }), /&lt;b&gt;x&lt;\/b&gt;'s meds/);
  assert.equal(esc('a & <b>'), 'a &amp; &lt;b&gt;');
});

test('status text lists every medication and marks data older than 24 hours', () => {
  const two = { ...spec, medications: [pill, { ...pill, id: 'b', name: 'Iron', dosesPerDay: 2, madeUpCount: 1, pillsTotal: null,
    lastTakenAt: null, pausedUntil: '2026-10-30T01:00:00Z' }] };
  const fresh = statusText(two, Date.parse('2026-10-28T01:00:00Z'));
  assert.match(fresh, /<b>Daily pill<\/b> · daily\n✅ Last taken 21:03 · Tue 27\/10\n⏰ Next 21:00 · Wed 28\/10, deadline 21:03/);
  assert.match(fresh, /📊 12 taken · 0 late · 1 missed\n💊 16 of 28 pills left/);
  assert.match(fresh, /<b>Iron<\/b> · 2× a day\n🌱 No doses logged yet\n⏸️ Paused until 08:00 · Fri 30\/10/);
  assert.match(fresh, /· 1 made up/);
  assert.match(fresh, /🕘 Updated 21:03 VN time$/);
  assert.match(statusText(spec, Date.parse('2026-10-29T01:00:00Z')), /⚠️ Not synced since 21:03 · Tue 27\/10/);
  assert.match(statusText(later(spec, spec.updatedAt, { pillsRemaining: 7 })), /7 of 28 pills left · 🛒 time to buy more/);
  assert.match(statusText({ ...spec, medications: [] }), /No medications set up/);
  assert.match(statusText(null), /^📭 Nothing here yet/);
  assert.match(statusText(v1, Date.parse('2026-10-28T01:00:00Z')), /12 taken/);
});

test('bot commands answer in its chat with HTML, a copy button and a refresh button', async () => {
  const store = tempStore();
  store.set({ snapshot: spec });
  const { calls, fetchImpl } = fakeTelegram();
  const bot = createBot({ token: 't', chatId: '42', store, publicUrl: 'https://x/ners', apiToken: 'secret-token', fetchImpl });
  const last = () => calls.at(-1).body;

  await bot.handle('/msg Take it and sleep <3');
  assert.equal(store.get().message, 'Take it and sleep <3');
  assert.match(last().text, /Saved! Mai will see it.*\n<i>Take it and sleep &lt;3<\/i>/);
  assert.equal(last().parse_mode, 'HTML');
  assert.equal(last().chat_id, '42');
  await bot.handle('/msg');
  assert.match(last().text, /Current note:\n<i>Take it and sleep &lt;3<\/i>/);
  await bot.handle(`/msg ${'x'.repeat(301)}`);
  assert.match(last().text, /bit long/);
  assert.equal(store.get().message, 'Take it and sleep <3');
  await bot.handle('/clearmsg');
  assert.equal(store.get().message, null);
  await bot.handle('/clearmsg');
  assert.match(last().text, /no note/);

  await bot.handle('/link');
  assert.match(last().text, /<code>https:\/\/x\/ners#secret-token<\/code>/);
  assert.deepEqual(last().reply_markup.inline_keyboard[0][0].copy_text, { text: 'https://x/ners#secret-token' });

  await bot.handle('/check@pillot_bot');
  assert.match(last().text, /Daily pill/);
  assert.equal(last().reply_markup.inline_keyboard[0][0].callback_data, 'refresh');

  for (const [input, expected] of [['/start', /Hi!.*\/link/s], ['/help', /\/clearmsg/], ['/nope', /I don't know \/nope/], ['hello', /\/msg your note/]]) {
    await bot.handle(input);
    assert.match(last().text, expected);
  }

  await bot.handleCallback({ id: 'q1', data: 'refresh', message: { message_id: 7, chat: { id: 42 } } });
  assert.equal(calls.at(-2).method, 'editMessageText');
  assert.equal(calls.at(-2).body.message_id, 7);
  assert.equal(last().text, '🔄 Updated');
  await bot.handleCallback({ id: 'q2', data: 'refresh', message: { message_id: 7, chat: { id: 42 } } });
  assert.equal(last().text, '✨ Already up to date');
});

test('the 09:00 report is sent once a day', async () => {
  const store = tempStore();
  store.set({ snapshot: spec });
  const { calls, fetchImpl } = fakeTelegram();
  const bot = createBot({ token: 't', chatId: '42', store, publicUrl: 'https://x/ners', apiToken: 'secret-token', fetchImpl });
  await bot.dailyReport(Date.parse('2026-10-28T01:30:00Z')); // 08:30 Vietnam time: not yet
  assert.equal(calls.length, 0);
  await bot.dailyReport(Date.parse('2026-10-28T02:00:00Z')); // 09:00 Vietnam time
  await bot.dailyReport(Date.parse('2026-10-28T02:01:00Z'));
  assert.equal(calls.length, 1);
  assert.match(calls[0].body.text, /^☀️ <b>Pillot<\/b>\n<b>Daily report · Medication check-in<\/b>\n28 Oct 2026 · 09:00 ICT\n/);
});

test('large medication lists fit Telegram and stay navigable from the status and daily report', async () => {
  const medications = Array.from({ length: 20 }, (_, i) => ({
    ...pill, id: String(i), name: `${i + 1}. ${'💊'.repeat(36)}`, dosesPerDay: 6,
    takenCount: 1000, lateCount: 100, missedCount: 100, madeUpCount: 50, skippedCount: 90,
    pillsPerDose: 2, pillsRemaining: 5,
  }));
  const snapshot = { ...spec, medications };
  assert.equal(validateSnapshot(snapshot), null);
  assert.ok(Array.from(statusText(snapshot).replace(/<\/?b>/g, '')).length > 4096);

  const store = tempStore();
  store.set({ snapshot });
  const { calls, fetchImpl } = fakeTelegram();
  const bot = createBot({ token: 't', chatId: '42', store, publicUrl: 'https://x/ners', apiToken: 'a', fetchImpl });
  await bot.handle('/check');
  await bot.dailyReport(Date.parse('2026-10-28T02:00:00Z'));
  for (const { body } of calls) {
    assert.ok(body.text.length <= 4096);
    assert.match(body.text, /<b>1\. 💊/u);
    assert.match(body.text, /Updated |Not synced since /);
  }

  const next = calls.at(-1).body.reply_markup.inline_keyboard[0].at(-1).callback_data;
  await bot.handleCallback({ id: 'q1', data: next, message: { message_id: 7, chat: { id: 42 } } });
  const secondPage = calls.find((c) => c.method === 'editMessageText').body;
  assert.ok(secondPage.text.length <= 4096);
  assert.match(secondPage.text, /<b>20\. 💊/u);
  assert.doesNotMatch(secondPage.text, /<b>1\. 💊/u);

  const lines = Array.from({ length: 50 }, (_, i) => `💊 <b>${i + 1}. ${'💊'.repeat(39)}</b> was updated.`);
  const start = calls.length;
  await bot.say(lines.join('\n'));
  const sent = calls.slice(start).map((call) => call.body.text);
  assert.ok(sent.length > 1 && sent.every((text) => text.length <= 4096));
  assert.equal(sent.join('\n'), lines.join('\n'));
});

test('scheduled Telegram sends retry after failure and only one request can be in flight', async () => {
  const now = Date.parse('2026-10-28T14:20:00Z');
  for (const [job, key] of [['dailyReport', 'lastReportDay'], ['checkDeadlines', 'nudged']]) {
    const store = tempStore();
    store.set({ snapshot: spec });
    let attempts = 0;
    let finish;
    const fetchImpl = () => {
      attempts += 1;
      return new Promise((resolve) => { finish = (result) => resolve({ json: async () => result }); });
    };
    const bot = createBot({ token: 't', chatId: '42', store, publicUrl: 'https://x/ners', apiToken: 'a', fetchImpl });

    const failed = assert.rejects(bot[job](now), /unavailable/);
    await bot[job](now);
    assert.equal(attempts, 1);
    finish({ ok: false, description: 'unavailable' });
    await failed;
    assert.equal(store.get()[key] ?? null, null);

    const retry = bot[job](now + 60_000);
    assert.equal(attempts, 2);
    finish({ ok: true });
    await retry;
    assert.ok(store.get()[key]);
    await bot[job](now + 120_000);
    assert.equal(attempts, 2);
  }
});

test('profile sets commands and descriptions', async () => {
  const { calls, fetchImpl } = fakeTelegram();
  const bot = createBot({ token: 't', chatId: '42', store: tempStore(), publicUrl: 'https://x/ners', apiToken: 'a', fetchImpl });
  await bot.setProfile();
  assert.deepEqual(calls.map((c) => c.method).sort(), ['setMyCommands', 'setMyDescription', 'setMyName', 'setMyShortDescription']);
  const commands = calls.find((c) => c.method === 'setMyCommands').body.commands.map((c) => c.command);
  assert.deepEqual(commands, ['check', 'msg', 'clearmsg', 'link', 'help']);
  assert.ok(calls.find((c) => c.method === 'setMyShortDescription').body.short_description.length <= 120);
  assert.ok(calls.find((c) => c.method === 'setMyDescription').body.description.length <= 512);
  assert.equal(normalize(null), null);
});

test('skips are reported and counted', () => {
  const next = later(spec, '2026-10-28T15:00:00Z', { skippedCount: 1 });
  assert.match(changeText(spec, next), /⏭️ Mai skipped a dose of <b>Daily pill<\/b> on purpose\./);
  assert.match(statusText(next, Date.parse('2026-10-28T16:00:00Z')), /· 1 skipped/);
  assert.equal(validateSnapshot(next), null);
  assert.match(validateSnapshot(later(spec, spec.updatedAt, { skippedCount: -1 })), /skippedCount/);
});

test('a passed deadline with no dose reported nudges the partner once', async () => {
  const store = tempStore();
  store.set({ snapshot: spec }); // deadline 2026-10-28T14:03:00Z, last taken before the dose was due
  const { calls, fetchImpl } = fakeTelegram();
  const bot = createBot({ token: 't', chatId: '42', store, publicUrl: 'https://x/ners', apiToken: 'a', fetchImpl });
  await bot.checkDeadlines(Date.parse('2026-10-28T14:10:00Z')); // within the 15 minute tolerance
  assert.equal(calls.length, 0);
  await bot.checkDeadlines(Date.parse('2026-10-28T14:20:00Z'));
  assert.equal(calls.length, 1);
  assert.match(calls[0].body.text, /⏰ <b>Daily pill<\/b> passed its deadline at 21:03 and no dose has come in yet\.\nThe phone may just be offline, but a gentle nudge to Mai could help/);
  await bot.checkDeadlines(Date.parse('2026-10-28T15:00:00Z'));
  assert.equal(calls.length, 1);
  // A new deadline after the next sync can nudge again; a taken or paused medication does not.
  store.set({ snapshot: later(spec, '2026-10-28T15:00:00Z', { deadlineAt: '2026-10-29T14:03:00Z', nextDueAt: '2026-10-29T14:00:00Z' }) });
  await bot.checkDeadlines(Date.parse('2026-10-29T14:30:00Z'));
  assert.equal(calls.length, 2);
  store.set({ snapshot: later(spec, '2026-10-29T15:00:00Z', { deadlineAt: '2026-10-30T14:03:00Z', nextDueAt: '2026-10-30T14:00:00Z', lastTakenAt: '2026-10-30T14:01:00Z' }) });
  await bot.checkDeadlines(Date.parse('2026-10-30T14:30:00Z'));
  store.set({ snapshot: later(spec, '2026-10-29T16:00:00Z', { deadlineAt: '2026-10-31T14:03:00Z', pausedUntil: '2026-11-02T00:00:00Z' }) });
  await bot.checkDeadlines(Date.parse('2026-10-31T14:30:00Z'));
  assert.equal(calls.length, 2);
});

test('as needed and finished courses read right and never nudge', async () => {
  const base = {
    id: 'a', name: 'Ibuprofen', dosesPerDay: 1, lastTakenAt: '2026-10-30T02:00:00Z', nextDueAt: '4001-01-01T00:00:00Z',
    deadlineAt: '4001-01-01T00:00:00Z', takenCount: 3, missedCount: 0, lateCount: 0, madeUpCount: 0, skippedCount: 0,
    pillsTotal: null, pillsRemaining: null, refillReminder: { enabled: false, daysBefore: 7 }, pausedUntil: null,
    asNeeded: true, courseEnded: false, pillsPerDose: 2, takenToday: 2,
  };
  const snapshot = { schemaVersion: 2, name: 'Ner', updatedAt: '2026-10-30T03:00:00Z', medications: [base, { ...base, id: 'b', name: 'Amox', asNeeded: false, courseEnded: true, nextDueAt: '2026-10-29T14:00:00Z', deadlineAt: '2026-10-29T14:00:00Z' }] };
  assert.equal(validateSnapshot(snapshot), null);
  const text = statusText(snapshot, Date.parse('2026-10-30T03:00:00Z'));
  assert.match(text, /as needed · 2 pills each/);
  assert.match(text, /Taken 2 times today/);
  assert.match(text, /Course finished/);
  assert.doesNotMatch(text, /4001/);
  const said = [];
  const store = { get: () => ({ snapshot, nudged: {} }), set() {} };
  const bot = createBot({ token: 't', chatId: '1', store, publicUrl: 'https://x', apiToken: 'k', fetchImpl: async (_url, init) => { said.push(JSON.parse(init.body).text); return { json: async () => ({ ok: true, result: {} }) }; } });
  await bot.checkDeadlines(Date.parse('2026-10-31T03:00:00Z'));
  assert.equal(said.length, 0);
});
