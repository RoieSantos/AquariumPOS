// System Tests page logic (super users only) - a small in-portal test runner, built per direct
// request so fast-moving changes don't silently break existing features. Test suites live in
// docs/tests/*.js and register themselves with SystemTests.suite(...); this file only runs them
// and draws the results.
//
// Two kinds of suite:
//   - 'logic': pure functions with PINNED inputs/prices (no database) - e.g. the aquarium
//     calculator. Expected values are snapshots of today's correct behavior; if one fails after an
//     intentional pricing change, update the expected number in the test file.
//   - 'live': read-only checks against the real Supabase data/Edge Functions (pricing tables load,
//     website calculator and Alice quote the same price). Never writes anything.
//
// Adding a test: open the matching docs/tests/*.js file and add a t.test('...', (a) => {...}) -
// `a` has equal/near/ok/includes/skip helpers (see makeAsserts below).
let currentSession = null;

const SystemTests = (function () {
  const suites = [];

  class SkipTest extends Error {}
  // Worth a look, but not proof something is broken (e.g. a negative stock balance).
  class WarnTest extends Error {}

  function fmt(value) {
    if (typeof value === 'string') return JSON.stringify(value);
    try { return JSON.stringify(value); } catch { return String(value); }
  }

  function makeAsserts() {
    return {
      equal(actual, expected, label) {
        if (actual !== expected) {
          throw new Error(`${label ? label + ': ' : ''}expected ${fmt(expected)}, got ${fmt(actual)}`);
        }
      },
      // Money/measurements - equal within a tolerance (default 0.01).
      near(actual, expected, label, tolerance = 0.01) {
        if (typeof actual !== 'number' || Math.abs(actual - expected) > tolerance) {
          throw new Error(`${label ? label + ': ' : ''}expected ${fmt(expected)}, got ${fmt(actual)}`);
        }
      },
      ok(condition, message) {
        if (!condition) throw new Error(message || 'expected condition to be true');
      },
      includes(text, fragment, label) {
        if (String(text || '').toLowerCase().indexOf(String(fragment).toLowerCase()) < 0) {
          throw new Error(`${label ? label + ': ' : ''}expected ${fmt(text)} to contain ${fmt(fragment)}`);
        }
      },
      skip(reason) {
        throw new SkipTest(reason || 'skipped');
      },
      warn(message) {
        throw new WarnTest(message || 'warning');
      }
    };
  }

  // SystemTests.suite('Name', { kind: 'logic' | 'live', description }, (t) => { t.test(...) })
  // With options.load (async, returns [{ name, fn }]) the tests are built at run time instead -
  // e.g. one test per row the database check function returns. options.loadLabel names the
  // placeholder test shown before the first run (and holds the error if loading fails).
  function suite(name, options, define) {
    const entry = { name, kind: options.kind || 'logic', description: options.description || '', tests: [], load: options.load || null };
    if (entry.load) {
      entry.tests.push({ name: options.loadLabel || 'Load checks', fn: async () => {} });
    } else {
      define({
        test(testName, fn) { entry.tests.push({ name: testName, fn }); }
      });
    }
    suites.push(entry);
  }

  // Builds a dynamic suite's tests; a loading error becomes one failed test.
  async function prepareSuite(entry) {
    if (!entry.load) return;
    try {
      const tests = await entry.load();
      entry.tests = tests.length ? tests : [{ name: 'No checks returned', fn: (a) => a.skip('Nothing to check.') }];
    } catch (err) {
      const message = err && err.message ? err.message : String(err);
      entry.tests = [{ name: 'Load checks', fn: () => { throw new Error(message); } }];
    }
  }

  async function runTest(test) {
    const started = performance.now();
    try {
      await test.fn(makeAsserts());
      return { status: 'pass', ms: performance.now() - started };
    } catch (err) {
      const ms = performance.now() - started;
      if (err instanceof SkipTest) return { status: 'skip', message: err.message, ms };
      if (err instanceof WarnTest) return { status: 'warn', message: err.message, ms };
      return { status: 'fail', message: err && err.message ? err.message : String(err), ms };
    }
  }

  return { suites, suite, runTest, prepareSuite };
})();
window.SystemTests = SystemTests;

// ---- Helpers shared by the test files ----

// RPC as the logged-in super user (admin_* functions take the login as their first two params).
async function callAdminRpc(name, params = {}) {
  return supabaseClient.rpc(name, {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    ...params
  });
}

// Edge Function POST as the logged-in super user.
async function callEdgeFunctionAsAdmin(name, payload) {
  const response = await fetch(`${window.APP_CONFIG.SUPABASE_URL}/functions/v1/${name}`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${window.APP_CONFIG.SUPABASE_ANON_KEY}`,
      'apikey': window.APP_CONFIG.SUPABASE_ANON_KEY
    },
    body: JSON.stringify({ admin_username: currentSession.username, admin_password: currentSession.password, ...payload })
  });
  const body = await response.json().catch(() => ({}));
  return { status: response.status, body };
}

// One read-only bot tool run exactly as Alice runs it (chatbot-sandbox-reply's tool_test mode).
async function callSandboxToolTest(name, input) {
  return callEdgeFunctionAsAdmin('chatbot-sandbox-reply', { tool_test: { name, input } });
}

// Shared skip for tests that need the redeployed chatbot-sandbox-reply.
function skipIfToolTestNotDeployed(a, status, body) {
  if (status === 400 && /Body must be JSON|tool_test only supports/.test(body.error || '')) {
    a.skip('chatbot-sandbox-reply has not been redeployed with this tool_test yet.');
  }
}

// ---- UI ----

let lastResults = [];

function escapeHtml(text) {
  return String(text ?? '').replace(/[&<>"']/g, (ch) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]));
}

const STATUS_BADGE = {
  pass: '<span class="badge badge-success">Pass</span>',
  fail: '<span class="badge badge-danger">Fail</span>',
  warn: '<span class="badge badge-warning">Warning</span>',
  skip: '<span class="badge badge-neutral">Skipped</span>',
  pending: '<span class="badge badge-primary">Running…</span>',
  idle: '<span class="badge badge-neutral">Not run</span>'
};

function selectedSuites() {
  const kind = document.getElementById('suiteKindSelect').value;
  return SystemTests.suites.filter((s) => kind === 'all' || s.kind === kind);
}

function renderSuites(results) {
  const onlyFailures = document.getElementById('onlyFailuresCheck').checked;
  const container = document.getElementById('suitesContainer');
  const byKey = new Map(results.map((r) => [`${r.suite}::${r.test}`, r]));

  container.innerHTML = selectedSuites().map((s) => {
    const rows = s.tests.map((test) => {
      const r = byKey.get(`${s.name}::${test.name}`) || { status: 'idle' };
      if (onlyFailures && r.status !== 'fail' && r.status !== 'warn') return '';
      return `<tr class="st-row st-${r.status}">
        <td>${STATUS_BADGE[r.status]}</td>
        <td>${escapeHtml(test.name)}${r.message ? `<div class="st-message">${escapeHtml(r.message)}</div>` : ''}</td>
        <td class="st-ms">${r.ms !== undefined ? Math.round(r.ms) + ' ms' : ''}</td>
      </tr>`;
    }).join('');
    if (onlyFailures && !rows) return '';

    const suiteResults = s.tests.map((test) => byKey.get(`${s.name}::${test.name}`)).filter(Boolean);
    const failed = suiteResults.filter((r) => r.status === 'fail').length;
    const warned = suiteResults.filter((r) => r.status === 'warn').length;
    const passed = suiteResults.filter((r) => r.status === 'pass').length;
    const summary = suiteResults.length
      ? `${passed}/${s.tests.length} passed${failed ? `, ${failed} failed` : ''}${warned ? `, ${warned} warning${warned === 1 ? '' : 's'}` : ''}`
      : (s.load ? 'loads when run' : `${s.tests.length} tests`);

    return `<div class="card st-suite">
      <div class="st-suite-head">
        <div>
          <div class="st-suite-title">${escapeHtml(s.name)} <span class="badge ${s.kind === 'live' ? 'badge-purple' : 'badge-glass'}">${s.kind === 'live' ? 'Live data' : 'Logic'}</span></div>
          ${s.description ? `<div class="muted st-suite-desc">${escapeHtml(s.description)}</div>` : ''}
        </div>
        <div class="muted">${summary}</div>
      </div>
      <div class="table-wrap"><table>
        <thead><tr><th style="width:110px;">Result</th><th>Test</th><th style="width:80px;">Time</th></tr></thead>
        <tbody>${rows}</tbody>
      </table></div>
    </div>`;
  }).join('') || '<p class="muted">Nothing to show.</p>';
}

function renderSummary(results, totalMs) {
  const el = document.getElementById('runSummary');
  if (!results.length) { el.innerHTML = ''; return; }
  const count = (status) => results.filter((r) => r.status === status).length;
  const failed = count('fail');
  const warned = count('warn');
  el.innerHTML = `<div class="stat-card-grid">
    <div class="stat-card"><div class="stat-label">Result</div><div class="stat-value" style="color:var(${failed ? '--danger' : '--success'})">${failed ? 'Something broke' : (warned ? 'OK, with warnings' : 'All good')}</div></div>
    <div class="stat-card"><div class="stat-label">Passed</div><div class="stat-value">${count('pass')}</div></div>
    <div class="stat-card"><div class="stat-label">Failed</div><div class="stat-value">${failed}</div></div>
    <div class="stat-card"><div class="stat-label">Warnings</div><div class="stat-value">${warned}</div></div>
    <div class="stat-card"><div class="stat-label">Skipped</div><div class="stat-value">${count('skip')}</div></div>
  </div>
  <p class="muted">Finished in ${(totalMs / 1000).toFixed(1)}s · ${new Date().toLocaleString()}</p>`;
  document.getElementById('copyFailuresBtn').classList.toggle('hidden', !failed && !warned);
}

async function runAll() {
  const btn = document.getElementById('runAllBtn');
  btn.disabled = true;
  const started = performance.now();
  const results = [];
  lastResults = results;

  // Mark everything selected as running first, then fill in as each finishes. Suites run one
  // after another; tests inside a suite run one at a time too, so live checks never stampede
  // the database or Edge Functions.
  let pending = selectedSuites().flatMap((s) => s.tests.map((test) => ({ suite: s.name, test: test.name, status: 'pending' })));
  renderSuites(pending);

  for (const s of selectedSuites()) {
    if (s.load) {
      await SystemTests.prepareSuite(s);
      pending = selectedSuites().flatMap((x) => x.tests.map((test) => ({ suite: x.name, test: test.name, status: 'pending' })));
    }
    for (const test of s.tests) {
      const result = await SystemTests.runTest(test);
      results.push({ suite: s.name, test: test.name, ...result });
      const done = new Set(results.map((r) => `${r.suite}::${r.test}`));
      renderSuites([...results, ...pending.filter((p) => !done.has(`${p.suite}::${p.test}`))]);
    }
  }

  renderSummary(results, performance.now() - started);
  btn.disabled = false;
}

function copyFailures() {
  const text = lastResults
    .filter((r) => r.status === 'fail' || r.status === 'warn')
    .map((r) => `${r.status === 'fail' ? 'FAIL' : 'WARN'} [${r.suite}] ${r.test}\n  ${r.message}`)
    .join('\n');
  navigator.clipboard.writeText(text).then(() => {
    const btn = document.getElementById('copyFailuresBtn');
    const label = btn.textContent;
    btn.textContent = 'Copied!';
    setTimeout(() => { btn.textContent = label; }, 1500);
  });
}

// Waits for DOMContentLoaded so every docs/tests/*.js file (loaded after this one) has registered
// its suites before the list is drawn.
document.addEventListener('DOMContentLoaded', async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('System Tests');

  if (!session.isSuperUser) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }

  if (!session.password) {
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = 'Please log out and log back in to run the live System Tests.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  document.getElementById('setupContent').classList.remove('hidden');
  document.getElementById('runAllBtn').addEventListener('click', runAll);
  document.getElementById('copyFailuresBtn').addEventListener('click', copyFailures);
  document.getElementById('onlyFailuresCheck').addEventListener('change', () => renderSuites(lastResults));
  document.getElementById('suiteKindSelect').addEventListener('change', () => { lastResults = []; renderSummary([], 0); renderSuites([]); });
  renderSuites([]);
});
