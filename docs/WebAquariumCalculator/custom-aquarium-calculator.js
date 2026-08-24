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
    '12mm': 350
  };

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

  function calculateStand(lengthInches, widthInches, glassThickness, standOptions, defaultUnit, tubularPricingSetupRows) {
    var stand = standOptions || {};
    if (!stand.enabled) {
      return null;
    }

    var layers = Math.max(2, Math.round(Number(stand.layers) || 2));
    var tubularSafety = enforceStandTubularSafety(lengthInches, widthInches, glassThickness, stand.tubular || '1x1');
    var tubular = tubularSafety.tubular;
    var standHeightInches = getStandHeightInches(layers, tubular);
    var stainless = Boolean(stand.stainless);
    var cabinet = Boolean(stand.cabinet);
    var sumpHolder = Boolean(stand.sumpHolder);
    var standUnit = stand.unit || defaultUnit || 'Inches';
    var sumpWidthInches = sumpHolder ? toInches(stand.sumpWidth, standUnit) : 0;
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

    return {
      enabled: true,
      price: computed.price,
      breakdown: computed.breakdown,
      totalFeetConsumed: computed.totalFeetConsumed,
      layers: layers,
      tubular: tubular,
      stainless: stainless,
      cabinet: cabinet,
      sumpHolder: sumpHolder,
      sumpWidth: round2(sumpWidthInches),
      unit: standUnit,
      heightInches: round2(standHeightInches),
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

    return {
      ok: true,
      totalPrice: computed.price,
      breakdown: computed.breakdown,
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

    var components = { sumpGlass: 0, filterMedia: 0, overflowBox: 0, piping: 0, allumTopCover: 0 };
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

    var subtotal = components.sumpGlass + components.filterMedia + components.overflowBox;
    if (subtotal >= 1000) {
      subtotal = roundNearest10(subtotal);
    }

    if (options.piping) {
      components.piping = String(sumpType).toLowerCase() === 'overhead sump' ? 450 : 2200;
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

  // Builds a sticker price lookup from StickerPricingSetup rows (public_get_sticker_pricing), same
  // "start from the hardcoded fallback, then override with whatever live rows matched" pattern as
  // buildGlassPriceLookup - a row for a type this function doesn't recognize is just ignored rather
  // than erroring, so adding new sticker types later doesn't require a matching JS change here.
  function buildStickerPriceLookup(rows) {
    var flat = Object.assign({}, STICKER_PRICE_PER_SQFT);
    var rubber = Object.assign({}, RUBBER_STICKER_PRICE_PER_SQFT);
    var rubberBase = RUBBER_STICKER_BASE_PRICE_PER_SQFT;
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
      } else if (Object.prototype.hasOwnProperty.call(flat, type)) {
        flat[type] = price;
      }
    }

    return { flat: flat, rubber: rubber, rubberBase: rubberBase };
  }

  function stickerPricePerSqFt(type, thickness, stickerLookup, glassLookup) {
    var flat = (stickerLookup && stickerLookup.flat) || STICKER_PRICE_PER_SQFT;
    var rubber = (stickerLookup && stickerLookup.rubber) || RUBBER_STICKER_PRICE_PER_SQFT;
    var rubberBase = (stickerLookup && stickerLookup.rubberBase) || RUBBER_STICKER_BASE_PRICE_PER_SQFT;
    var glass = glassLookup || DEFAULT_GLASS_PRICES;

    if (type === 'Rubber Matting') return rubber[thickness] || rubberBase;
    if (type === 'Glass') return glass[thickness] || glass['6mm'];
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
    var hasThickness = type === 'Rubber Matting' || type === 'Glass';
    var thickness = hasThickness ? (options.thickness || '6mm') : null;
    var isRepair = type === 'Glass' && Boolean(options.repair);

    var stickerLookup = buildStickerPriceLookup(options.stickerPricingSetupRows);
    var glassLookup = buildGlassPriceLookup(options.glassPricingSetupRows, options.glassPricingUom || 'MM');
    var areaSqFt = inchesToFeet(lengthInches) * inchesToFeet(widthInches);
    var pricePerSqFt = stickerPricePerSqFt(type, thickness, stickerLookup, glassLookup);
    var estimatedPrice = areaSqFt * pricePerSqFt;
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
        isRepair: isRepair
      }
    };
  }

  function getRequiredGlassFromMessage(message) {
    var text = String(message || '').toLowerCase();
    if (text.indexOf('12mm') >= 0) return '12mm';
    if (text.indexOf('10mm') >= 0) return '10mm';
    if (text.indexOf('6mm') >= 0) return '6mm';
    if (text.indexOf('3mm') >= 0) return '3mm';
    return null;
  }

  function buildGlassPriceLookup(rows, preferredUom) {
    var lookup = Object.assign({}, DEFAULT_GLASS_PRICES);
    var wantedUom = String(preferredUom || 'MM').trim().toLowerCase();
    var items = Array.isArray(rows) ? rows : [];

    for (var i = 0; i < items.length; i += 1) {
      var row = items[i] || {};
      var rowUom = String(row.uom || row.UOM || '').trim().toLowerCase();
      if (rowUom !== wantedUom) {
        continue;
      }

      var units = String(row.units || row.Units || '').trim();
      var price = Number(row.pricePerSqFt || row.PricePerSqFt || 0);
      if (!units || !(price > 0)) {
        continue;
      }

      lookup[normalizeGlass(units)] = price;
    }

    return lookup;
  }

  function validateGlassSafety(lengthInches, widthInches, heightInches, glassThickness, isTempered, isRimless) {
    var glass = normalizeGlass(glassThickness);
    var gallons = cubicInchesToGallons(lengthInches * widthInches * heightInches);
    var glassMm = extractGlassMm(glass);

    if (glass === '3mm' && lengthInches > 24) {
      return {
        isSafe: false,
        message: 'Length exceeds 24 inches for 3mm glass. Auto-upgrading glass to 6mm.',
        autoChangeTo: '6mm'
      };
    }

    if ((widthInches >= 36 || heightInches >= 36) && !isTempered) {
      return {
        isSafe: false,
        message: 'Width or height is 36 inches or more. Tempered glass is mandatory for this custom aquarium.',
        autoChangeTo: null
      };
    }

    if (glass === '3mm') {
      if (gallons > 15 && (lengthInches > 24 || widthInches > 12 || heightInches > 12)) {
        return {
          isSafe: false,
          message: 'Tank exceeds safe limits for 3mm glass. Please select 10mm or 12mm glass.',
          autoChangeTo: null
        };
      }
    }

    if (lengthInches > 60 || widthInches > 20 || heightInches > 20) {
      if (glass === '3mm' || (glass === '6mm' && gallons > 50)) {
        return {
          isSafe: false,
          message: 'Tank dimensions exceed safe limits for selected glass. Please choose 10mm or 12mm glass.',
          autoChangeTo: null
        };
      }
    }

    if (glass === '10mm') {
      if (gallons > 180 || lengthInches > 72 || widthInches > 30 || heightInches > 30) {
        return {
          isSafe: false,
          message: 'Tank volume or dimensions require 12mm glass. Please select 12mm glass to calculate.',
          autoChangeTo: null
        };
      }
    }

    if (isRimless) {
      if (gallons >= 10 && gallons <= 15 && glassMm < 6) {
        return {
          isSafe: false,
          message: 'Rimless 10-15G tanks require minimum 6mm glass.',
          autoChangeTo: null
        };
      }

      if (gallons >= 30 && gallons <= 100 && glassMm < 10) {
        return {
          isSafe: false,
          message: 'Rimless 30-100G tanks require minimum 10mm glass.',
          autoChangeTo: null
        };
      }
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
    var hasStand = Boolean(options.stand && options.stand.enabled);
    var hasFiltrationSump = Boolean(
      (options.filtrationSump && options.filtrationSump.enabled) ||
      String(optionType).toLowerCase() === 'complete setup'
    );
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
        autoChangeTo: getRequiredGlassFromMessage(safety.message) || safety.autoChangeTo || null,
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
    var glassAreaSqFt = getGlassAreaSqFt(lengthInches, widthInches, heightInches);
    var standCalculation = calculateStand(lengthInches, widthInches, glass, options.stand, unit, options.tubularPricingSetupRows);
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

      normalizedSump = {
        type: sumpType,
        unit: sumpUnit,
        lengthInches: sumpLengthInches,
        widthInches: sumpWidthInches,
        heightInches: sumpHeightInches
      };

      if (sumpLengthInches > 0 && sumpWidthInches > 0 && sumpHeightInches > 0) {
        var sumpAreaSqFt = getGlassAreaSqFt(sumpLengthInches, sumpWidthInches, sumpHeightInches);
        var sumpPricePerSqFt = basePricePerSqFt;
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
          components.piping = String(sumpType).toLowerCase() === 'overhead sump' ? 450 : 2200;
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

    if (hasAquascapeService) {
      components.aquascapeService = Math.round(gallons * 210);
      calculatedPrice += components.aquascapeService;
    }

    if (hasEnclosure) {
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
    calculateCustomAquarium: calculateCustomAquarium,
    validateGlassSafety: validateGlassSafety,
    toInches: toInches,
    calculateStandaloneStand: calculateStandaloneStand,
    calculateStandaloneFiltration: calculateStandaloneFiltration,
    calculateStandaloneSticker: calculateStandaloneSticker,
    enforceStandTubularSafety: enforceStandTubularSafety,
    getTubularThicknessInches: getTubularThicknessInches,
    computeStandBuiltLengthInches: computeStandBuiltLengthInches
  };

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = api;
  }

  global.CustomAquariumCalculator = api;
})(typeof window !== 'undefined' ? window : globalThis);