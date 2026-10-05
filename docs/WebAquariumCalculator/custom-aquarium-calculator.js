(function (global) {
  'use strict';

  // Last-resort fallback only, used when Supabase's GlassPricingSetup table can't be reached at
  // all (e.g. fully offline) - see buildGlassPriceLookup(). The live values are the actual source
  // of truth, editable from the portal's Pricing Setup page (see supabase_pricing_setup_tables.sql)
  // and shared by the aquarium builder AND the Sticker calculator's "Glass" type - one glass price
  // table now, not two that can drift apart.
  var DEFAULT_GLASS_PRICES = {
    '3mm': 85,
    '6mm': 185,
    '10mm': 290,
    '12mm': 350,
    // 3/4" glass - only offered on the standalone Sticker calculator's Glass type (see
    // getStickerThicknessOptions), not on aquariums.
    '19mm': 2000
  };

  // Last-resort fallback only, same reasoning as DEFAULT_GLASS_PRICES above - see
  // buildExtraPriceLookup(). Live values come from public.AquariumExtraPricingSetup (see
  // supabase_aquarium_extra_pricing.sql), editable from the portal's Pricing Setup page.
  var DEFAULT_EXTRA_PRICES = {
    Hole: 150,
    // Cabinet/Canopy (18mm laminated plywood), priced per sq ft - see computePlywoodPanels.
    // 'Plywood Sheet 18mm' = one 4x8ft sheet (pesos); 'Plywood Waste %' = cutting loss;
    // 'Plywood Markup' = multiplier (1.6 ~ P224/sq ft at a P3,900 sheet);
    // 'Plywood Minimum' = least charged per cabinet/canopy (~half a sheet);
    // 'Door Hardware per sq ft' = hinges + handles, per sq ft of door (front) area, so bigger doors cost more.
    'Plywood Sheet 18mm': 3900,
    'Plywood Waste %': 15,
    'Plywood Markup': 1.6,
    'Canopy Markup': 1.3, // canopy is simpler than a cabinet (no doors/load) - its own lower multiplier
    'Plywood Minimum': 2200,
    'Door Hardware per sq ft': 60,
    // Aluminum Cabinet Type (2026-10-02): 4mm ACP (aluminum composite panel) 4x8ft sheets on the
    // steel stand, aluminum-framed doors. Same formula as plywood, its own keys.
    'Aluminum ACP Sheet 4mm': 7000,
    'Aluminum Waste %': 10,
    'Aluminum Markup': 1.8,
    'Aluminum Canopy Markup': 1.5,
    'Aluminum Minimum': 3000,
    'Aluminum Door Hardware per sq ft': 60
  };

  // Cabinet Type -> its Pricing Setup keys and panel thickness (for the approx. outer size).
  // Applies to the canopy too, so the set matches.
  var CABINET_MATERIALS = {
    'Laminated Plywood': {
      label: '18mm laminated plywood', sheet: 'Plywood Sheet 18mm', waste: 'Plywood Waste %', markup: 'Plywood Markup',
      canopyMarkup: 'Canopy Markup', minimum: 'Plywood Minimum', hardware: 'Door Hardware per sq ft', thicknessInches: 18 / 25.4
    },
    Aluminum: {
      label: '4mm aluminum ACP', sheet: 'Aluminum ACP Sheet 4mm', waste: 'Aluminum Waste %', markup: 'Aluminum Markup',
      canopyMarkup: 'Aluminum Canopy Markup', minimum: 'Aluminum Minimum', hardware: 'Aluminum Door Hardware per sq ft', thicknessInches: 4 / 25.4
    }
  };

  function getCabinetType(type) {
    return CABINET_MATERIALS[type] ? type : 'Laminated Plywood';
  }

  var PLYWOOD_SHEET_SQFT = 32; // 4ft x 8ft
  var CANOPY_CLEARANCE_INCHES = 3 / 25.4; // per side, so a canopy slips over the tank
  var DEFAULT_CANOPY_HEIGHT_INCHES = 6;

  // Last-resort fallback only, same reasoning as DEFAULT_GLASS_PRICES above - see
  // buildTubularPriceLookup().
  var TUBULAR_RETAIL_RATES = {
    '1x1': 46,
    '1.5x1.5': 52,
    '2x2': 95
  };

  // Default footing (short leg stub below the lowest shelf, resting on the floor) added at every
  // corner of a standalone Stand build - per direct request, referencing a real tubular stand
  // photo where the bottom frame sits slightly above the ground on these stubs rather than
  // directly on the floor.
  var STAND_FOOTING_INCHES = 3;

  function round2(value) {
    return Math.round((Number(value) || 0) * 100) / 100;
  }

  function roundNearest10(value) {
    return Math.round((Number(value) || 0) / 10) * 10;
  }

  function ceilNearest10(value) {
    return Math.ceil((Number(value) || 0) / 10) * 10;
  }

  function normalizeUnit(unit) {
    return String(unit || 'Inches').trim().toLowerCase();
  }

  function toInches(value, unit) {
    var numeric = Number(value) || 0;
    switch (normalizeUnit(unit)) {
      case 'cm':
        return numeric / 2.54;
      case 'mm':
        return numeric / 25.4;
      case 'ft':
      case 'feet':
      case 'foot':
        return numeric * 12;
      default:
        return numeric;
    }
  }

  function cubicInchesToGallons(cubicInches) {
    return cubicInches / 231;
  }

  function inchesToFeet(inches) {
    return (Number(inches) || 0) / 12;
  }

  function getGlassAreaSqFt(lengthInches, widthInches, heightInches) {
    var areaSqInches =
      (2 * (lengthInches * heightInches)) +
      (2 * (widthInches * heightInches)) +
      (lengthInches * widthInches);

    return areaSqInches / 144;
  }

  function normalizeGlass(glass) {
    var text = String(glass || '6mm').trim().toLowerCase();
    if (!text.endsWith('mm')) {
      text += 'mm';
    }
    return text;
  }

  function extractGlassMm(glass) {
    var match = String(glass || '').match(/(\d+)/);
    return match ? Number(match[1]) : 0;
  }

  function normalizeTubular(tubular) {
    var text = String(tubular || '1x1').trim().toLowerCase().replace(/\s+/g, '');
    if (text === '1x1') return '1x1';
    if (text === '1.5x1.5' || text === '11/2x11/2' || text === '1 1/2 x 1 1/2') return '1.5x1.5';
    if (text === '2x2') return '2x2';
    return '1x1';
  }

  // Nominal thickness (inches) of each tubular size, used only to show the true built Length of a
  // dual (2-post) stand below - the frame has one end post at each end of the Length run, so the
  // finished stand is actually 2x the tubular's own thickness longer than the footprint Length
  // that was entered. Display-only per direct request: pricing still runs off the entered footprint.
  var TUBULAR_THICKNESS_INCHES = { '1x1': 1, '1.5x1.5': 1.5, '2x2': 2 };

  function getTubularThicknessInches(tubular) {
    return TUBULAR_THICKNESS_INCHES[normalizeTubular(tubular)] || TUBULAR_THICKNESS_INCHES['1x1'];
  }

  function computeStandBuiltLengthInches(lengthInches, tubular) {
    return Number(lengthInches || 0) + (2 * getTubularThicknessInches(tubular));
  }

  function getStandHeightInches(layers, tubular) {
    var layerCount = Math.max(2, Math.round(Number(layers) || 2));
    var normalizedTubular = normalizeTubular(tubular);
    var baseHeightInches = normalizedTubular === '1x1' ? 30 : 36;
    var incrementHeightInches = normalizedTubular === '1x1' ? 16 : 24;
    return baseHeightInches + ((layerCount - 2) * incrementHeightInches);
  }

  // Checks the mandatory 2x2 conditions (glass thickness, then length+width) BEFORE the softer
  // "starting tubular is 1x1 and length > 30" upgrade - each rule below used to "return"
  // immediately, so a stand starting at the default 1x1 tubular could match the softer 30" rule
  // and get back 1.5x1.5 before ever reaching the mandatory checks, understating what a 49"+ x
  // 18"+ (or 10mm+ glass) stand structurally requires. Checking strictest-first means the answer
  // no longer depends on what tubular the caller happened to start from.
  function enforceStandTubularSafety(lengthInches, widthInches, glassThickness, tubular) {
    var normalizedTubular = normalizeTubular(tubular);
    var glassMm = extractGlassMm(glassThickness);

    if (glassMm >= 10 && normalizedTubular !== '2x2') {
      return {
        tubular: '2x2',
        notice: {
          title: 'Stand Rule',
          message: 'For 10mm and above aquariums, the stand tubular must be 2x2. Tubular has been updated to 2x2.',
          updatedTubular: '2x2'
        }
      };
    }

    if (lengthInches >= 49 && widthInches >= 18 && normalizedTubular !== '2x2') {
      return {
        tubular: '2x2',
        notice: {
          title: 'Tubular size adjusted',
          message: 'Length > 50 in and Width > 18 in - tubular set to 2 x 2 (mandatory).',
          updatedTubular: '2x2'
        }
      };
    }

    if (normalizedTubular === '1x1' && lengthInches > 30) {
      return {
        tubular: '1.5x1.5',
        notice: {
          title: 'Tubular size adjusted',
          message: 'Length is greater than 30 inches - switching tubular to 1 1/2 x 1 1/2 for safety.',
          updatedTubular: '1.5x1.5'
        }
      };
    }

    return {
      tubular: normalizedTubular,
      notice: null
    };
  }

  // Builds a tubular price lookup from TubularPricingSetup rows (public_get_tubular_pricing),
  // same "start from the hardcoded fallback, override with live rows" pattern as
  // buildGlassPriceLookup/buildStickerPriceLookup above.
  function buildTubularPriceLookup(rows) {
    var lookup = Object.assign({}, TUBULAR_RETAIL_RATES);
    var items = Array.isArray(rows) ? rows : [];

    for (var i = 0; i < items.length; i += 1) {
      var row = items[i] || {};
      var size = normalizeTubular(row.tubularSize || row.tubular_size || row.TubularSize);
      var price = Number(row.pricePerFt || row.price_per_ft || row.PricePerFt || 0);
      if (price > 0) {
        lookup[size] = price;
      }
    }

    return lookup;
  }

  function computeStandRetailPrice(lengthFeet, widthFeet, heightFeet, layers, tubular, stainless, sumpWidthFeet, tubularRatesLookup) {
    var layerCount = Math.max(2, Math.round(Number(layers) || 2));
    var perimeterPerLayerFeet = 2 * (lengthFeet + widthFeet);
    var totalPerimeterFeet = perimeterPerLayerFeet * layerCount;
    var uprightsFeet = 4 * heightFeet;
    var bracesPerFrame = Math.ceil(lengthFeet / 3);
    var braceLengthPerFrameFeet = bracesPerFrame * widthFeet;
    var totalBraceLengthFeet = braceLengthPerFrameFeet * layerCount;
    var subtotalFeet = totalPerimeterFeet + uprightsFeet + totalBraceLengthFeet;
    var adjustedFeet = subtotalFeet * 1.22;
    var tubularRates = tubularRatesLookup || TUBULAR_RETAIL_RATES;
    var ratePerFoot = Number(tubularRates[normalizeTubular(tubular)]) || tubularRates['1x1'] || TUBULAR_RETAIL_RATES['1x1'];

    if (stainless) {
      ratePerFoot *= 3;
    }

    var retailPrice = adjustedFeet * ratePerFoot;
    var totalAdjustedFeet = adjustedFeet;
    var breakdown = [];

    if (sumpWidthFeet > 0) {
      var sumpPerimeterFeet = 2 * (lengthFeet + sumpWidthFeet);
      var sumpSupportsFeet = 2 * heightFeet;
      var sumpBracesPerFrame = Math.ceil(lengthFeet / 3);
      var sumpBraceFeet = sumpBracesPerFrame * sumpWidthFeet;
      var sumpSubtotalFeet = sumpPerimeterFeet + sumpSupportsFeet + sumpBraceFeet;
      var sumpCost = sumpSubtotalFeet * ratePerFoot;

      totalAdjustedFeet += sumpSubtotalFeet;
      retailPrice += sumpCost;

      breakdown.push('Sump holder calculation:');
      breakdown.push('Sump width: ' + sumpWidthFeet.toFixed(3) + ' ft');
      breakdown.push('Perimeter P_sump: ' + sumpPerimeterFeet.toFixed(3) + ' ft');
      breakdown.push('Uprights/supports U_sump: ' + sumpSupportsFeet.toFixed(3) + ' ft (u=2)');
      breakdown.push('Braces per frame: ' + sumpBracesPerFrame);
      breakdown.push('Total brace length B_sump: ' + sumpBraceFeet.toFixed(3) + ' ft');
      breakdown.push('Subtotal T_sump: ' + sumpSubtotalFeet.toFixed(3) + ' ft');
      breakdown.push('Sump Cost = ' + round2(sumpCost).toFixed(2));
      breakdown.push('');
    }

    breakdown.push('Stand price calculation breakdown:');
    breakdown.push('Length: ' + lengthFeet.toFixed(3) + ' ft');
    breakdown.push('Width : ' + widthFeet.toFixed(3) + ' ft');
    breakdown.push('Height: ' + heightFeet.toFixed(3) + ' ft');
    breakdown.push('Layers: ' + layerCount);
    breakdown.push('Tubular size: ' + normalizeTubular(tubular));
    breakdown.push('Stainless: ' + (stainless ? 'Yes' : 'No'));
    breakdown.push('');
    breakdown.push('Perimeter per layer: ' + perimeterPerLayerFeet.toFixed(3) + ' ft');
    breakdown.push('Total perimeter (all layers): ' + totalPerimeterFeet.toFixed(3) + ' ft');
    breakdown.push('Uprights (4 x H): ' + uprightsFeet.toFixed(3) + ' ft');
    breakdown.push('Braces per frame: ' + bracesPerFrame);
    breakdown.push('Brace length per frame: ' + braceLengthPerFrameFeet.toFixed(3) + ' ft');
    breakdown.push('Total brace length (all layers): ' + totalBraceLengthFeet.toFixed(3) + ' ft');
    breakdown.push('Subtotal tubular length: ' + subtotalFeet.toFixed(3) + ' ft');
    breakdown.push('Adjusted length ' + adjustedFeet.toFixed(3) + ' ft');
    breakdown.push('Retail price = ' + round2(retailPrice).toFixed(2));

    return {
      price: round2(retailPrice),
      breakdown: breakdown.join('\n'),
      totalFeetConsumed: round2(totalAdjustedFeet)
    };
  }

  // Default door count: 2 doors per 3ft of length (3ft = 2 doors, 6ft = 4 doors), never fewer than 2.
  function getDefaultCabinetDoors(lengthInches) {
    return 2 * Math.max(1, Math.round((Number(lengthInches) || 0) / 36));
  }

  // Prices a set of plywood panels ([label, widthInches, heightInches]) per sq ft (2026-10-02,
  // replacing whole-sheet pricing, which charged a tiny canopy the same as a full sheet):
  // area x (sheet price / 32) x (1 + waste %) x markup, never below 'Plywood Minimum', plus any
  // per-door hardware (cabinet only).
  function computePlywoodPanels(title, panels, extraPrices, doorCount, material) {
    var sheetPrice = Number(extraPrices[material.sheet]);
    var wastePct = Number(extraPrices[material.waste]);
    var markup = Number(extraPrices[title === 'Canopy' ? material.canopyMarkup : material.markup]);
    var minimum = Number(extraPrices[material.minimum]);
    var hardwarePerSqFt = Number(extraPrices[material.hardware]) || 0;
    // Doors are the front panel (panels[0]) - hardware scales with its area, not the door count.
    var doorAreaSqFt = doorCount > 0 ? (panels[0][1] * panels[0][2]) / 144 : 0;
    var ratePerSqFt = (sheetPrice / PLYWOOD_SHEET_SQFT) * (1 + wastePct / 100) * markup;
    var areaSqFt = 0;
    var breakdown = [title + ' (' + material.label + '):'];

    for (var i = 0; i < panels.length; i += 1) {
      var panelSqFt = (panels[i][1] * panels[i][2]) / 144;
      areaSqFt += panelSqFt;
      breakdown.push(panels[i][0] + ': ' + round2(panels[i][1]) + '" x ' + round2(panels[i][2]) + '" = ' + panelSqFt.toFixed(2) + ' sq ft');
    }

    var areaPrice = areaSqFt * ratePerSqFt;
    var plywoodPrice = Math.max(minimum, areaPrice);
    var hardware = doorAreaSqFt * hardwarePerSqFt;
    var price = round2(plywoodPrice + hardware);
    breakdown.push('Total area: ' + areaSqFt.toFixed(2) + ' sq ft');
    breakdown.push('Rate: ' + sheetPrice + ' / 32 sq ft x ' + (1 + wastePct / 100).toFixed(2) + ' waste x ' + markup + ' = ' + ratePerSqFt.toFixed(2) + ' per sq ft');
    breakdown.push('Panels: ' + areaSqFt.toFixed(2) + ' x ' + ratePerSqFt.toFixed(2) + ' = ' + areaPrice.toFixed(2) + (areaPrice < minimum ? ' -> minimum ' + minimum.toFixed(2) : ''));
    if (hardware > 0) {
      breakdown.push('Door hardware (' + doorCount + ' doors): ' + doorAreaSqFt.toFixed(2) + ' sq ft x ' + hardwarePerSqFt + ' = ' + hardware.toFixed(2));
    }
    breakdown.push(title + ' price = ' + price.toFixed(2));

    return { areaSqFt: round2(areaSqFt), price: price, breakdown: breakdown.join('\n') };
  }

  // Cabinet (closed panels around the stand frame) and Canopy (box cover on top of the tank) for
  // a stand of the given footprint. Cabinet = front (split into doors) + 2 sides + closed back,
  // over the stand's frame height (floor-to-top minus footing). Canopy = front + back + 2 sides at
  // the canopy height + top. A sump-holder section is never enclosed.
  function calculateStandPlywood(lengthInches, widthInches, standHeightInches, footingInches, options, unit, extraPricingSetupRows, tubular) {
    var opts = options || {};
    var extraPrices = buildExtraPriceLookup(extraPricingSetupRows);
    var cabinetType = getCabinetType(opts.cabinetType);
    var material = CABINET_MATERIALS[cabinetType];
    var result = { cabinetType: cabinetType, cabinetPrice: 0, canopyPrice: 0, cabinetDoors: 0, cabinetSqFt: 0, canopySqFt: 0, canopyHeightInches: 0, cabinetOuter: null, canopyOuter: null, breakdown: [] };
    var board2 = 2 * material.thicknessInches;

    if (opts.cabinet) {
      var cabinetHeight = Math.max(0, standHeightInches - footingInches);
      var doors = Math.round(Number(opts.cabinetDoors)) > 0 ? Math.round(Number(opts.cabinetDoors)) : getDefaultCabinetDoors(lengthInches);
      var cabinet = computePlywoodPanels('Cabinet', [
        ['Front (' + doors + ' doors)', lengthInches, cabinetHeight],
        ['Back', lengthInches, cabinetHeight],
        ['Left side', widthInches, cabinetHeight],
        ['Right side', widthInches, cabinetHeight]
      ], extraPrices, doors, material);
      result.cabinetPrice = cabinet.price;
      result.cabinetSqFt = cabinet.areaSqFt;
      result.cabinetDoors = doors;
      result.breakdown.push(cabinet.breakdown);
    }

    if (opts.canopy) {
      var canopyHeight = Number(opts.canopyHeight) > 0 ? toInches(opts.canopyHeight, unit) : DEFAULT_CANOPY_HEIGHT_INCHES;
      var canopy = computePlywoodPanels('Canopy', [
        ['Front', lengthInches, canopyHeight],
        ['Back', lengthInches, canopyHeight],
        ['Left side', widthInches, canopyHeight],
        ['Right side', widthInches, canopyHeight],
        ['Top', lengthInches, widthInches]
      ], extraPrices, 0, material);
      result.canopyPrice = canopy.price;
      result.canopySqFt = canopy.areaSqFt;
      result.canopyHeightInches = round2(canopyHeight);
      result.breakdown.push(canopy.breakdown);
    }

    // Approx. OUTER size for the workshop/drawing (pricing above still runs off the footprint).
    // Cabinet wraps the steel frame: built length (L + 2 end posts) + 2 boards; W + 2 boards.
    // Canopy matches the cabinet's outer L/W so the set lines up; without a cabinet it fits over
    // the tank (footprint + clearance + 2 boards).
    if (opts.cabinet) {
      result.cabinetOuter = {
        lengthInches: round2(computeStandBuiltLengthInches(lengthInches, tubular) + board2),
        widthInches: round2(widthInches + board2),
        heightInches: round2(Math.max(0, standHeightInches - footingInches))
      };
    }
    if (opts.canopy) {
      result.canopyOuter = {
        lengthInches: result.cabinetOuter ? result.cabinetOuter.lengthInches : round2(lengthInches + 2 * CANOPY_CLEARANCE_INCHES + board2),
        widthInches: result.cabinetOuter ? result.cabinetOuter.widthInches : round2(widthInches + 2 * CANOPY_CLEARANCE_INCHES + board2),
        heightInches: result.canopyHeightInches
      };
    }

    return result;
  }

  function calculateStand(lengthInches, widthInches, glassThickness, standOptions, defaultUnit, tubularPricingSetupRows, extraPricingSetupRows) {
    var stand = standOptions || {};
    if (!stand.enabled) {
      return null;
    }

    var layers = Math.max(2, Math.round(Number(stand.layers) || 2));
    var tubularSafety = enforceStandTubularSafety(lengthInches, widthInches, glassThickness, stand.tubular || '1x1');
    var tubular = tubularSafety.tubular;
    var autoHeightInches = getStandHeightInches(layers, tubular);
    var stainless = Boolean(stand.stainless);
    var cabinet = Boolean(stand.cabinet);
    var sumpHolder = Boolean(stand.sumpHolder);
    var standUnit = stand.unit || defaultUnit || 'Inches';
    var sumpWidthInches = sumpHolder ? toInches(stand.sumpWidth, standUnit) : 0;

    // Mirrors calculateStandaloneStand's own Sump Holder Width check below - a checked Sump Holder
    // with no width would otherwise price as a plain stand (computeStandRetailPrice only adds the
    // sump holder cost when sumpWidthFeet > 0), silently under-quoting a feature the customer
    // thinks they're getting.
    if (sumpHolder && !(sumpWidthInches > 0)) {
      return { error: 'Please enter a Sump Holder Width greater than 0, or uncheck Sump Holder.' };
    }

    // Height is auto-computed from layers/tubular by default, but (same as
    // calculateStandaloneStand) can be overridden - only used when explicitly provided and
    // positive. The value entered is the TOTAL floor-to-top height (footing already included),
    // fed to the pricing formula as-is - no need to add footing again.
    var standHeightInches = Number(stand.height) > 0 ? toInches(stand.height, standUnit) : autoHeightInches;

    // Footing (short leg stub below the bottom shelf) - customizable per direct request, same
    // "defaults to STAND_FOOTING_INCHES when left blank/invalid, never negative" rule as
    // calculateStandaloneStand. Display only (the drawing's Gap/Built Length figures) - it never
    // affects price, which always runs off the full floor-to-top standHeightInches above.
    var footingInches = stand.footingInches !== undefined && stand.footingInches !== null && stand.footingInches !== ''
      ? Math.max(0, Number(stand.footingInches) || 0)
      : STAND_FOOTING_INCHES;

    var computed = computeStandRetailPrice(
      inchesToFeet(lengthInches),
      inchesToFeet(widthInches),
      inchesToFeet(standHeightInches),
      layers,
      tubular,
      stainless,
      inchesToFeet(sumpWidthInches),
      buildTubularPriceLookup(tubularPricingSetupRows)
    );
    var plywood = calculateStandPlywood(lengthInches, widthInches, standHeightInches, footingInches, stand, standUnit, extraPricingSetupRows, tubular);

    return {
      enabled: true,
      price: round2(computed.price + plywood.cabinetPrice + plywood.canopyPrice),
      framePrice: computed.price,
      breakdown: [computed.breakdown].concat(plywood.breakdown).join('\n\n'),
      totalFeetConsumed: computed.totalFeetConsumed,
      layers: layers,
      tubular: tubular,
      stainless: stainless,
      cabinet: cabinet,
      cabinetDoors: plywood.cabinetDoors,
      cabinetPrice: plywood.cabinetPrice,
      cabinetType: plywood.cabinetType,
      cabinetSqFt: plywood.cabinetSqFt,
      cabinetOuter: plywood.cabinetOuter,
      canopy: Boolean(stand.canopy),
      canopyHeightInches: plywood.canopyHeightInches,
      canopyPrice: plywood.canopyPrice,
      canopySqFt: plywood.canopySqFt,
      canopyOuter: plywood.canopyOuter,
      sumpHolder: sumpHolder,
      sumpWidth: round2(sumpWidthInches),
      unit: standUnit,
      heightInches: round2(standHeightInches),
      footingInches: round2(footingInches),
      notice: tubularSafety.notice
    };
  }

  // Standalone Stand build - same pricing engine as the Stand add-on above
  // (computeStandRetailPrice/getStandHeightInches/enforceStandTubularSafety), just driven by the
  // stand's OWN Length/Width rather than an aquarium's footprint, for the Customize > Stand flow.
  // options.linkedAquariumGlass is only ever set by the caller when this stand was built via
  // "Use Its Footprint" from the Aquarium tab (see js/orderNow.js's prefillStandFromAquarium) -
  // that's the one case where a standalone stand actually IS for a specific aquarium, so the same
  // glass-based tubular rule the embedded Stand add-on above already enforces applies here too.
  // Left undefined for every other stand (no aquarium involved, nothing to check).
  function calculateStandaloneStand(input) {
    var options = input || {};
    var unit = options.unit || 'Inches';
    var lengthInches = toInches(options.length, unit);
    var widthInches = toInches(options.width, unit);
    var layers = Math.max(2, Math.round(Number(options.layers) || 2));
    var stainless = Boolean(options.stainless);
    var cabinet = Boolean(options.cabinet);
    var sumpHolder = Boolean(options.sumpHolder);

    if (!(lengthInches > 0) || !(widthInches > 0)) {
      return { ok: false, error: 'Please enter valid positive Length and Width.' };
    }

    var tubularSafety = enforceStandTubularSafety(lengthInches, widthInches, options.linkedAquariumGlass, options.tubular || '1x1');
    var tubular = tubularSafety.tubular;
    var standHeightInches = getStandHeightInches(layers, tubular);
    // Height is auto-computed from layers/tubular by default (matches the desktop app), but the
    // customer can override it - only used when explicitly provided and positive.
    var heightInches = Number(options.height) > 0 ? toInches(options.height, unit) : standHeightInches;
    // Footing (short leg stub below the bottom shelf) is always entered in inches directly - see
    // the "Footing (inches)" field - defaults to STAND_FOOTING_INCHES when left blank/invalid, and
    // can never go negative.
    var footingInches = options.footingInches !== undefined && options.footingInches !== null && options.footingInches !== ''
      ? Math.max(0, Number(options.footingInches) || 0)
      : STAND_FOOTING_INCHES;

    var sumpWidthInches = 0;
    if (sumpHolder) {
      sumpWidthInches = toInches(options.sumpWidth, unit);
      if (!(sumpWidthInches > 0)) {
        return { ok: false, error: 'Please enter a Sump Width greater than 0, or uncheck Sump Holder.' };
      }
    }

    // Height entered by the customer is the TOTAL floor-to-top height (footing already included
    // in it, per direct request), so it's fed to the pricing formula as-is - uprights (and the
    // sump-holder's own support legs) already run this full length, no need to add footing again.
    var computed = computeStandRetailPrice(
      inchesToFeet(lengthInches),
      inchesToFeet(widthInches),
      inchesToFeet(heightInches),
      layers,
      tubular,
      stainless,
      inchesToFeet(sumpWidthInches),
      buildTubularPriceLookup(options.tubularPricingSetupRows)
    );
    var plywood = calculateStandPlywood(lengthInches, widthInches, heightInches, footingInches, options, unit, options.extraPricingSetupRows, tubular);

    return {
      ok: true,
      totalPrice: round2(computed.price + plywood.cabinetPrice + plywood.canopyPrice),
      framePrice: computed.price,
      cabinetPrice: plywood.cabinetPrice,
      canopyPrice: plywood.canopyPrice,
      breakdown: [computed.breakdown].concat(plywood.breakdown).join('\n\n'),
      normalized: {
        unit: unit,
        lengthInches: round2(lengthInches),
        widthInches: round2(widthInches),
        heightInches: round2(heightInches),
        footingInches: round2(footingInches),
        layers: layers,
        tubular: tubular,
        stainless: stainless,
        cabinet: cabinet,
        cabinetDoors: plywood.cabinetDoors,
        cabinetType: plywood.cabinetType,
        cabinetSqFt: plywood.cabinetSqFt,
        cabinetOuter: plywood.cabinetOuter,
        canopy: Boolean(options.canopy),
        canopySqFt: plywood.canopySqFt,
        canopyOuter: plywood.canopyOuter,
        canopyHeightInches: plywood.canopyHeightInches,
        sumpHolder: sumpHolder,
        sumpWidthInches: round2(sumpWidthInches)
      },
      notice: tubularSafety.notice
    };
  }

  // Standalone Filtration/Sump build - the sump pricing math the Aquarium+Filtration combo already
  // uses (glass panels, filter media, overflow box, piping, allum top cover) reads its glass rate
  // and "effective width" off the aquarium it's attached to; here there is no aquarium, so this
  // takes its own Glass Thickness and prices the allum top cover to the sump's own footprint
  // instead of "aquarium width minus sump width".
  function calculateStandaloneFiltration(input) {
    var options = input || {};
    var unit = options.unit || 'Inches';
    var sumpType = String(options.sumpType || 'Undersump');
    var lengthInches = toInches(options.length, unit);
    var widthInches = toInches(options.width, unit);
    var heightInches = toInches(options.height, unit);

    if (!(lengthInches > 0) || !(widthInches > 0) || !(heightInches > 0)) {
      return { ok: false, error: 'Please enter valid positive dimensions for your sump.' };
    }

    var glass = normalizeGlass(options.glassThickness || '6mm');
    var glassPrices = Object.assign(
      {},
      buildGlassPriceLookup(options.glassPricingSetupRows, options.glassPricingUom || 'MM'),
      options.glassPricesPerSqFt
    );
    var basePricePerSqFt = Number(glassPrices[glass]) || 100;

    var components = { sumpGlass: 0, filterMedia: 0, overflowBox: 0, light: 0, pump: 0, piping: 0, allumTopCover: 0 };
    var normalizedExtra = {};

    var sumpAreaSqFt = getGlassAreaSqFt(lengthInches, widthInches, heightInches);
    components.sumpGlass = round2(sumpAreaSqFt * basePricePerSqFt);

    if (options.filterMedias) {
      var volumeCuFt = (lengthInches / 12) * (widthInches / 12) * (heightInches / 12);
      var liters = volumeCuFt * 28.316;
      var fillRatio = String(sumpType).toLowerCase() === 'overhead sump' ? 0.18 : 0.04;
      var mediaKg = Math.round(liters * fillRatio);
      components.filterMedia = round2(mediaKg * 300);
      normalizedExtra.filterMediaKg = mediaKg;
    }

    if (options.overflowBox) {
      components.overflowBox = 1900;
    }

    // Optional flat submersible light/pump totals (item price x qty) - the staff calculator's
    // "Sump only" build passes them, Order Now doesn't. Added before the round-to-10 like
    // calculateCustomAquarium does with its sump light/pump.
    components.light = round2(Number(options.lightPrice) || 0);
    components.pump = round2(Number(options.pumpPrice) || 0);

    var subtotal = components.sumpGlass + components.filterMedia + components.overflowBox + components.light + components.pump;
    if (subtotal >= 1000) {
      subtotal = roundNearest10(subtotal);
    }

    if (options.piping) {
      components.piping = String(sumpType).toLowerCase() === 'overhead sump' ? 540 : 2500;
    }

    if (options.allumTopCover) {
      var coverAreaSqFt = (lengthInches / 12) * (widthInches / 12);
      var allumRate = buildStickerPriceLookup(options.stickerPricingSetupRows).flat['Allum TopCover'];
      components.allumTopCover = ceilNearest10(coverAreaSqFt * allumRate);
    }

    var totalPrice = subtotal + components.piping + components.allumTopCover;

    return {
      ok: true,
      totalPrice: round2(totalPrice),
      components: components,
      normalized: Object.assign({
        unit: unit,
        sumpType: sumpType,
        lengthInches: round2(lengthInches),
        widthInches: round2(widthInches),
        heightInches: round2(heightInches),
        glassThickness: glass,
        piping: Boolean(options.piping),
        overflowBox: Boolean(options.overflowBox),
        filterMedias: Boolean(options.filterMedias),
        allumTopCover: Boolean(options.allumTopCover)
      }, normalizedExtra)
    };
  }

  // Standalone Custom Sticker/Accessory pricing - mirrors ShowCustomStickersDialog in MainForm.cs
  // (the desktop POS app's "CUSTOM STICKERS" action button) and its rate constants in
  // GlobalSettings.cs, so a quote given here (docs/sticker-calculator.html and Order Now's
  // Customize > Accessories/Stickers flow both call this) matches what the desktop app would
  // charge for the same inputs. Covers the full standalone sticker/accessory catalog (Rubber
  // Matting is thickness-priced, Plain/Tiles/Acrylic/Allum TopCover are flat) - Glass is priced
  // via GlassPricingSetup instead, shared with the Aquarium builder (see stickerPricePerSqFt).
  // Last-resort fallback only, same reasoning as DEFAULT_GLASS_PRICES above - live values come
  // from Supabase's StickerPricingSetup table via buildStickerPriceLookup(). "Glass" is
  // deliberately NOT one of these - the Sticker calculator's Glass type reads the SAME glass price
  // lookup the Aquarium builder uses (buildGlassPriceLookup), not a separate table, so there's
  // only ever one place glass-thickness pricing can drift.
  var STICKER_PRICE_PER_SQFT = {
    'Tiles Sticker': 90,
    'Plain Sticker': 70,
    'Acrylic': 135,
    'Allum TopCover': 500
  };
  var RUBBER_STICKER_PRICE_PER_SQFT = { '3mm': 26, '6mm': 32, '10mm': 45, '12mm': 60 };
  var RUBBER_STICKER_BASE_PRICE_PER_SQFT = 85;

  // Plywood types - Marine and Laminated, each only available in 6mm/18mm (unlike Rubber
  // Matting/Glass's 3/6/10/12mm range), per direct request to add Plywood to the standalone
  // sticker/accessory catalog.
  var MARINE_PLYWOOD_PRICE_PER_SQFT = { '6mm': 90, '18mm': 185 };
  var LAMINATED_PLYWOOD_PRICE_PER_SQFT = { '6mm': 125, '18mm': 210 };

  var STANDARD_STICKER_THICKNESS_OPTIONS = ['3mm', '6mm', '10mm', '12mm'];
  var PLYWOOD_THICKNESS_OPTIONS = ['6mm', '18mm'];

  // Single source of truth for "which sticker Types are thickness-priced" and "which thicknesses
  // are valid for that Type" - shared by the standalone sticker calculators (order-now.html and
  // sticker.html) so their Thickness dropdown never drifts out of sync with what
  // calculateStandaloneSticker below actually prices.
  function stickerTypeHasThickness(type) {
    return type === 'Rubber Matting' || type === 'Glass' || type === 'Marine Plywood' || type === 'Laminated Plywood';
  }

  function getStickerThicknessOptions(type) {
    if (type === 'Marine Plywood' || type === 'Laminated Plywood') return PLYWOOD_THICKNESS_OPTIONS.slice();
    if (type === 'Glass') return STANDARD_STICKER_THICKNESS_OPTIONS.concat(['19mm']);
    return STANDARD_STICKER_THICKNESS_OPTIONS.slice();
  }

  // What a thickness option is called on screen. The value stays "19mm" (the price lookup key);
  // only the wording adds that it is the 3/4 inch glass.
  function getStickerThicknessLabel(thickness) {
    return thickness === '19mm' ? '19mm (3/4")' : thickness;
  }

  // Builds a sticker price lookup from StickerPricingSetup rows (public_get_sticker_pricing), same
  // "start from the hardcoded fallback, then override with whatever live rows matched" pattern as
  // buildGlassPriceLookup - a row for a type this function doesn't recognize is just ignored rather
  // than erroring, so adding new sticker types later doesn't require a matching JS change here.
  function buildStickerPriceLookup(rows) {
    var flat = Object.assign({}, STICKER_PRICE_PER_SQFT);
    var rubber = Object.assign({}, RUBBER_STICKER_PRICE_PER_SQFT);
    var rubberBase = RUBBER_STICKER_BASE_PRICE_PER_SQFT;
    var marinePlywood = Object.assign({}, MARINE_PLYWOOD_PRICE_PER_SQFT);
    var laminatedPlywood = Object.assign({}, LAMINATED_PLYWOOD_PRICE_PER_SQFT);
    var items = Array.isArray(rows) ? rows : [];

    for (var i = 0; i < items.length; i += 1) {
      var row = items[i] || {};
      var type = String(row.stickerType || row.sticker_type || row.StickerType || '').trim();
      var thicknessRaw = row.thickness || row.Thickness;
      var price = Number(row.pricePerSqFt || row.price_per_sqft || row.PricePerSqFt || 0);
      if (!type || !(price > 0)) {
        continue;
      }

      if (type === 'Rubber Matting') {
        if (thicknessRaw) {
          rubber[normalizeGlass(thicknessRaw)] = price;
        } else {
          rubberBase = price;
        }
      } else if (type === 'Marine Plywood' && thicknessRaw) {
        marinePlywood[normalizeGlass(thicknessRaw)] = price;
      } else if (type === 'Laminated Plywood' && thicknessRaw) {
        laminatedPlywood[normalizeGlass(thicknessRaw)] = price;
      } else if (Object.prototype.hasOwnProperty.call(flat, type)) {
        flat[type] = price;
      }
    }

    return { flat: flat, rubber: rubber, rubberBase: rubberBase, marinePlywood: marinePlywood, laminatedPlywood: laminatedPlywood };
  }

  function stickerPricePerSqFt(type, thickness, stickerLookup, glassLookup) {
    var flat = (stickerLookup && stickerLookup.flat) || STICKER_PRICE_PER_SQFT;
    var rubber = (stickerLookup && stickerLookup.rubber) || RUBBER_STICKER_PRICE_PER_SQFT;
    var rubberBase = (stickerLookup && stickerLookup.rubberBase) || RUBBER_STICKER_BASE_PRICE_PER_SQFT;
    var marinePlywood = (stickerLookup && stickerLookup.marinePlywood) || MARINE_PLYWOOD_PRICE_PER_SQFT;
    var laminatedPlywood = (stickerLookup && stickerLookup.laminatedPlywood) || LAMINATED_PLYWOOD_PRICE_PER_SQFT;
    var glass = glassLookup || DEFAULT_GLASS_PRICES;

    if (type === 'Rubber Matting') return rubber[thickness] || rubberBase;
    if (type === 'Glass') return glass[thickness] || glass['6mm'];
    if (type === 'Marine Plywood') return marinePlywood[thickness] || marinePlywood['6mm'];
    if (type === 'Laminated Plywood') return laminatedPlywood[thickness] || laminatedPlywood['6mm'];
    return flat[type] || flat['Plain Sticker'];
  }

  // Length/Width only (no height) - stickers/mats/covers are flat, same as the desktop dialog.
  function calculateStandaloneSticker(input) {
    var options = input || {};
    var unit = options.unit || 'Inches';
    var lengthInches = toInches(options.length, unit);
    var widthInches = toInches(options.width, unit);

    if (!(lengthInches > 0) || !(widthInches > 0)) {
      return { ok: false, error: 'Please enter valid positive Length and Width.' };
    }

    var type = options.type || 'Plain Sticker';
    var hasThickness = stickerTypeHasThickness(type);
    var thickness = hasThickness ? (options.thickness || '6mm') : null;
    var isRepair = type === 'Glass' && Boolean(options.repair);
    var isTempered = type === 'Glass' && Boolean(options.tempered);

    var stickerLookup = buildStickerPriceLookup(options.stickerPricingSetupRows);
    var glassLookup = buildGlassPriceLookup(options.glassPricingSetupRows, options.glassPricingUom || 'MM');
    var areaSqFt = inchesToFeet(lengthInches) * inchesToFeet(widthInches);
    var pricePerSqFt = stickerPricePerSqFt(type, thickness, stickerLookup, glassLookup);
    var estimatedPrice = areaSqFt * pricePerSqFt;
    // Tempered glass is double the glass rate - the same 2x the custom aquarium calculator applies.
    if (isTempered) estimatedPrice *= 2;
    if (isRepair) estimatedPrice *= 2.5;

    return {
      ok: true,
      totalPrice: ceilNearest10(estimatedPrice),
      normalized: {
        unit: unit,
        lengthInches: round2(lengthInches),
        widthInches: round2(widthInches),
        areaSqFt: round2(areaSqFt),
        type: type,
        thickness: thickness,
        isRepair: isRepair,
        isTempered: isTempered
      }
    };
  }

  function getRequiredGlassFromMessage(message) {
    var text = String(message || '').toLowerCase();
    if (text.indexOf('19mm') >= 0) return '19mm';
    if (text.indexOf('12mm') >= 0) return '12mm';
    if (text.indexOf('10mm') >= 0) return '10mm';
    if (text.indexOf('6mm') >= 0) return '6mm';
    if (text.indexOf('3mm') >= 0) return '3mm';
    return null;
  }

  // BUGFIX: this previously read row.units/row.pricePerSqFt/row.uom, none of which exist on what
  // public_get_glass_pricing() actually returns (thickness/price_per_sqft, and no uom column at
  // all - it already filters to Uom='MM' server-side). That mismatch meant every row got silently
  // skipped and this ALWAYS fell back to DEFAULT_GLASS_PRICES - live edits from the portal's
  // Pricing Setup page never actually took effect anywhere this is called (Order Now, the staff
  // Aquarium Calculator, Stickers). preferredUom is kept as an accepted param for call-site
  // compatibility even though there's nothing left to filter by.
  function buildGlassPriceLookup(rows, preferredUom) {
    void preferredUom;
    var lookup = Object.assign({}, DEFAULT_GLASS_PRICES);
    var items = Array.isArray(rows) ? rows : [];

    for (var i = 0; i < items.length; i += 1) {
      var row = items[i] || {};
      var units = String(row.thickness || row.Thickness || '').trim();
      var price = Number(row.price_per_sqft || row.pricePerSqFt || row.PricePerSqFt || 0);
      if (!units || !(price > 0)) {
        continue;
      }

      lookup[normalizeGlass(units)] = price;
    }

    return lookup;
  }

  // Per-feature flat prices (currently just "Hole") - see AquariumExtraPricingSetup
  // (supabase_aquarium_extra_pricing.sql). Same defensive shape-tolerance as buildGlassPriceLookup:
  // accepts either the RPC's snake_case columns or a PascalCase row, and silently skips anything
  // that doesn't look like a valid {feature_key, price} pair rather than throwing.
  function buildExtraPriceLookup(rows) {
    var lookup = Object.assign({}, DEFAULT_EXTRA_PRICES);
    var items = Array.isArray(rows) ? rows : [];

    for (var i = 0; i < items.length; i += 1) {
      var row = items[i] || {};
      var key = String(row.feature_key || row.FeatureKey || '').trim();
      var price = Number(row.price || row.Price || 0);
      if (!key || !(price >= 0)) {
        continue;
      }

      lookup[key] = price;
    }

    return lookup;
  }

  // Thinnest glass that's safe for a tank's size - shop standard (2026-10-02). Height drives the
  // water pressure and length drives how far the long panel bows, so the limits are height/length
  // based instead of the old flat "6mm over 50 gallons" cutoff (which wrongly pushed standard
  // braced builds like 72x18x18 to 12mm). Non-rimless = braced (top frame/brace); rimless is
  // stricter. Each reason only names the target thickness, so getRequiredGlassFromMessage can't
  // misread it. Mirrored in chatbot-engine.ts (Alice) and FunctionEvents.safetyrules (POS).
  function getMinimumGlassForSize(lengthInches, widthInches, heightInches, isRimless) {
    var gallons = cubicInchesToGallons(lengthInches * widthInches * heightInches);

    if (heightInches >= 48) {
      return { glass: '19mm', reason: 'Height is 4 feet (48 inches) or more. 19mm (3/4") glass is required.' };
    }
    // 10mm max: 24" tall, 24" wide, 72" long, 180 gallons. Anything over 72" long is 12mm minimum.
    if (heightInches > 24 || widthInches > 24 || lengthInches > 72 || gallons > 180) {
      return { glass: '12mm', reason: 'Tank is over 24" tall, over 24" wide, over 72" long or over 180 gallons, so 12mm glass is required.' };
    }
    if (isRimless) {
      // Rimless 6mm max: 15" tall, 20" wide, 48" long, under 30 gallons.
      if (heightInches > 15 || widthInches > 20 || lengthInches > 48 || gallons >= 30) {
        return { glass: '10mm', reason: 'Rimless tanks over 15" tall, over 20" wide, over 48" long or 30 gallons and up need 10mm glass.' };
      }
    } else if (heightInches > 20 || widthInches > 20 || (heightInches > 18 && lengthInches > 60)) {
      // Braced 6mm max: 20" tall and 20" wide; up to 72" long at 18" tall or less, 60" long above 18".
      return { glass: '10mm', reason: 'Tank is over 20" tall or wide, or over 18" tall and longer than 60", so 10mm glass is required.' };
    }
    // 3mm max: 24" long, and 15 gallons once any side is over 12".
    if (lengthInches > 24 || (gallons > 15 && (widthInches > 12 || heightInches > 12))) {
      return { glass: '6mm', reason: 'Tank is over 24" long or over 15 gallons, so 6mm glass is required.' };
    }
    if (isRimless && gallons >= 10) {
      return { glass: '6mm', reason: 'Rimless tanks of 10 gallons and up need 6mm glass.' };
    }
    return { glass: '3mm', reason: '' };
  }

  function validateGlassSafety(lengthInches, widthInches, heightInches, glassThickness, isTempered, isRimless) {
    var glassMm = extractGlassMm(normalizeGlass(glassThickness));
    var minimum = getMinimumGlassForSize(lengthInches, widthInches, heightInches, isRimless);

    if (glassMm < extractGlassMm(minimum.glass)) {
      return {
        isSafe: false,
        message: minimum.reason + ' Auto-upgrading glass to ' + minimum.glass + '.',
        autoChangeTo: minimum.glass
      };
    }

    if ((widthInches >= 36 || heightInches >= 36) && !isTempered) {
      return {
        isSafe: false,
        message: 'Width or height is 36 inches or more. Tempered glass is mandatory for this custom aquarium.',
        autoChangeTo: null
      };
    }

    return {
      isSafe: true,
      message: 'OK',
      autoChangeTo: null
    };
  }

  function calculateStickerPrice(panelLengthInches, panelWidthInches, pricePerSqFt) {
    if (panelLengthInches <= 0 || panelWidthInches <= 0 || pricePerSqFt <= 0) {
      return 0;
    }

    var areaSqFt = (panelLengthInches / 12) * (panelWidthInches / 12);
    return ceilNearest10(areaSqFt * pricePerSqFt);
  }

  function getStickerRate(stickerType, config) {
    var type = String(stickerType || 'plain').trim().toLowerCase();
    var flat = buildStickerPriceLookup(config && config.stickerPricingSetupRows).flat;
    var stickerRates = Object.assign(
      { plain: flat['Plain Sticker'], tiles: flat['Tiles Sticker'] },
      config && config.stickerPricesPerSqFt
    );
    return type === 'tiles' ? Number(stickerRates.tiles) || 0 : Number(stickerRates.plain) || 0;
  }

  function calculateCustomAquarium(input) {
    var options = input || {};
    var unit = options.unit || 'Inches';
    var optionType = String(options.option || 'Aquarium only');
    var requestedGlass = normalizeGlass(options.glassThickness || '6mm');
    var requestedTempered = Boolean(options.temperedGlass);
    var glass = requestedGlass;
    var isTempered = requestedTempered;
    var isLowIron = Boolean(options.lowIron);
    var isAio = Boolean(options.aio);
    var isRimless = Boolean(options.rimless);
    var hasHighStrip = Boolean(options.highStrip);
    var hasAquascapeService = Boolean(options.aquascapeService);
    var hasEnclosure = Boolean(options.enclosure);
    // Turtle tank (water + basking platform): priced the same as Enclosure for now (x2.1 below).
    var hasTurtleTank = Boolean(options.turtleTank);
    var hasStand = Boolean(options.stand && options.stand.enabled);
    var hasFiltrationSump = Boolean(
      (options.filtrationSump && options.filtrationSump.enabled) ||
      String(optionType).toLowerCase() === 'complete setup'
    );
    // Hole for aquarium: flat price per hole (drilling), configurable via AquariumExtraPricingSetup.
    // Divider: priced the same as a main glass panel spanning the tank's Width x Height, using
    // whatever the effective glass price/sqft already works out to for THIS aquarium (thickness +
    // tempered already factored in via finalPricePerSqFt below), plus a flat 20% per direct
    // instruction ("Divider fix is glass price... calculate the height and width price + 20%").
    var holeCount = Math.max(0, Math.round(Number(options.holeCount) || 0));
    var dividerCount = Math.max(0, Math.round(Number(options.dividerCount) || 0));
    var lengthInches = toInches(options.length, unit);
    var widthInches = toInches(options.width, unit);
    var heightInches = toInches(options.height, unit);
    var safetyNotice = null;

    if (!(lengthInches > 0) || !(widthInches > 0) || !(heightInches > 0)) {
      return {
        ok: false,
        error: 'Please enter valid positive dimensions.',
        autoChangeTo: null
      };
    }

    if (isLowIron) {
      isTempered = true;
    }

    if ((widthInches >= 36 || heightInches >= 36) && !isTempered) {
      isTempered = true;
    }

    if (isAio && hasFiltrationSump) {
      return {
        ok: false,
        error: 'AIO cannot be combined with filtration sump.',
        autoChangeTo: null
      };
    }

    if (isAio && hasEnclosure) {
      return {
        ok: false,
        error: 'AIO and enclosure cannot both be selected.',
        autoChangeTo: null
      };
    }

    if (hasFiltrationSump && hasEnclosure) {
      return {
        ok: false,
        error: 'Enclosure cannot be selected when filtration sump is enabled.',
        autoChangeTo: null
      };
    }

    if (hasTurtleTank && hasEnclosure) {
      return {
        ok: false,
        error: 'Turtle tank and enclosure cannot both be selected.',
        autoChangeTo: null
      };
    }

    if (isAio && extractGlassMm(glass) === 3) {
      glass = '6mm';
    }

    if (isLowIron && isTempered && extractGlassMm(glass) < 10) {
      glass = '10mm';
    }

    var safety = validateGlassSafety(lengthInches, widthInches, heightInches, glass, isTempered, isRimless);
    if (safety.autoChangeTo) {
      safetyNotice = {
        title: 'Glass Auto-upgrade',
        message: safety.message,
        updatedGlassThickness: safety.autoChangeTo
      };
      glass = safety.autoChangeTo;
      safety = validateGlassSafety(lengthInches, widthInches, heightInches, glass, isTempered, isRimless);
    }

    if (!safety.isSafe) {
      var requiredGlass = getRequiredGlassFromMessage(safety.message);
      if (requiredGlass && requiredGlass !== glass) {
        var originalSafetyMessage = safety.message;
        glass = requiredGlass;
        if (String(safety.message || '').toLowerCase().indexOf('tempered 12mm') >= 0) {
          isTempered = true;
        }
        safetyNotice = {
          title: 'Glass Auto-upgrade',
          message: originalSafetyMessage + '\n\nGlass thickness has been updated to ' + requiredGlass + '.',
          updatedGlassThickness: requiredGlass
        };
        safety = validateGlassSafety(lengthInches, widthInches, heightInches, glass, isTempered, isRimless);
      }
    }

    if (!safety.isSafe) {
      return {
        ok: false,
        error: safety.message,
        autoChangeTo: safety.autoChangeTo || getRequiredGlassFromMessage(safety.message) || null,
        requested: {
          glassThickness: requestedGlass,
          temperedGlass: requestedTempered
        },
        normalized: {
          glassThickness: glass,
          temperedGlass: isTempered
        },
        safetyNotice: safetyNotice
      };
    }

    var gallons = cubicInchesToGallons(lengthInches * widthInches * heightInches);
    var glassPrices = Object.assign(
      {},
      buildGlassPriceLookup(options.glassPricingSetupRows, options.glassPricingUom || 'MM'),
      options.glassPricesPerSqFt
    );
    var basePricePerSqFt = Number(glassPrices[glass]) || 100;
    var finalPricePerSqFt = basePricePerSqFt;
    var extraPrices = buildExtraPriceLookup(options.extraPricingSetupRows);
    var holePricePerHole = Number(extraPrices.Hole) || DEFAULT_EXTRA_PRICES.Hole;
    var glassAreaSqFt = getGlassAreaSqFt(lengthInches, widthInches, heightInches);
    var standCalculation = calculateStand(lengthInches, widthInches, glass, options.stand, unit, options.tubularPricingSetupRows, options.extraPricingSetupRows);
    if (standCalculation && standCalculation.error) {
      return {
        ok: false,
        error: standCalculation.error,
        autoChangeTo: null
      };
    }

    var components = {
      glass: 0,
      highStrip: 0,
      sumpGlass: 0,
      filterMedia: 0,
      overflowBox: 0,
      light: 0,
      pump: 0,
      piping: 0,
      allumTopCover: 0,
      stickerBackground: 0,
      stickerBottom: 0,
      aquascapeService: 0,
      holes: 0,
      divider: 0,
      stand: standCalculation ? Number(standCalculation.price) || 0 : 0
    };

    if (gallons < 90 && glass === '6mm') {
      finalPricePerSqFt = 117;
    } else if (gallons >= 300 && glass === '12mm') {
      finalPricePerSqFt += 145;
    } else if (gallons >= 170 && glass === '12mm') {
      finalPricePerSqFt += 110;
    }

    if (isTempered) {
      finalPricePerSqFt *= 2;
    }

    var calculatedPrice = glassAreaSqFt * finalPricePerSqFt;
    components.glass = round2(calculatedPrice);

    if (hasHighStrip) {
      var highStripLinearFeet = ((lengthInches + widthInches) * 2) / 12;
      components.highStrip = round2(highStripLinearFeet * 90);
      calculatedPrice += components.highStrip;
    }

    var normalizedSump = null;
    if (hasFiltrationSump) {
      var sump = options.filtrationSump || {};
      var sumpUnit = sump.unit || unit;
      var sumpType = String(sump.type || 'Undersump');
      var sumpLengthInches = toInches(sump.length, sumpUnit);
      var sumpWidthInches = toInches(sump.width, sumpUnit);
      var sumpHeightInches = toInches(sump.height, sumpUnit);

      // Sump glass thickness is its own choice (sumps are often built thinner than the display
      // tank) - same as the POS's sumpGlassComboBox. Falls back to the tank's glass when not given.
      var sumpGlass = sump.glassThickness ? normalizeGlass(sump.glassThickness) : glass;

      normalizedSump = {
        type: sumpType,
        unit: sumpUnit,
        glassThickness: sumpGlass,
        lengthInches: sumpLengthInches,
        widthInches: sumpWidthInches,
        heightInches: sumpHeightInches
      };

      // Mirrors the Stand's Sump Holder Width check above - covers both sump types (Undersump and
      // Overhead Sump both go through this same branch), since leaving a dimension blank/zero used
      // to silently skip every sump cost (glass, filter media, overflow box, light, pump) instead
      // of flagging it, under-quoting a feature the customer thinks they're getting.
      if (!(sumpLengthInches > 0 && sumpWidthInches > 0 && sumpHeightInches > 0)) {
        return {
          ok: false,
          error: 'Please enter valid positive Sump Length, Width and Height, or uncheck Filtration sump.',
          autoChangeTo: null
        };
      }

      {
        var sumpAreaSqFt = getGlassAreaSqFt(sumpLengthInches, sumpWidthInches, sumpHeightInches);
        var sumpPricePerSqFt = Number(glassPrices[sumpGlass]) || basePricePerSqFt;
        if (isTempered) {
          sumpPricePerSqFt *= 2;
        }

        components.sumpGlass = round2(sumpAreaSqFt * sumpPricePerSqFt);
        calculatedPrice += components.sumpGlass;

        if (sump.filterMedias) {
          var volumeCuFt = (sumpLengthInches / 12) * (sumpWidthInches / 12) * (sumpHeightInches / 12);
          var liters = volumeCuFt * 28.316;
          var fillRatio = String(sumpType).toLowerCase() === 'overhead sump' ? 0.18 : 0.04;
          var mediaKg = Math.round(liters * fillRatio);
          components.filterMedia = round2(mediaKg * 300);
          calculatedPrice += components.filterMedia;
          normalizedSump.filterMediaKg = mediaKg;
          normalizedSump.meshBags = mediaKg;
          normalizedSump.filterWools = mediaKg;
        }

        if (sump.overflowBox) {
          components.overflowBox = 1900;
          calculatedPrice += components.overflowBox;
        }

        if (sump.lightPrice) {
          components.light = round2(Number(sump.lightPrice) || 0);
          calculatedPrice += components.light;
        }

        if (sump.pumpPrice) {
          components.pump = round2(Number(sump.pumpPrice) || 0);
          calculatedPrice += components.pump;
        }

        if (sump.piping) {
          components.piping = String(sumpType).toLowerCase() === 'overhead sump' ? 540 : 2500;
        }

        if (sump.allumTopCover) {
          var effectiveWidthInches = widthInches;
          if (String(sumpType).toLowerCase() === 'overhead sump') {
            effectiveWidthInches = Math.max(0, widthInches - sumpWidthInches);
          }
          var coverAreaSqFt = (lengthInches / 12) * (effectiveWidthInches / 12);
          var allumRate = buildStickerPriceLookup(options.stickerPricingSetupRows).flat['Allum TopCover'];
          components.allumTopCover = ceilNearest10(coverAreaSqFt * allumRate);
        }
      }
    }

    var stickerBackground = options.stickerBackground || {};
    if (stickerBackground.enabled) {
      var backgroundRate = getStickerRate(stickerBackground.type, options);
      components.stickerBackground = calculateStickerPrice(lengthInches, heightInches, backgroundRate);
      if (stickerBackground.allSides) {
        components.stickerBackground += calculateStickerPrice(widthInches, heightInches, backgroundRate) * 2;
      }
    }

    var stickerBottom = options.stickerBottom || {};
    if (stickerBottom.enabled) {
      var bottomRate = getStickerRate(stickerBottom.type, options);
      components.stickerBottom = calculateStickerPrice(lengthInches, widthInches, bottomRate);
    }

    if (String(optionType).toLowerCase() === 'undersump' ||
        String(optionType).toLowerCase() === 'overheadsump' ||
        String(optionType).toLowerCase() === 'overhead sump') {
      calculatedPrice = round2(calculatedPrice * 1.9);
    }

    if (isAio) {
      calculatedPrice = round2(calculatedPrice * 2.4);
    }

    if (isLowIron) {
      calculatedPrice = round2(calculatedPrice * 1.7);
    }

    if (calculatedPrice >= 1000) {
      calculatedPrice = roundNearest10(calculatedPrice);
    }

    if (components.piping > 0) {
      calculatedPrice += components.piping;
    }

    if (components.allumTopCover > 0) {
      calculatedPrice += components.allumTopCover;
    }

    if (components.stickerBackground > 0) {
      calculatedPrice += components.stickerBackground;
    }

    if (components.stickerBottom > 0) {
      calculatedPrice += components.stickerBottom;
    }

    if (holeCount > 0) {
      components.holes = round2(holeCount * holePricePerHole);
      calculatedPrice += components.holes;
    }

    if (dividerCount > 0) {
      var dividerAreaSqFt = (widthInches * heightInches) / 144;
      var dividerPriceEach = round2(dividerAreaSqFt * finalPricePerSqFt * 1.2);
      components.divider = round2(dividerPriceEach * dividerCount);
      calculatedPrice += components.divider;
    }

    if (hasAquascapeService) {
      components.aquascapeService = Math.round(gallons * 210);
      calculatedPrice += components.aquascapeService;
    }

    if (hasEnclosure || hasTurtleTank) {
      calculatedPrice = round2(calculatedPrice * 2.1);
      if (calculatedPrice >= 1000) {
        calculatedPrice = roundNearest10(calculatedPrice);
      }
    }

    var aquariumOnlyPrice = calculatedPrice;

    if (hasStand && standCalculation) {
      calculatedPrice += components.stand;
    }

    return {
      ok: true,
      totalPrice: round2(calculatedPrice),
      aquariumOnlyPrice: round2(aquariumOnlyPrice),
      gallons: round2(gallons),
      components: components,
      requested: {
        glassThickness: requestedGlass,
        temperedGlass: requestedTempered
      },
      normalized: {
        unit: unit,
        option: optionType,
        glassThickness: glass,
        temperedGlass: isTempered,
        rimless: isRimless,
        lengthInches: round2(lengthInches),
        widthInches: round2(widthInches),
        heightInches: round2(heightInches),
        sump: normalizedSump,
        stand: standCalculation
      },
      safety: safety,
      safetyNotice: safetyNotice,
      standNotice: standCalculation ? standCalculation.notice : null
    };
  }

  var api = {
    buildGlassPriceLookup: buildGlassPriceLookup,
    buildTubularPriceLookup: buildTubularPriceLookup,
    buildStickerPriceLookup: buildStickerPriceLookup,
    buildExtraPriceLookup: buildExtraPriceLookup,
    calculateCustomAquarium: calculateCustomAquarium,
    validateGlassSafety: validateGlassSafety,
    getMinimumGlassForSize: getMinimumGlassForSize,
    getDefaultCabinetDoors: getDefaultCabinetDoors,
    toInches: toInches,
    calculateStandaloneStand: calculateStandaloneStand,
    calculateStandaloneFiltration: calculateStandaloneFiltration,
    calculateStandaloneSticker: calculateStandaloneSticker,
    stickerTypeHasThickness: stickerTypeHasThickness,
    getStickerThicknessOptions: getStickerThicknessOptions,
    getStickerThicknessLabel: getStickerThicknessLabel,
    enforceStandTubularSafety: enforceStandTubularSafety,
    getTubularThicknessInches: getTubularThicknessInches,
    computeStandBuiltLengthInches: computeStandBuiltLengthInches
  };

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = api;
  }

  global.CustomAquariumCalculator = api;
})(typeof window !== 'undefined' ? window : globalThis);