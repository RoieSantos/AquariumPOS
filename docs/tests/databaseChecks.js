// System Tests - live, READ-ONLY health checks of the database and deployment.
//
//   * Order statuses / Inventory / Background jobs / Database functions: one test per row of
//     admin_run_system_checks (sql/supabase_system_checks.sql). Add new data checks THERE, not here.
//   * Portal wiring: crawls the portal's own pages and scripts (starting from the menu) and checks
//     that every page link exists, every database function (RPC) they call exists, and every Edge
//     Function they call is deployed - so a renamed page, an un-run .sql file or an un-deployed
//     function shows up here instead of as a broken button.
(function () {
  // ---- admin_run_system_checks: one call per run, shared by the four section suites ----
  let checksCache = null; // { at, promise }
  function loadSystemChecks() {
    if (!checksCache || Date.now() - checksCache.at > 30000) {
      const promise = callAdminRpc('admin_run_system_checks').then(({ data, error }) => {
        if (error) {
          if (error.code === 'PGRST202') throw new Error('admin_run_system_checks is not in the database yet - run sql/supabase_system_checks.sql.');
          throw new Error(error.message);
        }
        return data || [];
      });
      checksCache = { at: Date.now(), promise };
      promise.catch(() => { checksCache = null; });
    }
    return checksCache.promise;
  }

  function rowToTest(row) {
    return {
      name: row.check_name,
      fn: (a) => {
        if (row.status === 'fail') throw new Error(row.detail);
        if (row.status === 'warn') a.warn(row.detail);
      }
    };
  }

  [
    ['Order statuses', 'Order status rules hold in the live data (Assigned, To Ship gate, serial reservations, Pancake pushes).'],
    ['Inventory', 'Item ledger and serial tracking are consistent (sales posted, queue moving, no orphan or negative stock).'],
    ['Facebook posts', 'Delivery Done and ship posts to the GMA / Amaya Pages: none stuck "being posted", none failed without a retry, every Done delivery posted.'],
    ['Background jobs', 'Every scheduled job (Pancake syncs, ledger posting, follow-ups...) ran recently and its last run succeeded.'],
    ['Database functions', 'The newest version of each often-changed SQL function is the one installed (an older .sql file did not overwrite it).']
  ].forEach(([section, description]) => {
    SystemTests.suite(`${section} (live)`, {
      kind: 'live',
      description,
      loadLabel: 'Load checks from the database',
      load: async () => (await loadSystemChecks()).filter((row) => row.section === section).map(rowToTest)
    });
  });

  // ---- Facebook Page tokens (facebook-token-health: read-only Graph API GETs, never posts) ----
  const EXPIRY_WARN_DAYS = 14;
  SystemTests.suite('Facebook tokens (live)', {
    kind: 'live',
    description: 'Every Page token for auto-posting (GMA, Amaya) and for Alice\'s Messenger replies is valid, belongs to the right Page, has the permission it needs and isn\'t about to expire. Nothing is posted.',
    loadLabel: 'Check tokens with Facebook',
    load: async () => {
      const { status, body } = await callEdgeFunctionAsAdmin('facebook-token-health', {});
      if (status === 404) throw new Error('facebook-token-health is not deployed yet.');
      if (status !== 200 || !Array.isArray(body.tokens)) throw new Error(`facebook-token-health failed (${status}): ${body.error || 'no response'}`);
      return body.tokens.map((tk) => ({
        name: tk.label + (tk.page_name ? ` - ${tk.page_name}` : ''),
        fn: (a) => {
          a.ok(tk.configured, `${tk.error || 'Secret not set.'} (Supabase > Edge Functions > Secrets)`);
          a.ok(tk.valid, `Facebook rejected the token: ${tk.error || 'invalid'} - generate a new Page token.`);
          a.ok(tk.page_matches !== false, `Token belongs to a different Page (${tk.page_name || '?'}) than the Page ID secret says.`);
          a.ok(!tk.missing_scopes || tk.missing_scopes.length === 0, `Token is missing permission: ${(tk.missing_scopes || []).join(', ')}`);
          const soon = (iso) => iso && iso !== 'never' && new Date(iso).getTime() - Date.now() < EXPIRY_WARN_DAYS * 86400000;
          if (soon(tk.expires_at)) a.warn(`Token expires ${new Date(tk.expires_at).toLocaleString()} - replace it before then.`);
          if (soon(tk.data_access_expires_at)) a.warn(`Facebook data access for this token ends ${new Date(tk.data_access_expires_at).toLocaleString()} - re-authorize the app before then.`);
          if (tk.missing_scopes === null) a.warn('Token works, but Facebook would not list its permissions - posting permission could not be confirmed.');
        }
      }));
    }
  });

  // ---- Portal wiring crawl ----
  const EXTRA_START_PAGES = [
    'index.html', 'staff-login.html', 'dashboard.html', 'order-now.html', 'pin-location.html', 'track-driver.html',
    'WebAquariumCalculator/index.html', 'WebAquariumCalculator/stand.html', 'WebAquariumCalculator/sticker.html'
  ];
  const MAX_PAGES = 200;

  let crawlPromise = null;
  function crawlPortal() {
    if (crawlPromise) return crawlPromise;
    crawlPromise = (async () => {
      const superUser = { username: 'system-test', password: 'x', staffRoles: [], isSuperUser: true };
      const start = [...window.SystemTestsMenuPagesFor(superUser), ...EXTRA_START_PAGES];
      const pages = new Map();   // page path -> { ok, status, from }
      const scripts = new Map(); // script path -> text
      const rpcs = new Set();
      const edgeFunctions = new Set();
      const queue = start.map((page) => ({ page, from: 'menu' }));

      // Page/script paths relative to the portal root (docs/), e.g. "WebAquariumCalculator/index.html".
      const portalRoot = new URL('.', location.href).pathname;
      const toPortalPath = (base, ref) => {
        const url = new URL(ref, new URL(base, location.href));
        if (url.origin !== location.origin || !url.pathname.startsWith(portalRoot)) return null;
        return decodeURIComponent(url.pathname.slice(portalRoot.length));
      };

      // Comments mention files ("see docs/x.html", "supabaseClient.rpc('old_name')") - not real calls.
      const stripComments = (text) => text
        .replace(/<!--[\s\S]*?-->/g, '')
        .replace(/\/\*[\s\S]*?\*\//g, '')
        .replace(/(^|[\s;{}(),])\/\/.*$/gm, '$1');

      // pageBase = the page the code runs in: a script's 'x.html' resolves against its page, not js/.
      // Returns the .js paths the code names (scripts loaded at run time, e.g. nav.js -> 'js/chat.js').
      function scan(rawText, pageBase, source) {
        const text = stripComments(rawText);
        const jsRefs = [...text.matchAll(/['"`]((?:\.\.\/)?js\/[A-Za-z0-9_.-]+\.js)(?:\?[^'"`]*)?['"`]/g)]
          .map((m) => toPortalPath(pageBase, m[1])).filter(Boolean);
        for (const m of text.matchAll(/\b\w*[rR]pc\w*\(\s*['"`]([a-z][a-z0-9_]+)['"`]/g)) rpcs.add(m[1]);
        for (const m of text.matchAll(/functions\/v1\/([a-z0-9-]+)/g)) edgeFunctions.add(m[1]);
        for (const m of text.matchAll(/['"`(=]([A-Za-z0-9_/.-]+\.html)(?:[?#][^'"`)\s]*)?['"`)]/g)) {
          const path = toPortalPath(pageBase, m[1]);
          if (path && !pages.has(path) && !queue.some((q) => q.page === path)) queue.push({ page: path, from: source });
        }
        return jsRefs;
      }

      async function loadScript(src, page) {
        const clean = src.split('?')[0];
        if (scripts.has(clean)) return;
        scripts.set(clean, '');
        const r = await fetch(src, { cache: 'no-store' }).catch(() => null);
        if (!r || !r.ok) { scripts.set(clean, null); return; }
        const text = await r.text();
        scripts.set(clean, text);
        await Promise.all(scan(text, page, clean).map((ref) => loadScript(ref, page)));
      }

      while (queue.length && pages.size < MAX_PAGES) {
        const batch = queue.splice(0, 6);
        await Promise.all(batch.map(async ({ page, from }) => {
          if (pages.has(page)) return;
          pages.set(page, { ok: false, status: 0, from });
          const res = await fetch(page, { cache: 'no-store' }).catch(() => null);
          pages.set(page, { ok: !!res && res.ok, status: res ? res.status : 0, from });
          if (!res || !res.ok) return;
          const html = await res.text();
          const inlineRefs = scan(html, page, page);
          const srcs = [...html.matchAll(/<script[^>]+src=["']([^"']+)["']/g)].map((m) => toPortalPath(page, m[1])).filter(Boolean);
          await Promise.all([...srcs, ...inlineRefs].map((src) => loadScript(src, page)));
        }));
      }
      return { pages, scripts, rpcs: [...rpcs].sort(), edgeFunctions: [...edgeFunctions].sort() };
    })();
    crawlPromise.catch(() => { crawlPromise = null; });
    // Fresh crawl next time the tests are run (pages may have been redeployed meanwhile).
    crawlPromise.finally(() => setTimeout(() => { crawlPromise = null; }, 30000));
    return crawlPromise;
  }

  // Handy from the browser console: (await SystemTestsCrawlPortal()).rpcs
  window.SystemTestsCrawlPortal = crawlPortal;

  SystemTests.suite('Portal wiring (live)', {
    kind: 'live',
    description: 'Crawls the portal\'s pages and scripts starting from the menu: every linked page and script exists, every database function they call is installed, every Edge Function is deployed.'
  }, (t) => {
    t.test('Every linked page exists', async (a) => {
      const { pages } = await crawlPortal();
      const missing = [...pages].filter(([, p]) => !p.ok).map(([page, p]) => `${page} (${p.status || 'no response'}, linked from ${p.from})`);
      a.ok(pages.size > 20, `only found ${pages.size} pages - crawl looks broken`);
      a.ok(missing.length === 0, `missing: ${missing.join('; ')}`);
    });

    t.test('Every script the pages load exists', async (a) => {
      const { scripts } = await crawlPortal();
      const missing = [...scripts].filter(([, text]) => text === null).map(([src]) => src);
      a.ok(missing.length === 0, `missing: ${missing.join(', ')}`);
    });

    t.test('Every database function the pages call is installed', async (a) => {
      const { rpcs } = await crawlPortal();
      a.ok(rpcs.length > 50, `only found ${rpcs.length} RPC names - crawl looks broken`);
      const { data, error } = await callAdminRpc('admin_check_portal_rpcs', { p_names: rpcs });
      if (error && error.code === 'PGRST202') a.skip('admin_check_portal_rpcs is not in the database yet - run sql/supabase_system_checks.sql.');
      a.ok(!error, error && error.message);
      const missing = (data || []).filter((r) => r.problem === 'missing').map((r) => r.rpc_name);
      const ambiguous = (data || []).filter((r) => r.problem === 'ambiguous').map((r) => r.rpc_name);
      a.ok(missing.length === 0, `${missing.length} of ${rpcs.length} not in the database (a .sql file not run yet?): ${missing.join(', ')}`
        + (ambiguous.length ? ` | also 2+ versions of: ${ambiguous.join(', ')}` : ''));
      if (ambiguous.length) a.warn(`2+ versions with different parameters (calls can fail with PGRST203 - drop the old one): ${ambiguous.join(', ')}`);
    });

    t.test('Every Edge Function the pages call is deployed', async (a) => {
      const { edgeFunctions } = await crawlPortal();
      a.ok(edgeFunctions.length > 3, `only found ${edgeFunctions.length} Edge Function names - crawl looks broken`);
      // A CORS preflight reaches the function without running any of its code: 404 = not deployed.
      const results = await Promise.all(edgeFunctions.map(async (name) => {
        const res = await fetch(`${window.APP_CONFIG.SUPABASE_URL}/functions/v1/${name}`, { method: 'OPTIONS' }).catch(() => null);
        return { name, status: res ? res.status : 0 };
      }));
      const missing = results.filter((r) => r.status === 404 || r.status === 0).map((r) => `${r.name} (${r.status || 'no response'})`);
      a.ok(missing.length === 0, `not deployed: ${missing.join(', ')}`);
    });
  });
})();
