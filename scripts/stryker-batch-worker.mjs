import * as vitest from 'vitest';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';

const { inject } = vitest;
const vitestDist = path.join(path.dirname(createRequire(path.join(process.cwd(), 'package.json')).resolve('vitest/package.json')), 'dist');

/** Vitest 4 exports these; Vitest 5 only has them inside a hashed chunk, found by its export line. */
async function vitestInternals() {
  // Built names keep Vite from resolving Vitest 4 paths that Vitest 5 no longer exports.
  const v4 = (name) => import(/* @vite-ignore */ ['vitest', name].join('/'));
  try {
    const [runners, suite] = await Promise.all([v4('runners'), v4('suite')]);
    return { Base: runners.VitestTestRunner, getFn: suite.getFn };
  } catch {
    const chunks = path.join(vitestDist, 'chunks');
    for (const f of fs.readdirSync(chunks)) {
      const m = fs.readFileSync(path.join(chunks, f), 'utf8').match(/\bgetFn as (\w+)\b/);
      if (m) return { Base: vitest.TestRunner, getFn: (await import(pathToFileURL(path.join(chunks, f)).href))[m[1]] };
    }
    return { Base: vitest.TestRunner, getFn: undefined };
  }
}

const { Base, getFn } = await vitestInternals();

// A repeat with no mutant on; if it fails, state from earlier repeats is leaking.
const CONTROL = null;

const HANG_FACTOR = 5;  // a repeat this many times slower than its dry run, plus the floor, is hung
const HANG_FLOOR_MS = 1000;

class Hang extends Error {}

const ns = () => globalThis[inject('globalNamespace')] ?? (globalThis[inject('globalNamespace')] = {});

function testId(test) {
  const parts = [test.name];
  for (let s = test.suite; s; s = s.suite) parts.unshift(s.name);
  return `${path.relative(process.cwd(), test.file.filepath).replace(/\\/g, '/')}#${parts.join(' ').trim()}`;
}

/** Runs each batched mutant as one repeat of a test, followed by a control repeat with none. */
export default class BatchRunner extends Base {
  plans = new Map();
  killed = new Set();

  onCollected(files) {
    if (inject('mode') === 'batch' && typeof getFn === 'function') {
      this.batch = inject('strykerBatch');
      this.limits = Object.fromEntries(this.batch.map((m) => [m.id, m.hitLimit]));
      this.times = inject('strykerBatchTimes');
      this.deadline = inject('strykerBatchDeadline');
    }
    return super.onCollected?.(files);
  }

  async onBeforeRunTask(test) {
    await super.onBeforeRunTask(test);
    if (!this.batch || test.mode !== 'run') return;
    const id = testId(test);
    const todo = this.batch.filter((m) => m.tests.includes(id) && !this.killed.has(m.id)).map((m) => m.id);
    if (todo.length === 0 || test.repeats) {
      test.mode = 'skip';
      return;
    }
    const steps = todo.flatMap((m) => [m, CONTROL]);
    test.repeats = steps.length - 1;
    this.plans.set(test, { id, steps, pending: null, poisoned: false, hung: false, hangMs: HANG_FLOOR_MS + HANG_FACTOR * (this.times[id] ?? 0) });
  }

  onBeforeTryTask(test, opts) {
    super.onBeforeTryTask(test, opts);
    const p = this.plans.get(test);
    if (!p) return;
    const id = p.steps[opts.repeats];
    const n = ns();
    n.activeMutant = id ?? undefined;
    n.hitLimit = id ? this.limits[id] : undefined;
    n.hitCount = n.hitLimit === undefined ? undefined : 0;
    p.errorsBefore = test.result?.errors?.length ?? 0;
  }

  async batchRunTask(test) {
    const p = this.plans.get(test);
    if (!p) return getFn(test)();
    const left = this.deadline - Date.now();
    if (left <= 0) p.poisoned = true;
    if (p.poisoned) return;
    const ms = Math.min(p.hangMs, left);
    let timer;
    const hang = new Promise((_, reject) => (timer = setTimeout(() => reject(new Hang(`batch: no answer in ${ms}ms`)), ms)));
    try {
      await Promise.race([getFn(test)(), hang]);
    } catch (e) {
      if (e instanceof Hang) p.hung = true;
      throw e;
    } finally {
      clearTimeout(timer);
    }
  }

  async onAfterRetryTask(test, opts) {
    await super.onAfterRetryTask?.(test, opts);
    const p = this.plans.get(test);
    if (!p || p.poisoned) return;
    const n = ns();
    const id = p.steps[opts.repeats];
    const errors = test.result?.errors ?? [];
    const failed = errors.length > p.errorsBefore;
    const timeout = n.hitLimit !== undefined && n.hitCount > n.hitLimit;
    n.activeMutant = undefined;
    if (p.hung) {
      p.poisoned = true;
      (test.file.meta.strykerLeaks ??= []).push(`${p.id} (hung)`);
    } else if (id !== CONTROL) {
      p.pending = { id, failed, timeout, message: errors.at(-1)?.message ?? 'failed' };
    } else if (failed) {
      p.poisoned = true;
      (test.file.meta.strykerLeaks ??= []).push(p.id);
    } else {
      this.commit(test.file.meta, p.id, p.pending);
    }
  }

  commit(meta, name, { id, failed, timeout, message }) {
    const r = ((meta.strykerBatch ??= {})[id] ??= { killedBy: [], timeout: false, ran: [] });
    r.ran.push(name);
    if (timeout) r.timeout = true;
    else if (failed) r.killedBy.push({ name, message });
    if (timeout || failed) this.killed.add(id);
  }
}

// Without getFn the runner cannot wrap a test, so it leaves running tests to Vitest and never batches.
if (typeof getFn === 'function') BatchRunner.prototype.runTask = BatchRunner.prototype.batchRunTask;
