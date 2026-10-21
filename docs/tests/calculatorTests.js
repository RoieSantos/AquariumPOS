// System Tests - aquarium / stand / sticker calculator (docs/WebAquariumCalculator/
// custom-aquarium-calculator.js). Pure logic, no database: every test pins its own glass/extra
// prices (PINNED_* below) so a price edit on the Pricing Setup page never makes these fail -
// only a change to the calculator's CODE does.
//
// The expected numbers are snapshots of the calculator's behavior on 2026-10-18. If one fails right
// after you intentionally changed a pricing formula, update the expected number here (and check
// that Alice's copy in supabase/functions/_shared/chatbot-engine.ts got the same change - the
// "Website calculator vs Alice" live suite checks that for you).
(function () {
  const C = window.CustomAquariumCalculator;

  const PINNED_GLASS_ROWS = [
    { thickness: '3mm', price_per_sqft: 85 },
    { thickness: '6mm', price_per_sqft: 185 },
    { thickness: '10mm', price_per_sqft: 290 },
    { thickness: '12mm', price_per_sqft: 350 },
    { thickness: '19mm', price_per_sqft: 2000 }
  ];
  const PINNED_EXTRA_ROWS = [{ feature_key: 'Hole', price: 150 }];

  function quote(input) {
    return C.calculateCustomAquarium({ glassPricingSetupRows: PINNED_GLASS_ROWS, extraPricingSetupRows: PINNED_EXTRA_ROWS, ...input });
  }

  function expectOk(a, result) {
    a.ok(result && result.ok, `quote failed: ${result && result.error}`);
  }

  SystemTests.suite('Aquarium prices', {
    kind: 'logic',
    description: 'Custom aquarium quotes for fixed sizes at fixed glass prices. A failure means the price formula changed.'
  }, (t) => {
    const cases = [
      ['20x10x12 3mm (small tank)', { length: 20, width: 10, height: 12, glassThickness: '3mm' }, 543.06],
      ['36x18x18 6mm (standard 50 gal, P117/sqft rate)', { length: 36, width: 18, height: 18, glassThickness: '6mm' }, 2110],
      ['60x24x24 10mm', { length: 60, width: 24, height: 24, glassThickness: '10mm' }, 11020],
      ['96x30x30 12mm tempered (300+ gal surcharge)', { length: 96, width: 30, height: 30, glassThickness: '12mm', temperedGlass: true }, 71780],
      ['36x18x18 low iron (forces 10mm tempered, x1.7)', { length: 36, width: 18, height: 18, glassThickness: '6mm', lowIron: true }, 17750],
      ['36x18x18 + 2 holes + 1 divider', { length: 36, width: 18, height: 18, glassThickness: '6mm', holeCount: 2, dividerCount: 1 }, 2725.9],
      ['36x18x18 enclosure (x2.1)', { length: 36, width: 18, height: 18, glassThickness: '6mm', enclosure: true }, 4430],
      ['36x18x18 plain background + tiles bottom sticker', { length: 36, width: 18, height: 18, glassThickness: '6mm', stickerBackground: { enabled: true, type: 'plain' }, stickerBottom: { enabled: true, type: 'tiles' } }, 2840],
      ['3x1.5x1.5 FEET = same as 36x18x18 inches', { unit: 'Feet', length: 3, width: 1.5, height: 1.5, glassThickness: '6mm' }, 2110],
      ['48x18x18 + undersump (media, overflow, piping)', { length: 48, width: 18, height: 18, glassThickness: '6mm', filtrationSump: { enabled: true, type: 'Undersump', length: 30, width: 14, height: 14, filterMedias: true, overflowBox: true, piping: true } }, 10350]
    ];
    cases.forEach(([name, input, expected]) => {
      t.test(name, (a) => {
        const r = quote(input);
        expectOk(a, r);
        a.near(r.totalPrice, expected, 'total price');
      });
    });

    t.test('48x18x18 with 2-layer stand: total = aquarium + stand', (a) => {
      const r = quote({ length: 48, width: 18, height: 18, glassThickness: '6mm', stand: { enabled: true, layers: 2, tubular: '1x1' } });
      expectOk(a, r);
      a.near(r.aquariumOnlyPrice, 2630, 'aquarium only');
      a.near(r.components.stand, 2537.6, 'stand');
      a.near(r.totalPrice, 5167.6, 'total');
    });

    t.test('Piping: Overhead 540, Overhead separate-drain pipe 790, drain ignored for Undersump', (a) => {
      const sump = (type, extra) => quote({ length: 48, width: 18, height: 18, glassThickness: '6mm', filtrationSump: Object.assign({ enabled: true, type, length: 48, width: 6, height: 6 }, extra) });
      a.near(sump('Overhead Sump', { piping: true }).components.piping, 540, 'overhead standard set');
      a.near(sump('Overhead Sump', { pipingSeparateDrain: true }).components.piping, 790, 'overhead separate drain');
      a.near(sump('Undersump', { piping: true, pipingSeparateDrain: true }).components.piping, 2500, 'undersump ignores drain');
    });

    t.test('Holes are priced from the Hole price setting', (a) => {
      const r = quote({ length: 36, width: 18, height: 18, glassThickness: '6mm', holeCount: 3 });
      expectOk(a, r);
      a.near(r.components.holes, 450, 'holes (3 x 150)');
    });
  });

  SystemTests.suite('Aquarium safety rules', {
    kind: 'logic',
    description: 'Glass thickness / tempered / option rules that protect customers from an unsafe build.'
  }, (t) => {
    t.test('6mm on 48x24x24 auto-upgrades to 10mm', (a) => {
      const r = quote({ length: 48, width: 24, height: 24, glassThickness: '6mm' });
      expectOk(a, r);
      a.equal(r.normalized.glassThickness, '10mm', 'glass');
      a.ok(r.safetyNotice, 'should show a safety notice');
      a.near(r.totalPrice, 9280, 'total price');
    });

    t.test('Width or height 36" or more forces tempered glass', (a) => {
      const r = quote({ length: 72, width: 36, height: 24, glassThickness: '12mm' });
      expectOk(a, r);
      a.equal(r.normalized.temperedGlass, true, 'tempered');
    });

    t.test('48" tall tank requires 19mm', (a) => {
      a.equal(C.getMinimumGlassForSize(48, 24, 48, false).glass, '19mm');
    });

    t.test('Over 72" long requires 12mm', (a) => {
      a.equal(C.getMinimumGlassForSize(73, 18, 18, false).glass, '12mm');
    });

    t.test('Rimless is stricter than braced (36x18x18: braced 6mm, rimless 10mm)', (a) => {
      a.equal(C.getMinimumGlassForSize(36, 18, 18, false).glass, '6mm', 'braced');
      a.equal(C.getMinimumGlassForSize(36, 18, 18, true).glass, '10mm', 'rimless');
    });

    t.test('Small 20x10x12 can be 3mm', (a) => {
      a.equal(C.getMinimumGlassForSize(20, 10, 12, false).glass, '3mm');
    });

    t.test('AIO cannot be combined with a filtration sump', (a) => {
      const r = quote({ length: 36, width: 18, height: 18, glassThickness: '6mm', aio: true, filtrationSump: { enabled: true, length: 24, width: 12, height: 12 } });
      a.equal(r.ok, false, 'ok');
      a.includes(r.error, 'AIO cannot be combined');
    });

    t.test('Enclosure + turtle tank is rejected', (a) => {
      const r = quote({ length: 36, width: 18, height: 18, enclosure: true, turtleTank: true });
      a.equal(r.ok, false, 'ok');
    });

    t.test('Zero / missing dimensions are rejected', (a) => {
      const r = quote({ length: 0, width: 18, height: 18 });
      a.equal(r.ok, false, 'ok');
      a.includes(r.error, 'valid positive dimensions');
    });

    t.test('Sump with missing dimensions is rejected (no silent under-quote)', (a) => {
      const r = quote({ length: 48, width: 18, height: 18, glassThickness: '6mm', filtrationSump: { enabled: true, type: 'Undersump', length: 30 } });
      a.equal(r.ok, false, 'ok');
      a.includes(r.error, 'Sump');
    });
  });

  SystemTests.suite('Stand rules & prices', {
    kind: 'logic',
    description: 'Steel stand tubular safety rules and standalone stand prices (default tubular rates).'
  }, (t) => {
    t.test('10mm+ glass forces 2x2 tubular', (a) => {
      a.equal(C.enforceStandTubularSafety(36, 18, '10mm', '1x1').tubular, '2x2');
    });
    t.test('49"+ long and 18"+ wide forces 2x2 tubular', (a) => {
      a.equal(C.enforceStandTubularSafety(49, 18, '6mm', '1x1').tubular, '2x2');
    });
    t.test('1x1 over 30" long upgrades to 1.5x1.5', (a) => {
      a.equal(C.enforceStandTubularSafety(36, 12, '6mm', '1x1').tubular, '1.5x1.5');
    });
    t.test('Small stand keeps 1x1', (a) => {
      a.equal(C.enforceStandTubularSafety(24, 12, '6mm', '1x1').tubular, '1x1');
    });
    t.test('Standalone 36x18 2-layer stand', (a) => {
      const r = C.calculateStandaloneStand({ length: 36, width: 18, layers: 2, tubular: '1x1' });
      expectOk(a, r);
      a.equal(r.normalized.tubular, '1.5x1.5', 'tubular');
      a.near(r.totalPrice, 2093.52, 'price');
    });
    t.test('Standalone 60x24 3-layer stand for a 12mm tank', (a) => {
      const r = C.calculateStandaloneStand({ length: 60, width: 24, layers: 3, tubular: '1x1', linkedAquariumGlass: '12mm' });
      expectOk(a, r);
      a.equal(r.normalized.tubular, '2x2', 'tubular');
      a.near(r.totalPrice, 8576.6, 'price');
    });
  });

  SystemTests.suite('Sticker prices', {
    kind: 'logic',
    description: 'Standalone sticker / glass panel calculator.'
  }, (t) => {
    t.test('24x12 plain sticker', (a) => {
      const r = C.calculateStandaloneSticker({ length: 24, width: 12, type: 'Plain Sticker' });
      expectOk(a, r);
      a.near(r.totalPrice, 140, 'price');
    });
    t.test('24x12 6mm tempered glass panel (2x glass rate)', (a) => {
      const r = C.calculateStandaloneSticker({ length: 24, width: 12, type: 'Glass', thickness: '6mm', tempered: true, glassPricingSetupRows: PINNED_GLASS_ROWS });
      expectOk(a, r);
      a.near(r.totalPrice, 740, 'price');
    });
  });
})();
