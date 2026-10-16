// Runs the toolkit scripts as child processes: one at a time, with a timeout, cancellation, a bounded output
// buffer and retention of finished runs.
import { spawn as nodeSpawn, spawnSync } from 'node:child_process';
import crypto from 'node:crypto';

export class RunManager {
  constructor({
    cwd, env = process.env, isWin = process.platform === 'win32',
    timeoutMs = 2 * 3_600_000, maxOutputBytes = 2 * 1024 * 1024, maxRuns = 20, retainMs = 6 * 3_600_000,
    spawn = nodeSpawn, now = Date.now,
  }) {
    Object.assign(this, { cwd, env, isWin, timeoutMs, maxOutputBytes, maxRuns, retainMs, spawn, now });
    this.runs = new Map();
  }

  active() {
    for (const r of this.runs.values()) if (r.status === 'running') return r;
    return null;
  }

  // Returns the run, or { busy: run } when another run is still going.
  start(kind, cmd, args, { user = '' } = {}) {
    const current = this.active();
    if (current) return { busy: current };
    this.prune();

    const run = {
      id: crypto.randomUUID(), kind, user,
      command: [cmd, ...args].join(' '),
      status: 'running', exitCode: null, signal: null, cancelled: false, timedOut: false,
      startedAt: this.now(), endedAt: null,
      chunks: [], bytes: 0, base: 0, // base = number of bytes already dropped from the front
      child: null, timer: null,
    };
    this.runs.set(run.id, run);

    let child;
    try {
      // stdin is closed: a script that asks for input fails immediately instead of hanging forever.
      child = this.spawn(cmd, args, {
        cwd: this.cwd, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'],
        detached: !this.isWin, // own process group so the whole tree can be signalled on POSIX
        env: { ...this.env, PYTHONIOENCODING: 'utf-8' },
      });
    } catch (e) {
      this.finish(run, { error: e });
      return run;
    }
    run.child = child;

    child.stdout?.on('data', (d) => this.append(run, d));
    child.stderr?.on('data', (d) => this.append(run, d));
    child.on('error', (e) => this.finish(run, { error: e }));
    child.on('close', (code, signal) => this.finish(run, { code, signal }));

    run.timer = setTimeout(() => {
      run.timedOut = true;
      this.append(run, `\n[wizard] Run exceeded ${Math.round(this.timeoutMs / 60000)} minutes and was stopped.\n`);
      this.kill(run);
    }, this.timeoutMs);
    run.timer.unref?.();
    return run;
  }

  append(run, data) {
    const text = Buffer.isBuffer(data) ? data.toString('utf8') : String(data);
    if (!text) return;
    run.chunks.push(text);
    run.bytes += Buffer.byteLength(text);
    // Keep the newest maxOutputBytes: drop whole chunks from the front.
    while (run.bytes > this.maxOutputBytes && run.chunks.length > 1) {
      const dropped = run.chunks.shift();
      const n = Buffer.byteLength(dropped);
      run.bytes -= n;
      run.base += n;
    }
  }

  finish(run, { code = null, signal = null, error = null }) {
    if (run.status !== 'running') return;
    clearTimeout(run.timer);
    if (error) this.append(run, `\n[wizard] Could not run the command: ${error.message}\n`);
    run.exitCode = code;
    run.signal = signal;
    run.endedAt = this.now();
    if (error || run.timedOut) run.status = 'failed';
    else if (run.cancelled) run.status = 'cancelled';
    else run.status = code === 0 ? 'succeeded' : 'failed';
    run.child = null;
  }

  kill(run) {
    const child = run.child;
    if (!child || !child.pid) return;
    try {
      if (this.isWin) spawnSync('taskkill', ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true, timeout: 10_000 });
      else process.kill(-child.pid, 'SIGTERM');
    } catch { /* already gone */ }
    // Escalate if it ignores the polite signal.
    const hard = setTimeout(() => {
      try { if (!this.isWin && run.status === 'running') process.kill(-child.pid, 'SIGKILL'); } catch { /* gone */ }
    }, 5000);
    hard.unref?.();
  }

  cancel(id) {
    const run = this.runs.get(id);
    if (!run) return null;
    if (run.status === 'running') {
      run.cancelled = true;
      this.append(run, '\n[wizard] Run cancelled by the user.\n');
      this.kill(run);
    }
    return run;
  }

  // Output from absolute byte offset `from`. If that part was already dropped, resumes at the oldest kept byte.
  read(id, from = 0) {
    const run = this.runs.get(id);
    if (!run) return null;
    const text = run.chunks.join('');
    const start = Math.max(0, Number.isFinite(from) ? from : 0);
    const total = run.base + Buffer.byteLength(text);
    let output = '';
    let truncated = false;
    if (start < run.base) truncated = true;
    const rel = Math.max(0, start - run.base);
    output = rel === 0 ? text : Buffer.from(text).subarray(rel).toString('utf8');
    return { run, output, offset: total, truncated };
  }

  prune() {
    const t = this.now();
    for (const [id, r] of this.runs) {
      if (r.status !== 'running' && t - (r.endedAt ?? t) > this.retainMs) this.runs.delete(id);
    }
    while (this.runs.size >= this.maxRuns) {
      const oldestDone = [...this.runs.values()].find((r) => r.status !== 'running');
      if (!oldestDone) break;
      this.runs.delete(oldestDone.id);
    }
  }

  // Stops anything still running (graceful shutdown).
  stopAll() {
    for (const r of this.runs.values()) if (r.status === 'running') { r.cancelled = true; this.kill(r); }
  }

  view(run) {
    return {
      id: run.id, kind: run.kind, command: run.command, status: run.status, exitCode: run.exitCode,
      startedAt: run.startedAt, endedAt: run.endedAt, timedOut: run.timedOut,
    };
  }

  list() {
    return [...this.runs.values()].sort((a, b) => b.startedAt - a.startedAt).map((r) => this.view(r));
  }
}
