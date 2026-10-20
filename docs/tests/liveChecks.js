// System Tests - live, READ-ONLY checks against the real Supabase data and Edge Functions.
// Nothing here writes to the database.
//
// "Website calculator vs Alice" is the important one: the bot quotes from its own hand-ported
// copy of calculateCustomAquarium in supabase/functions/_shared/chatbot-engine.ts, so a pricing
// change made only in docs/WebAquariumCalculator/custom-aquarium-calculator.js would leave Alice
// quoting a different price. Each case runs the same order through both (the bot's side via
// chatbot-sandbox-reply's tool_test mode - no Claude call, no chat history written) and fails if
// they disagree.
(function () {
  const C = window.CustomAquariumCalculator;

  let livePricingPromise = null;
  function loadLivePricing() {
    if (!livePricingPromise) {
      livePricingPromise = Promise.all([
        supabaseClient.rpc('public_get_glass_pricing'),
        supabaseClient.rpc('public_get_tubular_pricing'),
        supabaseClient.rpc('public_get_aquarium_extra_pricing'),
        supabaseClient.rpc('public_get_sticker_pricing')
      ]).then(([glass, tubular, extra, sticker]) => {
        const firstError = [glass, tubular, extra, sticker].find((r) => r.error);
        if (firstError) throw new Error(firstError.error.message);
        return { glass: glass.data || [], tubular: tubular.data || [], extra: extra.data || [], sticker: sticker.data || [] };
      });
      // Let a later "Run tests" retry if this one failed.
      livePricingPromise.catch(() => { livePricingPromise = null; });
    }
    return livePricingPromise;
  }

  SystemTests.suite('Pricing tables (live)', {
    kind: 'live',
    description: 'The Pricing Setup tables load and are actually used (not silently replaced by built-in fallback prices).'
  }, (t) => {
    t.test('Glass prices load for 3/6/10/12/19mm', async (a) => {
      const { glass } = await loadLivePricing();
      ['3', '6', '10', '12', '19'].forEach((mm) => {
        const row = glass.find((r) => String(r.thickness).replace(/mm$/i, '') === mm);
        a.ok(row && Number(row.price_per_sqft) > 0, `missing or zero price for ${mm}mm glass`);
      });
    });

    t.test('Calculator uses the live glass price, not its fallback', async (a) => {
      const { glass } = await loadLivePricing();
      const row = glass.find((r) => String(r.thickness).replace(/mm$/i, '') === '10');
      const lookup = C.buildGlassPriceLookup(glass, 'MM');
      a.near(lookup['10mm'], Number(row.price_per_sqft), '10mm price used by calculator');
    });

    t.test('Stand tubular prices load for 1x1 / 1.5x1.5 / 2x2', async (a) => {
      const { tubular } = await loadLivePricing();
      const lookup = C.buildTubularPriceLookup(tubular);
      ['1x1', '1.5x1.5', '2x2'].forEach((size) => {
        const row = tubular.find((r) => String(r.tubular_size) === size);
        a.ok(row && Number(row.price_per_ft) > 0, `missing price for ${size}`);
        a.near(lookup[size], Number(row.price_per_ft), `${size} used by calculator`);
      });
    });

    t.test('Hole price is set', async (a) => {
      const { extra } = await loadLivePricing();
      const hole = extra.find((r) => r.feature_key === 'Hole');
      a.ok(hole && Number(hole.price) > 0, 'Hole price missing');
    });

    t.test('Plain and Tiles sticker prices are set', async (a) => {
      const { sticker } = await loadLivePricing();
      ['Plain Sticker', 'Tiles Sticker'].forEach((type) => {
        const row = sticker.find((r) => r.sticker_type === type);
        a.ok(row && Number(row.price_per_sqft) > 0, `${type} price missing`);
      });
    });

    t.test('A standard 36x18x18 quote works with live prices', async (a) => {
      const p = await loadLivePricing();
      const r = C.calculateCustomAquarium({
        length: 36, width: 18, height: 18, glassThickness: '6mm',
        glassPricingSetupRows: p.glass, tubularPricingSetupRows: p.tubular, extraPricingSetupRows: p.extra, stickerPricingSetupRows: p.sticker
      });
      a.ok(r.ok, r.error);
      a.ok(r.totalPrice > 500 && r.totalPrice < 20000, `price looks wrong: ${r.totalPrice}`);
    });
  });

  // Same mapping computeAquariumQuote (chatbot-engine.ts) does from the bot's tool input to the
  // calculator's options - kept in step with it deliberately, sump pump/light excluded (those look
  // up catalog items).
  function websitePayloadFromBotInput(input, p) {
    const stickerKind = (v) => (v === 'plain' || v === 'tiles' ? v : null);
    const bg = stickerKind(input.sticker_background);
    const bottom = stickerKind(input.sticker_bottom);
    return {
      unit: input.unit || 'Inches',
      length: Number(input.length), width: Number(input.width), height: Number(input.height),
      glassThickness: input.glass_thickness || '6mm',
      temperedGlass: Boolean(input.tempered_glass),
      lowIron: Boolean(input.low_iron),
      rimless: Boolean(input.rimless),
      highStrip: Boolean(input.high_strip),
      holeCount: Number(input.hole_count) || 0,
      dividerCount: Number(input.divider_count) || 0,
      enclosure: Boolean(input.enclosure),
      turtleTank: Boolean(input.turtle_tank),
      stickerBackground: { enabled: Boolean(bg), allSides: Boolean(input.sticker_background_all_sides), type: bg || 'plain' },
      stickerBottom: { enabled: Boolean(bottom), type: bottom || 'plain' },
      option: 'Aquarium only',
      filtrationSump: input.add_sump
        ? {
            enabled: true,
            type: input.sump_type === 'Overhead Sump' ? 'Overhead Sump' : 'Undersump',
            length: Number(input.sump_length), width: Number(input.sump_width), height: Number(input.sump_height),
            unit: input.unit || 'Inches',
            glassThickness: input.sump_glass_thickness || undefined,
            filterMedias: Boolean(input.sump_filter_media),
            piping: Boolean(input.sump_piping),
            overflowBox: Boolean(input.sump_overflow_box),
            allumTopCover: Boolean(input.sump_allum_top_cover),
            pumpPrice: 0, lightPrice: 0
          }
        : { enabled: false },
      stand: input.add_stand
        ? {
            enabled: true,
            layers: Number(input.stand_layers) || 2,
            tubular: input.stand_tubular || '1x1',
            stainless: Boolean(input.stand_stainless),
            cabinet: Boolean(input.stand_cabinet),
            cabinetDoors: Number(input.stand_cabinet_doors) || 0,
            cabinetType: input.cabinet_type || 'Laminated Plywood',
            canopy: Boolean(input.canopy),
            canopyHeight: Number(input.canopy_height) || 0
          }
        : { enabled: false },
      glassPricingSetupRows: p.glass, glassPricingUom: 'MM',
      tubularPricingSetupRows: p.tubular, extraPricingSetupRows: p.extra, stickerPricingSetupRows: p.sticker
    };
  }

  const PARITY_CASES = [
    ['36x18x18 6mm', { length: 36, width: 18, height: 18, glass_thickness: '6mm' }],
    ['20x10x12 3mm', { length: 20, width: 10, height: 12, glass_thickness: '3mm' }],
    ['60x24x24 10mm', { length: 60, width: 24, height: 24, glass_thickness: '10mm' }],
    ['96x30x30 12mm tempered', { length: 96, width: 30, height: 30, glass_thickness: '12mm', tempered_glass: true }],
    ['48x24x24 6mm (safety auto-upgrade)', { length: 48, width: 24, height: 24, glass_thickness: '6mm' }],
    ['36x18x18 rimless', { length: 36, width: 18, height: 18, glass_thickness: '6mm', rimless: true }],
    ['36x18x18 low iron', { length: 36, width: 18, height: 18, glass_thickness: '6mm', low_iron: true }],
    ['36x18x18 high strip', { length: 36, width: 18, height: 18, glass_thickness: '6mm', high_strip: true }],
    ['36x18x18 + 2 holes + 1 divider', { length: 36, width: 18, height: 18, glass_thickness: '6mm', hole_count: 2, divider_count: 1 }],
    ['36x18x18 enclosure', { length: 36, width: 18, height: 18, glass_thickness: '6mm', enclosure: true }],
    ['36x18x18 turtle tank', { length: 36, width: 18, height: 18, glass_thickness: '6mm', turtle_tank: true }],
    ['36x18x18 stickers (plain bg all sides + tiles bottom)', { length: 36, width: 18, height: 18, glass_thickness: '6mm', sticker_background: 'plain', sticker_background_all_sides: true, sticker_bottom: 'tiles' }],
    ['3x1.5x1.5 feet', { unit: 'Feet', length: 3, width: 1.5, height: 1.5, glass_thickness: '6mm' }],
    ['48x18x18 + 2-layer stand', { length: 48, width: 18, height: 18, glass_thickness: '6mm', add_stand: true, stand_layers: 2, stand_tubular: '1x1' }],
    ['48x18x18 + stand with plywood cabinet + canopy', { length: 48, width: 18, height: 18, glass_thickness: '6mm', add_stand: true, stand_layers: 2, stand_cabinet: true, canopy: true, canopy_height: 12 }],
    ['60x24x24 10mm + aluminum cabinet stand', { length: 60, width: 24, height: 24, glass_thickness: '10mm', add_stand: true, stand_layers: 2, stand_cabinet: true, cabinet_type: 'Aluminum' }],
    ['48x18x18 + undersump (no pump/light)', { length: 48, width: 18, height: 18, glass_thickness: '6mm', add_sump: true, sump_length: 30, sump_width: 14, sump_height: 14, sump_filter_media: true, sump_overflow_box: true, sump_piping: true }]
  ];

  SystemTests.suite('Website calculator vs Alice (live)', {
    kind: 'live',
    description: 'Same order priced by the website calculator and by the AI bot\'s own copy of the formula. A failure means Alice would quote customers a different price.'
  }, (t) => {
    PARITY_CASES.forEach(([name, input]) => {
      t.test(name, async (a) => {
        const p = await loadLivePricing();
        const web = C.calculateCustomAquarium(websitePayloadFromBotInput(input, p));
        const { status, body } = await callSandboxToolTest('compute_aquarium_quote', input);

        skipIfToolTestNotDeployed(a, status, body);
        a.ok(status === 200 && body.ok, `bot call failed (${status}): ${body.error || 'no response'}`);
        const bot = body.result;

        a.equal(bot.ok, web.ok, `ok (website error: ${web.error || '-'}, bot error: ${bot.error || '-'})`);
        if (!web.ok) return;
        a.near(bot.totalPrice, web.totalPrice, 'total price (bot vs website)');
        a.near(bot.aquariumOnlyPrice, web.aquariumOnlyPrice, 'aquarium-only price (bot vs website)');
        a.equal(bot.normalized.glassThickness, web.normalized.glassThickness, 'glass thickness after safety rules');
        a.equal(bot.normalized.temperedGlass, web.normalized.temperedGlass, 'tempered after safety rules');
      });
    });
  });

  // ---- Stickers: website Sticker calculator vs Alice's compute_sticker_quote ----
  const STICKER_CASES = [
    ['24x12 Plain Sticker', { length: 24, width: 12, type: 'Plain Sticker' }],
    ['36x18 Tiles Sticker', { length: 36, width: 18, type: 'Tiles Sticker' }],
    ['24x12 Acrylic', { length: 24, width: 12, type: 'Acrylic' }],
    ['24x12 Rubber Matting 6mm', { length: 24, width: 12, type: 'Rubber Matting', thickness: '6mm' }],
    ['48x24 Marine Plywood 18mm', { length: 48, width: 24, type: 'Marine Plywood', thickness: '18mm' }],
    ['48x24 Laminated Plywood 6mm', { length: 48, width: 24, type: 'Laminated Plywood', thickness: '6mm' }],
    ['24x12 Glass 6mm', { length: 24, width: 12, type: 'Glass', thickness: '6mm' }],
    ['24x12 Glass 10mm tempered', { length: 24, width: 12, type: 'Glass', thickness: '10mm', is_tempered: true }],
    ['24x12 Glass 6mm repair', { length: 24, width: 12, type: 'Glass', thickness: '6mm', is_repair: true }]
  ];

  SystemTests.suite('Sticker calculator vs Alice (live)', {
    kind: 'live',
    description: 'Same sticker / glass panel priced by the website Sticker calculator and by Alice.'
  }, (t) => {
    STICKER_CASES.forEach(([name, input]) => {
      t.test(name, async (a) => {
        const p = await loadLivePricing();
        const web = C.calculateStandaloneSticker({
          unit: 'Inches', length: input.length, width: input.width, type: input.type, thickness: input.thickness,
          repair: Boolean(input.is_repair), tempered: Boolean(input.is_tempered),
          stickerPricingSetupRows: p.sticker, glassPricingSetupRows: p.glass, glassPricingUom: 'MM'
        });
        const { status, body } = await callSandboxToolTest('compute_sticker_quote', input);
        skipIfToolTestNotDeployed(a, status, body);
        a.ok(status === 200 && body.ok, `bot call failed (${status}): ${body.error || 'no response'}`);
        a.ok(web.ok, `website error: ${web.error}`);
        a.near(body.result.totalPrice, web.totalPrice, 'price (bot vs website)');
      });
    });
  });

  // ---- Repairs: the real Repair Calculator page (in a hidden frame) vs Alice's compute_repair_quote ----
  // Loaded the way Conversations embeds it (?embed=gma), so no second login check runs inside it.
  let repairFramePromise = null;
  function repairFrameReady(frame) {
    try {
      return Boolean(frame.contentDocument && frame.contentDocument.getElementById('repairSummaryTotalValue'));
    } catch {
      return false;
    }
  }

  // Why the frame isn't ready, for the failure message (instead of a bare "did not load").
  function repairFrameState(frame, loaded) {
    if (!loaded) return 'the page never finished loading';
    let doc;
    let win;
    try {
      doc = frame.contentDocument;
      win = frame.contentWindow;
    } catch {
      doc = null;
    }
    if (!doc || !win) return 'its document is not readable (opened from file:// or another origin? open System Tests from the portal URL)';
    const path = win.location.pathname.split('/').pop();
    if (path !== 'repair-calculator.html') return `it redirected to ${path}`;
    if (!win.CustomAquariumCalculator) return 'custom-aquarium-calculator.js did not load';
    if (!win.supabaseClient) return 'the Supabase client did not load';
    const error = doc.getElementById('repairError');
    if (error && !error.classList.contains('hidden') && error.textContent.trim()) return error.textContent.trim();
    return 'its live pricing (public_get_glass_pricing / public_get_repair_pricing_setup) never came back';
  }

  function loadRepairFrame() {
    if (!repairFramePromise) {
      repairFramePromise = new Promise((resolve, reject) => {
        const frame = document.createElement('iframe');
        frame.style.cssText = 'position:absolute;width:1px;height:1px;left:-9999px;border:0;';
        frame.src = 'repair-calculator.html?embed=gma';
        let loaded = false;
        let poll = null;
        const timeout = setTimeout(() => {
          clearInterval(poll);
          // A background tab throttles timers, so the timeout can fire in the same tick as a poll
          // that would have succeeded - check once more before failing.
          if (repairFrameReady(frame)) return resolve(frame);
          const why = repairFrameState(frame, loaded);
          frame.remove();
          reject(new Error(`Repair Calculator page not ready after 30s - ${why}.`));
        }, 30000);
        frame.addEventListener('load', () => {
          loaded = true;
          // Ready once its live pricing has loaded and it drew its first summary.
          poll = setInterval(() => {
            if (repairFrameReady(frame)) {
              clearInterval(poll);
              clearTimeout(timeout);
              resolve(frame);
            }
          }, 100);
        });
        document.body.appendChild(frame);
      });
      repairFramePromise.catch(() => { repairFramePromise = null; });
    }
    return repairFramePromise;
  }

  function websiteRepairTotal(frame, input) {
    const win = frame.contentWindow;
    const doc = frame.contentDocument;
    doc.getElementById('repairUnit').value = 'Inches';
    doc.getElementById('repairAquariumLength').value = input.length;
    doc.getElementById('repairAquariumWidth').value = input.width;
    doc.getElementById('repairAquariumHeight').value = input.height;
    doc.getElementById('repairGlassThickness').value = input.glass_thickness || '6mm';
    doc.getElementById('repairGlassType').value = input.glass_type || 'regular';
    doc.querySelectorAll('.repair-panel-checkbox').forEach((box) => {
      box.checked = (input.panels || []).includes(box.dataset.panel);
    });
    win.repairSetType(input.repair_type || 'panel'); // recalculates
    const text = doc.getElementById('repairSummaryTotalValue').textContent || '';
    return Number(text.replace(/[^0-9.]/g, ''));
  }

  const REPAIR_CASES = [
    ['36x18x18 front panel 6mm', { length: 36, width: 18, height: 18, repair_type: 'panel', panels: ['Front'], glass_thickness: '6mm', glass_type: 'regular' }],
    ['48x24x24 bottom + back 10mm', { length: 48, width: 24, height: 24, repair_type: 'panel', panels: ['Bottom', 'Back'], glass_thickness: '10mm', glass_type: 'regular' }],
    ['36x18x18 side panel low iron', { length: 36, width: 18, height: 18, repair_type: 'panel', panels: ['Left'], glass_thickness: '6mm', glass_type: 'low_iron' }],
    ['48x24x36 front (36"+ tall forces tempered)', { length: 48, width: 24, height: 36, repair_type: 'panel', panels: ['Front'], glass_thickness: '12mm', glass_type: 'regular' }],
    ['24x12x12 reseal (small tier)', { length: 24, width: 12, height: 12, repair_type: 'reseal' }],
    ['48x18x18 reseal (medium tier)', { length: 48, width: 18, height: 18, repair_type: 'reseal' }],
    ['72x24x24 reseal (monster tier)', { length: 72, width: 24, height: 24, repair_type: 'reseal' }]
  ];

  SystemTests.suite('Repair calculator vs Alice (live)', {
    kind: 'live',
    description: 'Same repair priced by the real Repair Calculator page and by Alice.'
  }, (t) => {
    REPAIR_CASES.forEach(([name, input]) => {
      t.test(name, async (a) => {
        const frame = await loadRepairFrame();
        const webTotal = websiteRepairTotal(frame, input);
        const { status, body } = await callSandboxToolTest('compute_repair_quote', input);
        skipIfToolTestNotDeployed(a, status, body);
        a.ok(status === 200 && body.ok && body.result.ok, `bot call failed (${status}): ${body.error || body.result?.error || 'no response'}`);
        a.ok(webTotal > 0, 'website total is 0');
        a.near(body.result.totalPrice, webTotal, 'total (bot vs website)');
      });
    });
  });

  // ---- Wholesale rules (the pricing step of Alice's create_order, nothing saved) ----
  async function buildOrderLines(a, items, pricing) {
    let { status, body } = await callSandboxToolTest('build_order_lines', { items, pricing });
    skipIfToolTestNotDeployed(a, status, body);
    // Products with colour/option variants need one picked - take the first option offered.
    const variantSku = /more than one option: [^(]*\(([^)]+)\)/.exec(body.result?.error || '');
    if (variantSku) {
      const withVariant = items.map((it, i) => (i === 0 ? { ...it, variant: variantSku[1] } : it));
      ({ status, body } = await callSandboxToolTest('build_order_lines', { items: withVariant, pricing }));
    }
    a.ok(status === 200 && body.ok, `bot call failed (${status}): ${body.error || 'no response'}`);
    return body.result;
  }

  // One fetch per run, shared by the wholesale tests below.
  let wholesaleListCache = null;
  async function cheapestWholesaleItem(a) {
    if (!wholesaleListCache || Date.now() - wholesaleListCache.at > 30000) {
      wholesaleListCache = { at: Date.now(), result: await supabaseClient.rpc('public_list_wholesale_items') };
    }
    const { data, error } = wholesaleListCache.result;
    if (error) wholesaleListCache = null;
    a.ok(!error, error && error.message);
    const items = (data || []).filter((r) => Number(r.wholesale_price) > 0)
      .sort((x, y) => Number(x.wholesale_price) - Number(y.wholesale_price));
    if (!items.length) a.skip('No items have a wholesale price set.');
    return { code: items[0].code, price: Number(items[0].wholesale_price) };
  }

  SystemTests.suite('Wholesale rules (live)', {
    kind: 'live',
    description: 'The PHP 5,000 wholesale minimum, and what can / can\'t get wholesale pricing - as Alice\'s order tool applies it.'
  }, (t) => {
    t.test('Under PHP 5,000 at wholesale is refused', async (a) => {
      const item = await cheapestWholesaleItem(a);
      if (item.price >= 5000) a.skip('Cheapest wholesale item is already PHP 5,000 or more.');
      const r = await buildOrderLines(a, [{ item_code: item.code, quantity: 1 }], 'wholesale');
      a.equal(r.ok, false, 'ok');
      a.includes(r.error, 'wholesale minimum');
    });

    t.test('PHP 5,000+ at wholesale is priced at the wholesale price', async (a) => {
      const item = await cheapestWholesaleItem(a);
      const quantity = Math.ceil(5000 / item.price);
      const r = await buildOrderLines(a, [{ item_code: item.code, quantity }], 'wholesale');
      a.ok(r.ok, r.error);
      a.near(r.orderLines[0].Price, item.price, 'line price');
      a.ok(r.wholesaleTotal >= 5000, `wholesale total ${r.wholesaleTotal} under 5,000`);
    });

    t.test('Retail order of the same item gets no wholesale price', async (a) => {
      const item = await cheapestWholesaleItem(a);
      const r = await buildOrderLines(a, [{ item_code: item.code, quantity: Math.ceil(5000 / item.price) }], 'retail');
      a.ok(r.ok, r.error);
      a.equal(r.wholesaleLineCount, 0, 'wholesale lines on a retail order');
    });

    t.test('A Set / bundle never gets wholesale', async (a) => {
      const { data } = await supabaseClient.rpc('public_list_aquarium_sets');
      const set = (data || []).find((s) => Number(s.price) > 0);
      if (!set) a.skip('No priced Sets found.');
      const r = await buildOrderLines(a, [{ item_code: set.code, quantity: 1 }], 'wholesale');
      a.equal(r.ok, false, 'ok');
      a.includes(r.error, 'none of these items has a wholesale price');
    });

    t.test('A custom-built aquarium never gets wholesale', async (a) => {
      const r = await buildOrderLines(a, [{ item_code: 'CUSTOM-AQUARIUM', quantity: 1, custom_price: 20000, notes: 'System test - 48x18x18 6mm' }], 'wholesale');
      a.equal(r.ok, false, 'ok');
      a.includes(r.error, 'none of these items has a wholesale price');
    });

    t.test('Set on a wholesale order stays at its own price', async (a) => {
      const item = await cheapestWholesaleItem(a);
      const { data } = await supabaseClient.rpc('public_list_aquarium_sets');
      const set = (data || []).find((s) => Number(s.price) > 0);
      if (!set) a.skip('No priced Sets found.');
      const r = await buildOrderLines(a, [
        { item_code: item.code, quantity: Math.ceil(5000 / item.price) },
        { item_code: set.code, quantity: 1 }
      ], 'wholesale');
      a.ok(r.ok, r.error);
      const setLine = r.orderLines.find((l) => l.ItemCode === set.code);
      a.ok(setLine, 'Set line missing');
      a.near(setLine.Price, Number(set.price), 'Set line price');
      a.equal(r.wholesaleLineCount, 1, 'wholesale-priced lines');
    });
  });

  // ---- Delivery fee: our own truck's formula (base + per km + toll) ----
  // A fixed pin (SM Mall of Asia) - distance can shift a little as Google's routing changes, so this
  // checks the formula and a sane range rather than one exact peso amount.
  const DELIVERY_TEST_PIN = { latitude: 14.5352, longitude: 120.9822 };

  SystemTests.suite('Delivery fee (live)', {
    kind: 'live',
    description: 'Delivery fee to a fixed map pin from each branch, as staff and Alice quote it. Uses one Google Routes call per branch.'
  }, (t) => {
    t.test('Fee = base fee + rate per km x distance + toll, from both branches', async (a) => {
      const { data: settingsRows, error } = await supabaseClient.rpc('public_get_delivery_quote_settings');
      a.ok(!error, error && error.message);
      const settings = Object.fromEntries((settingsRows || []).map((r) => [r.setting_key, Number(r.setting_value)]));
      a.ok(settings.DELIVERY_BASE_FEE >= 0 && settings.DELIVERY_RATE_PER_KM > 0, 'DELIVERY_BASE_FEE / DELIVERY_RATE_PER_KM not set (General Setup)');

      const { status, body } = await callEdgeFunctionAsAdmin('delivery-fee-from-pin', DELIVERY_TEST_PIN);
      a.ok(status === 200 && body.quotes, `delivery-fee-from-pin failed (${status}): ${body.error || 'no response'}`);
      for (const branch of ['GMA', 'Amaya']) {
        const q = body.quotes[branch];
        a.ok(q && q.ok, `${branch}: ${q && q.error}`);
        const expected = settings.DELIVERY_BASE_FEE + settings.DELIVERY_RATE_PER_KM * q.distanceKm + Number(q.tollAmount || 0);
        // distanceKm comes back rounded to 0.1 km, so allow half of that in pesos (+1 for rounding).
        a.near(q.estimatedFee, expected, `${branch} fee vs formula`, settings.DELIVERY_RATE_PER_KM * 0.05 + 1);
        a.ok(q.estimatedFee > 0 && q.estimatedFee < 20000, `${branch} fee looks wrong: ${q.estimatedFee}`);
      }
    });
  });
})();
