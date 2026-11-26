import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';

// This file is installed beside the hooks, with no node_modules; everything resolves from the project.
const project = createRequire(path.join(process.cwd(), 'package.json'));
const core = createRequire(project.resolve('@stryker-mutator/core/package.json'));
const load = (req, id) => import(pathToFileURL(req.resolve(id)).href);
const { declareFactoryPlugin, PluginKind, commonTokens, tokens } = await load(core, '@stryker-mutator/api/plugin');
const { DryRunStatus, TestStatus, toMutantRunResult, MutantRunStatus } = await load(core, '@stryker-mutator/api/test-runner');
const { INSTRUMENTER_CONSTANTS } = await load(core, '@stryker-mutator/api/core');
const stockDir = path.dirname(project.resolve('@stryker-mutator/vitest-runner/package.json'));
const { VitestTestRunner } = await import(pathToFileURL(path.join(stockDir, 'dist/src/vitest-test-runner.js')).href);

const WORKER = new URL('./stryker-batch-worker.mjs', import.meta.url);
const HIT_LIMIT_FACTOR = 100;
// Share of the dry run's own timeout the batch may use; what it leaves runs the stock way.
const BUDGET_SHARE = 0.5;

const fileOf = (testId) => testId.split('#')[0];

function mutantIndex(coverage) {
  const index = new Map();
  for (const [testId, hits] of Object.entries(coverage.perTest)) {
    for (const [id, n] of Object.entries(hits)) {
      const m = index.get(id) ?? { id, tests: [], hitLimit: (coverage.static[id] ?? 0) * HIT_LIMIT_FACTOR };
      m.tests.push(testId);
      m.hitLimit += n * HIT_LIMIT_FACTOR;
      index.set(id, m);
    }
  }
  return [...index.values()];
}

function mergeFiles(files) {
  const merged = {};
  for (const file of files) {
    for (const [id, r] of Object.entries(file.meta.strykerBatch ?? {})) {
      const into = (merged[id] ??= { killedBy: [], timeout: false, ran: [] });
      into.killedBy.push(...r.killedBy);
      into.ran.push(...r.ran);
      into.timeout ||= r.timeout;
    }
  }
  return merged;
}

function toResult(r) {
  if (r.timeout) return { status: MutantRunStatus.Timeout, reason: 'Hit limit reached (batch)' };
  const tests = r.killedBy.length
    ? r.killedBy.map((k) => ({ id: k.name, name: k.name, status: TestStatus.Failed, failureMessage: k.message, timeSpentMs: 0 }))
    : r.ran.map((name) => ({ id: name, name, status: TestStatus.Success, timeSpentMs: 0 }));
  return toMutantRunResult({ status: DryRunStatus.Complete, tests });
}

/** Answers every covered mutant right after the dry run, in one load per test file. */
class VitestBatchRunner extends VitestTestRunner {
  static inject = tokens(commonTokens.options, commonTokens.logger, 'globalNamespace');

  async init() {
    await super.init();
    this.results = path.resolve('.stryker-batch.json');
    // Vite cannot always load a runner from outside the project, so it is copied into the sandbox.
    const local = path.resolve(`stryker-batch-worker-${process.env.STRYKER_MUTATOR_WORKER ?? 0}.mjs`);
    fs.copyFileSync(WORKER, local);
    this.ctx.projects.forEach((p) => (p.config.runner = local));
  }

  async withWorkers(fn) {
    const before = { maxWorkers: this.ctx.config.maxWorkers, bail: this.ctx.config.bail };
    this.ctx.config.maxWorkers = Math.max(1, this.options.concurrency ?? 1);
    try {
      return await fn();
    } finally {
      Object.assign(this.ctx.config, before);
    }
  }

  async dryRun(options) {
    const result = await this.withWorkers(() => super.dryRun(options));
    if (result.status === DryRunStatus.Complete && result.mutantCoverage) {
      await this.withWorkers(() => this.runBatch(result, Date.now() + options.timeout * BUDGET_SHARE));
    }
    return result;
  }

  async runBatch(dry, deadline) {
    const batch = mutantIndex(dry.mutantCoverage);
    this.ctx.provide('mode', 'batch');
    this.ctx.provide('strykerBatch', batch);
    this.ctx.provide('strykerBatchTimes', Object.fromEntries(dry.tests.map((t) => [t.id, t.timeSpentMs])));
    this.ctx.provide('strykerBatchDeadline', deadline);
    this.ctx.config.bail = 0;
    await this.run({ testFiles: [...new Set(batch.flatMap((m) => m.tests.map(fileOf)))] });
    this.saveResults(batch);
  }

  saveResults(batch) {
    const files = this.ctx.state.getFiles();
    const merged = mergeFiles(files);
    const done = {};
    for (const m of batch) {
      const r = merged[m.id];
      if (r && (r.timeout || r.killedBy.length || r.ran.length === m.tests.length)) done[m.id] = r;
    }
    fs.writeFileSync(this.results, JSON.stringify(done));
    this.log.info(`Batch answered ${Object.keys(done).length} of ${batch.length} covered mutants.`);
    const leaks = [...new Set(files.flatMap((f) => f.meta.strykerLeaks ?? []))];
    if (leaks.length) this.log.warn(`${leaks.length} test(s) leak state between repeats, so their mutants run the stock way:\n  ${leaks.join('\n  ')}`);
  }

  async mutantRun(options) {
    this.done ??= fs.existsSync(this.results) ? JSON.parse(fs.readFileSync(this.results, 'utf8')) : {};
    const r = this.done[options.activeMutant.id];
    return r ? toResult(r) : super.mutantRun(options);
  }
}

function create(injector) {
  return injector.provideValue('globalNamespace', INSTRUMENTER_CONSTANTS.NAMESPACE).injectClass(VitestBatchRunner);
}
create.inject = tokens(commonTokens.injector);

export const strykerPlugins = [declareFactoryPlugin(PluginKind.TestRunner, 'vitest-batch', create)];
