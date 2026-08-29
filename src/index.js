// dorm lock worker
// phone hits POST /command (or /toggle), esp32 long polls GET /poll then POST /confirm
// GET /state for status. /health is public

const DEFAULTS = {
  POLL_TIMEOUT_MS: 25000,
  COMMAND_TIMEOUT_MS: 10000,
  COMMAND_TTL_MS: 60000, // cmd is dead after this
};

// stay under cloudflare's idle timeout
const MAX_HOLD_MS = 27000;
const IDEM_KEEP = 25;
// a requestId only counts as a retry for 10 min, after that its a new request
const IDEM_TTL_MS = 600000;

class HttpError extends Error {
  constructor(status, code, extra = {}) {
    super(code);
    this.status = status;
    this.code = code;
    this.extra = extra;
  }
}

const encoder = new TextEncoder();

function toNum(value, fallback) {
  if (value === undefined || value === null || value === '') return fallback;
  const n = Number(value);
  return Number.isFinite(n) ? n : fallback;
}

function clamp(n, lo, hi) {
  return Math.min(hi, Math.max(lo, n));
}

function baseHeaders(extra = {}) {
  return {
    'cache-control': 'no-store',
    'strict-transport-security': 'max-age=31536000',
    'referrer-policy': 'no-referrer',
    'x-content-type-options': 'nosniff',
    ...extra,
  };
}

function jsonResponse(body, status = 200, extra = {}) {
  return new Response(JSON.stringify(body, null, 2) + '\n', {
    status,
    headers: baseHeaders({ 'content-type': 'application/json; charset=utf-8', ...extra }),
  });
}

// lock/unlock work too
function normalizeTarget(value) {
  if (typeof value !== 'string') return null;
  const t = value.trim().toLowerCase();
  if (t === 'locked' || t === 'lock') return 'locked';
  if (t === 'unlocked' || t === 'unlock') return 'unlocked';
  return null;
}

function iso(ms) {
  return ms ? new Date(ms).toISOString() : null;
}

// ---- auth ----

async function sha256(text) {
  return crypto.subtle.digest('SHA-256', encoder.encode(text));
}

function bytesEqual(a, b) {
  if (crypto.subtle && typeof crypto.subtle.timingSafeEqual === 'function') {
    return crypto.subtle.timingSafeEqual(a, b);
  }
  // fallback, shouldnt really hit this on workers
  const x = new Uint8Array(a);
  const y = new Uint8Array(b);
  if (x.length !== y.length) return false;
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

// hash both first so the lengths always match
async function secretMatches(presented, expected) {
  if (!presented || !expected) return false;
  const [a, b] = await Promise.all([sha256(presented), sha256(expected)]);
  return bytesEqual(a, b);
}

function presentedSecret(request) {
  const header = request.headers.get('x-lock-secret');
  if (header) return header.trim();
  const auth = request.headers.get('authorization'); // bearer works too
  if (auth && /^bearer\s+/i.test(auth)) return auth.replace(/^bearer\s+/i, '').trim();
  return null;
}

// control = phone, device = esp32. esp32 can use DEVICE_SECRET if its set
// TODO rate limit /command at some point
async function authorize(request, env, role) {
  const control = env.SHARED_SECRET;
  if (!control) {
    throw new HttpError(500, 'server_unconfigured', { hint: 'wrangler secret put SHARED_SECRET' });
  }

  const presented = presentedSecret(request);
  if (!presented) {
    throw new HttpError(401, 'missing_secret', { hint: 'send header: X-Lock-Secret: <secret>' });
  }

  if (await secretMatches(presented, control)) return;
  if (role === 'device' && env.DEVICE_SECRET && (await secretMatches(presented, env.DEVICE_SECRET))) return;

  throw new HttpError(401, 'bad_secret');
}

function isLocalDev(hostname) {
  return hostname === 'localhost' || hostname === '127.0.0.1' || hostname === '[::1]' || hostname === '0.0.0.0';
}

const ROUTES = {
  'POST /command': 'control',
  'POST /toggle': 'control',
  'GET /state': 'control',
  'GET /poll': 'device',
  'POST /confirm': 'device',
  'GET /health': 'public',
};

export default {
  async fetch(request, env) {
    try {
      const url = new URL(request.url);

      // https only (except wrangler dev on localhost)
      if (url.protocol !== 'https:' && !isLocalDev(url.hostname)) {
        throw new HttpError(403, 'https_required');
      }

      const path = url.pathname.replace(/\/+$/, '') || '/';
      const key = request.method + ' ' + path;
      const role = ROUTES[key];

      if (!role) {
        if (path === '/') {
          return jsonResponse({ ok: true, service: 'dorm-lock', endpoints: Object.keys(ROUTES) });
        }
        throw new HttpError(404, 'not_found', { path, method: request.method });
      }

      if (path === '/health') return jsonResponse({ ok: true, now: new Date().toISOString() });

      await authorize(request, env, role);

      const id = env.LOCK.idFromName(env.LOCK_NAME || 'door');
      return await env.LOCK.get(id).fetch(request);
    } catch (err) {
      if (err instanceof HttpError) {
        return jsonResponse({ ok: false, error: err.code, ...err.extra }, err.status);
      }
      return jsonResponse({ ok: false, error: 'internal_error', detail: String((err && err.message) || err) }, 500);
    }
  },
};

// ================= durable object =================
// everything goes thru one DO so /command and /poll can see each other in memory

export class LockDO {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;

    this.pollWaiters = new Set(); // esp32 polls waiting
    this.cmdWaiters = new Map(); // id -> phones waiting on that cmd
    this.lastPollAt = 0; // not saved, fine if it resets

    this.pollTimeoutMs = clamp(toNum(env.POLL_TIMEOUT_MS, DEFAULTS.POLL_TIMEOUT_MS), 0, MAX_HOLD_MS);
    this.commandTimeoutMs = clamp(toNum(env.COMMAND_TIMEOUT_MS, DEFAULTS.COMMAND_TIMEOUT_MS), 0, MAX_HOLD_MS);
    this.commandTtlMs = Math.max(1000, toNum(env.COMMAND_TTL_MS, DEFAULTS.COMMAND_TTL_MS));
    this.strictStatus = String(env.STRICT_STATUS || '0') === '1';

    ctx.blockConcurrencyWhile(async () => {
      const stored = await ctx.storage.get('state');
      this.s = stored || {
        state: 'locked',
        lastCommandId: 0,
        lastConfirmedId: 0,
        pending: null, // {id, target, issuedAt}
        lastConfirm: null,
        idem: {},
      };
      if (!this.s.idem) this.s.idem = {}; // just in case
    });
  }

  save() {
    return this.ctx.storage.put('state', this.s);
  }

  waitForConfirm(commandId, ms) {
    return new Promise((resolve) => {
      let set = this.cmdWaiters.get(commandId);
      if (!set) {
        set = new Set();
        this.cmdWaiters.set(commandId, set);
      }
      const waiter = { resolve };
      waiter.timer = setTimeout(() => {
        set.delete(waiter);
        if (set.size === 0) this.cmdWaiters.delete(commandId);
        resolve({ status: 'timeout' });
      }, ms);
      set.add(waiter);
    });
  }

  releaseCommand(commandId, payload) {
    const set = this.cmdWaiters.get(commandId);
    if (!set) return;
    this.cmdWaiters.delete(commandId);
    for (const waiter of set) {
      clearTimeout(waiter.timer);
      waiter.resolve(payload);
    }
  }

  waitForCommand(afterId, ms) {
    return new Promise((resolve) => {
      const waiter = { afterId, resolve };
      waiter.timer = setTimeout(() => {
        this.pollWaiters.delete(waiter);
        resolve(null);
      }, ms);
      this.pollWaiters.add(waiter);
    });
  }

  wakePollers(command) {
    for (const waiter of [...this.pollWaiters]) {
      if (command.id > waiter.afterId) {
        this.pollWaiters.delete(waiter);
        clearTimeout(waiter.timer);
        waiter.resolve(command);
      }
    }
  }

  freshPending(now = Date.now()) {
    const p = this.s.pending;
    if (!p) return null;
    return now - p.issuedAt > this.commandTtlMs ? null : p;
  }

  // if nobody ran it before the ttl, kill it. otherwise the esp32 could
  // reconnect way later and unlock the door when nobody asked
  async reapExpired() {
    const p = this.s.pending;
    if (!p) return;
    if (Date.now() - p.issuedAt <= this.commandTtlMs) return;
    this.s.pending = null;
    this.s.lastConfirmedId = Math.max(this.s.lastConfirmedId, p.id);
    this.s.lastConfirm = {
      id: p.id,
      target: p.target,
      state: this.s.state,
      ok: false,
      at: Date.now(),
      detail: 'expired',
    };
    await this.save();
    this.releaseCommand(p.id, { status: 'expired' });
  }

  rememberIdem(requestId, commandId) {
    this.s.idem[requestId] = { id: commandId, at: Date.now() };
    const entries = Object.entries(this.s.idem).sort((a, b) => b[1].at - a[1].at);
    if (entries.length > IDEM_KEEP) {
      this.s.idem = Object.fromEntries(entries.slice(0, IDEM_KEEP));
    }
  }

  async fetch(request) {
    try {
      const url = new URL(request.url);
      const path = url.pathname.replace(/\/+$/, '') || '/';
      await this.reapExpired();

      if (request.method === 'POST' && path === '/command') return await this.handleCommand(request);
      if (request.method === 'POST' && path === '/toggle') return await this.handleToggle(request);
      if (request.method === 'GET' && path === '/poll') return await this.handlePoll(url);
      if (request.method === 'POST' && path === '/confirm') return await this.handleConfirm(request);
      if (request.method === 'GET' && path === '/state') return this.handleState();
      throw new HttpError(404, 'not_found');
    } catch (err) {
      if (err instanceof HttpError) {
        return jsonResponse({ ok: false, error: err.code, ...err.extra }, err.status);
      }
      return jsonResponse({ ok: false, error: 'internal_error', detail: String((err && err.message) || err) }, 500);
    }
  }

  async readJson(request) {
    let text;
    try {
      text = await request.text();
    } catch {
      throw new HttpError(400, 'unreadable_body');
    }
    if (!text.trim()) return {};
    let parsed;
    try {
      parsed = JSON.parse(text);
    } catch {
      throw new HttpError(400, 'invalid_json');
    }
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
      throw new HttpError(400, 'body_must_be_object');
    }
    return parsed;
  }

  async handleCommand(request) {
    const body = await this.readJson(request);
    const target = normalizeTarget(body.target !== undefined ? body.target : body.state);
    if (!target) {
      throw new HttpError(400, 'bad_target', {
        hint: 'body must be {"target":"locked"} or {"target":"unlocked"}',
      });
    }
    return this.issueCommand(target, body, {});
  }

  // toggle - the DO already knows the state so it can flip it itself. saves the phone a request
  async handleToggle(request) {
    const body = await this.readJson(request);
    const from = this.s.state;

    // flip from the last *confirmed* state, not whatever's pending.
    // that way a double tap doesnt flip it right back
    const target = from === 'locked' ? 'unlocked' : 'locked';
    return this.issueCommand(target, body, { from });
  }

  async issueCommand(target, body, extra) {
    const force = body.force === true;
    const requestId =
      typeof body.requestId === 'string' && body.requestId.trim() ? body.requestId.trim().slice(0, 64) : null;
    const waitMs = clamp(toNum(body.waitMs, this.commandTimeoutMs), 0, MAX_HOLD_MS);

    // retry w/ same requestId -> attach to the old cmd, dont make a new one
    const priorIdem = requestId ? this.s.idem[requestId] : null;
    if (priorIdem && Date.now() - priorIdem.at <= IDEM_TTL_MS) {
      const priorId = priorIdem.id;
      if (priorId <= this.s.lastConfirmedId) {
        return this.finishCommand(priorId, target, { status: this.replayStatus(priorId) }, { ...extra, replay: true });
      }
      return this.finishCommand(priorId, target, await this.waitForConfirm(priorId, waitMs), { ...extra, replay: true });
    }

    const pending = this.freshPending();

    // already in that state and nothing pending
    if (!force && !pending && this.s.state === target) {
      return jsonResponse({
        ok: true,
        status: 'already',
        state: this.s.state,
        target,
        commandId: this.s.lastConfirmedId,
        lastConfirmedId: this.s.lastConfirmedId,
        deviceConnected: this.pollWaiters.size > 0,
        ...extra,
      });
    }

    // same thing is already pending, just wait on that one
    if (pending && pending.target === target && !force) {
      if (requestId) {
        this.rememberIdem(requestId, pending.id);
        await this.save();
      }
      return this.finishCommand(pending.id, target, await this.waitForConfirm(pending.id, waitMs), { ...extra, joined: true });
    }

    // new cmd. kills the old pending one if there is one
    if (pending) this.releaseCommand(pending.id, { status: 'superseded' });

    const id = this.s.lastCommandId + 1;
    const issuedAt = Date.now();
    this.s.lastCommandId = id;
    this.s.pending = { id, target, issuedAt };
    if (requestId) this.rememberIdem(requestId, id);
    await this.save();
    this.wakePollers(this.s.pending);

    if (waitMs === 0) {
      return jsonResponse(
        {
          ok: true,
          status: 'queued',
          commandId: id,
          target,
          state: this.s.state,
          lastConfirmedId: this.s.lastConfirmedId,
          deviceConnected: this.pollWaiters.size > 0,
          ...extra,
        },
        202
      );
    }

    return this.finishCommand(id, target, await this.waitForConfirm(id, waitMs), extra);
  }

  replayStatus(commandId) {
    const lc = this.s.lastConfirm;
    if (lc && lc.id === commandId) {
      if (lc.ok) return 'confirmed';
      return lc.detail === 'expired' ? 'expired' : 'device_error';
    }
    // dont know what happened to it anymore. dont say confirmed if we dont actually know
    return 'unknown';
  }

  finishCommand(commandId, target, result, extra) {
    const ok = result.status === 'confirmed';
    let httpStatus = 200;
    if (!ok && this.strictStatus) {
      httpStatus = result.status === 'timeout' || result.status === 'expired' ? 504 : 409;
    }
    return jsonResponse(
      {
        ok,
        status: result.status,
        commandId,
        target,
        state: this.s.state,
        lastConfirmedId: this.s.lastConfirmedId,
        deviceConnected: this.pollWaiters.size > 0,
        detail: result.detail || null,
        ...extra,
      },
      httpStatus
    );
  }

  // ---- poll ----

  async handlePoll(url) {
    const afterId = Math.max(0, Math.floor(toNum(url.searchParams.get('after'), 0)));
    const waitMs = clamp(toNum(url.searchParams.get('wait'), this.pollTimeoutMs), 0, MAX_HOLD_MS);

    this.lastPollAt = Date.now();

    const pending = this.freshPending();
    if (pending && pending.id > afterId) return this.commandPayload(pending);
    if (waitMs === 0) return this.noCommand();

    const command = await this.waitForCommand(afterId, waitMs);
    this.lastPollAt = Date.now();
    return command ? this.commandPayload(command) : this.noCommand();
  }

  // esp32 can read these instead of parsing json
  stateHeaders() {
    return {
      'x-lock-state': this.s.state,
      'x-lock-command-id': String(this.s.lastCommandId),
      'x-lock-confirmed-id': String(this.s.lastConfirmedId),
    };
  }

  commandPayload(command) {
    return jsonResponse(
      {
        commandId: command.id,
        target: command.target,
        issuedAt: iso(command.issuedAt),
        expiresAt: iso(command.issuedAt + this.commandTtlMs),
        state: this.s.state,
        lastConfirmedId: this.s.lastConfirmedId,
      },
      200,
      this.stateHeaders()
    );
  }

  noCommand() {
    return new Response(null, { status: 204, headers: baseHeaders(this.stateHeaders()) });
  }

  // ---- confirm ----

  async handleConfirm(request) {
    const body = await this.readJson(request);
    const raw = body.commandId !== undefined ? body.commandId : body.id;
    const commandId = Math.floor(toNum(raw, NaN));
    if (!Number.isFinite(commandId) || commandId < 1) {
      throw new HttpError(400, 'bad_command_id', {
        hint: 'body must include {"commandId": <positive integer>}',
      });
    }

    const deviceOk = body.ok !== false && body.result !== 'error' && body.result !== 'fail';
    const reported = normalizeTarget(body.state);
    const detail = typeof body.detail === 'string' ? body.detail.slice(0, 200) : null;

    // already confirmed this id
    if (commandId <= this.s.lastConfirmedId) {
      const lc = this.s.lastConfirm;
      const lateExecution =
        reported && lc && lc.id === commandId && lc.ok === false && reported !== this.s.state;

      // edge case - we expired it but the esp32 did it anyway, so record what actually happened
      if (lateExecution) {
        this.s.state = reported;
        this.s.lastConfirm = {
          id: commandId,
          target: lc.target,
          state: reported,
          ok: false,
          at: Date.now(),
          detail: 'late_execution',
        };
        await this.save();
        return jsonResponse({
          ok: true,
          status: 'late',
          commandId,
          state: this.s.state,
          lastConfirmedId: this.s.lastConfirmedId,
          detail: 'late_execution',
        });
      }

      return jsonResponse({
        ok: true,
        status: 'duplicate',
        commandId,
        state: this.s.state,
        lastConfirmedId: this.s.lastConfirmedId,
      });
    }

    if (commandId > this.s.lastCommandId) {
      throw new HttpError(409, 'unknown_command', { commandId, lastCommandId: this.s.lastCommandId });
    }

    const pending = this.s.pending;
    let target;
    if (pending && pending.id === commandId) {
      target = pending.target;
    } else if (reported) {
      target = reported; // got reaped but the servo moved anyway
    } else {
      throw new HttpError(409, 'stale_command', {
        commandId,
        hint: 'command expired; resend with a "state" field so the worker can record reality',
      });
    }

    const mismatch = Boolean(reported) && reported !== target;
    const ok = deviceOk && !mismatch;
    const finalState = reported || target;

    if (deviceOk || reported) this.s.state = finalState;
    this.s.lastConfirmedId = commandId;
    this.s.pending = null;
    this.s.lastConfirm = {
      id: commandId,
      target,
      state: this.s.state,
      ok,
      at: Date.now(),
      detail: detail || (mismatch ? 'reported_state_mismatch' : null),
    };
    await this.save();

    this.releaseCommand(commandId, {
      status: ok ? 'confirmed' : 'device_error',
      detail: this.s.lastConfirm.detail,
    });

    return jsonResponse({
      ok,
      status: ok ? 'confirmed' : 'device_error',
      commandId,
      state: this.s.state,
      lastConfirmedId: this.s.lastConfirmedId,
      detail: this.s.lastConfirm.detail,
    });
  }

  handleState() {
    const now = Date.now();
    const pending = this.freshPending(now);
    return jsonResponse(
      {
        ok: true,
        state: this.s.state,
        lastCommandId: this.s.lastCommandId,
        lastConfirmedId: this.s.lastConfirmedId,
        pending: pending
          ? {
              commandId: pending.id,
              target: pending.target,
              issuedAt: iso(pending.issuedAt),
              expiresAt: iso(pending.issuedAt + this.commandTtlMs),
              ageMs: now - pending.issuedAt,
            }
          : null,
        lastConfirm: this.s.lastConfirm ? { ...this.s.lastConfirm, at: iso(this.s.lastConfirm.at) } : null,
        device: {
          connected: this.pollWaiters.size > 0,
          waitingPolls: this.pollWaiters.size,
          lastPollAt: iso(this.lastPollAt),
          secondsSinceLastPoll: this.lastPollAt ? Math.round((now - this.lastPollAt) / 1000) : null,
        },
        config: {
          pollTimeoutMs: this.pollTimeoutMs,
          commandTimeoutMs: this.commandTimeoutMs,
          commandTtlMs: this.commandTtlMs,
          strictStatus: this.strictStatus,
        },
        now: iso(now),
      },
      200,
      this.stateHeaders()
    );
  }
}
