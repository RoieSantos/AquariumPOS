// Shared AI-bot brain used by BOTH supabase/functions/facebook-messenger-webhook (the real,
// Facebook-facing bot) and supabase/functions/chatbot-sandbox-reply (a portal-only testing
// sandbox - see docs/ai-bot-sandbox.html) - per direct request to let staff test the bot's
// conversational/tool-use logic from the portal while Meta's messaging restriction/app review is
// in progress, without needing a real Facebook conversation.
//
// Everything here is Facebook-agnostic except sendMessengerImage (a plain Graph API call that
// takes its own pageAccessToken/graphVersion - harmless to share since the sandbox simply never
// calls it). executeTool()/runChatbotTurn() take a `simulate` flag: when true (sandbox mode),
// every side-effecting tool (escalate_to_staff, send_item_image, schedule_follow_up,
// schedule_delivery_date) skips its real action (no Telegram ping, no real Messenger send, no
// ChatbotFollowUps/DeliveryStops write) and returns a "SANDBOX MODE" description of what it WOULD
// have done instead - per direct decision, so testers can safely use real order numbers without
// risk of creating bogus data or spamming staff. Read-only tools (search, order status, quotes,
// delivery-scheduling eligibility) behave identically in both modes since there's nothing to fake -
// sandbox testing should see the same real catalog/order data the real bot would.
//
// Keep this file as the single source of truth for the bot's persona/tools/pricing logic - editing
// facebook-messenger-webhook/index.ts's own copy of any of this would silently NOT apply to the
// sandbox (and vice versa).

import { type SupabaseClient } from 'npm:@supabase/supabase-js@2';
import type Anthropic from 'npm:@anthropic-ai/sdk@0.124.0';

export const DEFAULT_GRAPH_VERSION = 'v21.0';
export const MAX_TOOL_ITERATIONS = 5;
export const MAX_TOKENS = 2048;

// ============================================================================
// BEGIN: ported verbatim from docs/WebAquariumCalculator/custom-aquarium-calculator.js
// (calculateCustomAquarium + everything it calls, minus the standalone Stand/Filtration/Sticker
// builders and sticker helpers - out of scope for compute_aquarium_quote). Source of truth is
// that file - if its pricing logic changes, re-sync this block so the bot's quotes keep matching
// the website's. buildGlassPriceLookup below was previously a verbatim copy of a real bug in that
// file (read row.uom/row.units, which public_get_glass_pricing() never actually returns, so it
// always fell through to DEFAULT_GLASS_PRICES) - now fixed on both sides at once so they stay
// consistent with each other AND actually honor live Pricing Setup edits.
// ============================================================================

// 19mm (3/4") is only offered on the standalone Sticker calculator's Glass type, not on aquariums.
const DEFAULT_GLASS_PRICES: Record<string, number> = { '3mm': 85, '6mm': 185, '10mm': 290, '12mm': 350, '19mm': 2000 };
const TUBULAR_RETAIL_RATES: Record<string, number> = { '1x1': 46, '1.5x1.5': 52, '2x2': 95 };

function round2(value: number): number {
  return Math.round((Number(value) || 0) * 100) / 100;
}

function roundNearest10(value: number): number {
  return Math.round((Number(value) || 0) / 10) * 10;
}

function ceilNearest10(value: number): number {
  return Math.ceil((Number(value) || 0) / 10) * 10;
}

function normalizeUnit(unit: string): string {
  return String(unit || 'Inches').trim().toLowerCase();
}

function toInches(value: number | string, unit: string): number {
  const numeric = Number(value) || 0;
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

function cubicInchesToGallons(cubicInches: number): number {
  return cubicInches / 231;
}

function inchesToFeet(inches: number): number {
  return (Number(inches) || 0) / 12;
}

function getGlassAreaSqFt(lengthInches: number, widthInches: number, heightInches: number): number {
  const areaSqInches = 2 * (lengthInches * heightInches) + 2 * (widthInches * heightInches) + lengthInches * widthInches;
  return areaSqInches / 144;
}

function normalizeGlass(glass: string): string {
  let text = String(glass || '6mm').trim().toLowerCase();
  if (!text.endsWith('mm')) {
    text += 'mm';
  }
  return text;
}

function extractGlassMm(glass: string): number {
  const match = String(glass || '').match(/(\d+)/);
  return match ? Number(match[1]) : 0;
}

function normalizeTubular(tubular: string): string {
  const text = String(tubular || '1x1').trim().toLowerCase().replace(/\s+/g, '');
  if (text === '1x1') return '1x1';
  if (text === '1.5x1.5' || text === '11/2x11/2' || text === '1 1/2 x 1 1/2') return '1.5x1.5';
  if (text === '2x2') return '2x2';
  return '1x1';
}

function getStandHeightInches(layers: number, tubular: string): number {
  const layerCount = Math.max(2, Math.round(Number(layers) || 2));
  const normalizedTubular = normalizeTubular(tubular);
  const baseHeightInches = normalizedTubular === '1x1' ? 30 : 36;
  const incrementHeightInches = normalizedTubular === '1x1' ? 16 : 24;
  return baseHeightInches + (layerCount - 2) * incrementHeightInches;
}

interface TubularSafetyResult {
  tubular: string;
  notice: { title: string; message: string; updatedTubular: string } | null;
}

// Checks the mandatory 2x2 conditions (glass thickness, then length+width) BEFORE the softer
// "starting tubular is 1x1 and length > 30" upgrade - each rule below used to "return" immediately,
// so a stand starting at the default 1x1 tubular could match the softer 30" rule and get back
// 1.5x1.5 before ever reaching the mandatory checks, understating what a 49"+ x 18"+ (or 10mm+
// glass) stand structurally requires. Checking strictest-first means the answer no longer depends
// on what tubular the caller happened to start from. Mirrors the fix in
// docs/WebAquariumCalculator/custom-aquarium-calculator.js - keep both in sync.
function enforceStandTubularSafety(lengthInches: number, widthInches: number, glassThickness: string, tubular: string): TubularSafetyResult {
  const normalizedTubular = normalizeTubular(tubular);
  const glassMm = extractGlassMm(glassThickness);

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

  return { tubular: normalizedTubular, notice: null };
}

function buildTubularPriceLookup(rows: Array<Record<string, unknown>> | null | undefined): Record<string, number> {
  const lookup: Record<string, number> = Object.assign({}, TUBULAR_RETAIL_RATES);
  const items = Array.isArray(rows) ? rows : [];

  for (const row of items) {
    const size = normalizeTubular(String((row as any).tubularSize ?? (row as any).tubular_size ?? (row as any).TubularSize ?? '1x1'));
    const price = Number((row as any).pricePerFt ?? (row as any).price_per_ft ?? (row as any).PricePerFt ?? 0);
    if (price > 0) {
      lookup[size] = price;
    }
  }

  return lookup;
}

interface StandComputeResult {
  price: number;
  breakdown: string;
  totalFeetConsumed: number;
}

function computeStandRetailPrice(
  lengthFeet: number,
  widthFeet: number,
  heightFeet: number,
  layers: number,
  tubular: string,
  stainless: boolean,
  sumpWidthFeet: number,
  tubularRatesLookup: Record<string, number>
): StandComputeResult {
  const layerCount = Math.max(2, Math.round(Number(layers) || 2));
  const perimeterPerLayerFeet = 2 * (lengthFeet + widthFeet);
  const totalPerimeterFeet = perimeterPerLayerFeet * layerCount;
  const uprightsFeet = 4 * heightFeet;
  const bracesPerFrame = Math.ceil(lengthFeet / 3);
  const braceLengthPerFrameFeet = bracesPerFrame * widthFeet;
  const totalBraceLengthFeet = braceLengthPerFrameFeet * layerCount;
  const subtotalFeet = totalPerimeterFeet + uprightsFeet + totalBraceLengthFeet;
  const adjustedFeet = subtotalFeet * 1.22;
  const tubularRates = tubularRatesLookup || TUBULAR_RETAIL_RATES;
  let ratePerFoot = Number(tubularRates[normalizeTubular(tubular)]) || tubularRates['1x1'] || TUBULAR_RETAIL_RATES['1x1'];

  if (stainless) {
    ratePerFoot *= 3;
  }

  let retailPrice = adjustedFeet * ratePerFoot;
  let totalAdjustedFeet = adjustedFeet;

  if (sumpWidthFeet > 0) {
    const sumpPerimeterFeet = 2 * (lengthFeet + sumpWidthFeet);
    const sumpSupportsFeet = 2 * heightFeet;
    const sumpBracesPerFrame = Math.ceil(lengthFeet / 3);
    const sumpBraceFeet = sumpBracesPerFrame * sumpWidthFeet;
    const sumpSubtotalFeet = sumpPerimeterFeet + sumpSupportsFeet + sumpBraceFeet;
    const sumpCost = sumpSubtotalFeet * ratePerFoot;

    totalAdjustedFeet += sumpSubtotalFeet;
    retailPrice += sumpCost;
  }

  return {
    price: round2(retailPrice),
    breakdown: '',
    totalFeetConsumed: round2(totalAdjustedFeet)
  };
}

interface StandOptions {
  enabled?: boolean;
  layers?: number;
  tubular?: string;
  stainless?: boolean;
  cabinet?: boolean;
  cabinetDoors?: number;
  cabinetType?: string;
  canopy?: boolean;
  canopyHeight?: number;
  sumpHolder?: boolean;
  sumpWidth?: number;
  unit?: string;
}

interface StandCalculation {
  enabled: true;
  price: number;
  breakdown: string;
  totalFeetConsumed: number;
  layers: number;
  tubular: string;
  stainless: boolean;
  cabinet: boolean;
  cabinetDoors: number;
  cabinetPrice: number;
  cabinetType: string;
  canopy: boolean;
  canopyHeightInches: number;
  canopyPrice: number;
  framePrice: number;
  sumpHolder: boolean;
  sumpWidth: number;
  unit: string;
  heightInches: number;
  notice: TubularSafetyResult['notice'];
}

// Hand-ported copy of the Cabinet/Canopy pricing in docs/WebAquariumCalculator/custom-aquarium-calculator.js
// (getDefaultCabinetDoors/computePlywoodPanels/calculateStandPlywood) - keep both in sync. 18mm laminated
// plywood, priced per sq ft: area x (sheet / 32) x (1 + waste %) x markup, min 'Plywood Minimum', + door hardware.
const PLYWOOD_SHEET_SQFT = 32;
const STAND_FOOTING_INCHES = 3;
const DEFAULT_CANOPY_HEIGHT_INCHES = 6;

function getDefaultCabinetDoors(lengthInches: number): number {
  return 2 * Math.max(1, Math.round((Number(lengthInches) || 0) / 36));
}

// Cabinet Type -> its Pricing Setup keys (copy of CABINET_MATERIALS in custom-aquarium-calculator.js).
// Applies to the canopy too.
interface CabinetMaterial { label: string; sheet: string; waste: string; markup: string; canopyMarkup: string; minimum: string; hardware: string }
const CABINET_MATERIALS: Record<string, CabinetMaterial> = {
  'Laminated Plywood': {
    label: '18mm laminated plywood', sheet: 'Plywood Sheet 18mm', waste: 'Plywood Waste %', markup: 'Plywood Markup',
    canopyMarkup: 'Canopy Markup', minimum: 'Plywood Minimum', hardware: 'Door Hardware per sq ft'
  },
  Aluminum: {
    label: '4mm aluminum ACP', sheet: 'Aluminum ACP Sheet 4mm', waste: 'Aluminum Waste %', markup: 'Aluminum Markup',
    canopyMarkup: 'Aluminum Canopy Markup', minimum: 'Aluminum Minimum', hardware: 'Aluminum Door Hardware per sq ft'
  }
};

function computePlywoodPanels(title: string, panels: Array<[string, number, number]>, extraPrices: Record<string, number>, doorCount: number, material: CabinetMaterial) {
  const sheetPrice = Number(extraPrices[material.sheet]);
  const wastePct = Number(extraPrices[material.waste]);
  const markup = Number(extraPrices[title === 'Canopy' ? material.canopyMarkup : material.markup]);
  const minimum = Number(extraPrices[material.minimum]);
  const hardwarePerSqFt = Number(extraPrices[material.hardware]) || 0;
  // Doors are the front panel (panels[0]) - hardware scales with its area, not the door count.
  const doorAreaSqFt = doorCount > 0 ? (panels[0][1] * panels[0][2]) / 144 : 0;
  const ratePerSqFt = (sheetPrice / PLYWOOD_SHEET_SQFT) * (1 + wastePct / 100) * markup;
  let areaSqFt = 0;
  const breakdown = [title + ' (' + material.label + '):'];
  for (const [label, w, h] of panels) {
    const panelSqFt = (w * h) / 144;
    areaSqFt += panelSqFt;
    breakdown.push(`${label}: ${round2(w)}" x ${round2(h)}" = ${panelSqFt.toFixed(2)} sq ft`);
  }
  const areaPrice = areaSqFt * ratePerSqFt;
  const hardware = doorAreaSqFt * hardwarePerSqFt;
  const price = round2(Math.max(minimum, areaPrice) + hardware);
  breakdown.push(`Total area: ${areaSqFt.toFixed(2)} sq ft at ${ratePerSqFt.toFixed(2)} per sq ft = ${areaPrice.toFixed(2)}${areaPrice < minimum ? ` -> minimum ${minimum.toFixed(2)}` : ''}`);
  if (hardware > 0) breakdown.push(`Door hardware (${doorCount} doors): ${doorAreaSqFt.toFixed(2)} sq ft x ${hardwarePerSqFt} = ${hardware.toFixed(2)}`);
  breakdown.push(`${title} price = ${price.toFixed(2)}`);
  return { areaSqFt: round2(areaSqFt), price, breakdown: breakdown.join('\n') };
}

// Cabinet = front (doors) + back + 2 sides over the stand frame height (minus footing);
// Canopy = front + back + 2 sides at canopy height + top. A sump-holder section is never enclosed.
function calculateStandPlywood(
  lengthInches: number,
  widthInches: number,
  standHeightInches: number,
  stand: StandOptions,
  unit: string,
  extraPricingSetupRows: Array<Record<string, unknown>> | undefined
) {
  const extraPrices = buildExtraPriceLookup(extraPricingSetupRows);
  const cabinetType = CABINET_MATERIALS[stand.cabinetType || ''] ? (stand.cabinetType as string) : 'Laminated Plywood';
  const material = CABINET_MATERIALS[cabinetType];
  const result = { cabinetType, cabinetPrice: 0, canopyPrice: 0, cabinetDoors: 0, canopyHeightInches: 0, breakdown: [] as string[] };

  if (stand.cabinet) {
    const cabinetHeight = Math.max(0, standHeightInches - STAND_FOOTING_INCHES);
    const doors = Math.round(Number(stand.cabinetDoors)) > 0 ? Math.round(Number(stand.cabinetDoors)) : getDefaultCabinetDoors(lengthInches);
    const cabinet = computePlywoodPanels('Cabinet', [
      [`Front (${doors} doors)`, lengthInches, cabinetHeight],
      ['Back', lengthInches, cabinetHeight],
      ['Left side', widthInches, cabinetHeight],
      ['Right side', widthInches, cabinetHeight]
    ], extraPrices, doors, material);
    result.cabinetPrice = cabinet.price;
    result.cabinetDoors = doors;
    result.breakdown.push(cabinet.breakdown);
  }

  if (stand.canopy) {
    const canopyHeight = Number(stand.canopyHeight) > 0 ? toInches(Number(stand.canopyHeight), unit) : DEFAULT_CANOPY_HEIGHT_INCHES;
    const canopy = computePlywoodPanels('Canopy', [
      ['Front', lengthInches, canopyHeight],
      ['Back', lengthInches, canopyHeight],
      ['Left side', widthInches, canopyHeight],
      ['Right side', widthInches, canopyHeight],
      ['Top', lengthInches, widthInches]
    ], extraPrices, 0, material);
    result.canopyPrice = canopy.price;
    result.canopyHeightInches = round2(canopyHeight);
    result.breakdown.push(canopy.breakdown);
  }

  return result;
}

function calculateStand(
  lengthInches: number,
  widthInches: number,
  glassThickness: string,
  standOptions: StandOptions | undefined,
  defaultUnit: string,
  tubularPricingSetupRows: Array<Record<string, unknown>> | undefined,
  extraPricingSetupRows?: Array<Record<string, unknown>>
): StandCalculation | null {
  const stand = standOptions || {};
  if (!stand.enabled) {
    return null;
  }

  const layers = Math.max(2, Math.round(Number(stand.layers) || 2));
  const tubularSafety = enforceStandTubularSafety(lengthInches, widthInches, glassThickness, stand.tubular || '1x1');
  const tubular = tubularSafety.tubular;
  const standHeightInches = getStandHeightInches(layers, tubular);
  const stainless = Boolean(stand.stainless);
  const cabinet = Boolean(stand.cabinet);
  const sumpHolder = Boolean(stand.sumpHolder);
  const standUnit = stand.unit || defaultUnit || 'Inches';
  const sumpWidthInches = sumpHolder ? toInches(stand.sumpWidth || 0, standUnit) : 0;
  const computed = computeStandRetailPrice(
    inchesToFeet(lengthInches),
    inchesToFeet(widthInches),
    inchesToFeet(standHeightInches),
    layers,
    tubular,
    stainless,
    inchesToFeet(sumpWidthInches),
    buildTubularPriceLookup(tubularPricingSetupRows)
  );
  const plywood = calculateStandPlywood(lengthInches, widthInches, standHeightInches, stand, standUnit, extraPricingSetupRows);

  return {
    enabled: true,
    price: round2(computed.price + plywood.cabinetPrice + plywood.canopyPrice),
    framePrice: computed.price,
    breakdown: [computed.breakdown].concat(plywood.breakdown).join('\n\n'),
    totalFeetConsumed: computed.totalFeetConsumed,
    layers,
    tubular,
    stainless,
    cabinet,
    cabinetDoors: plywood.cabinetDoors,
    cabinetType: plywood.cabinetType,
    cabinetPrice: plywood.cabinetPrice,
    canopy: Boolean(stand.canopy),
    canopyHeightInches: plywood.canopyHeightInches,
    canopyPrice: plywood.canopyPrice,
    sumpHolder,
    sumpWidth: round2(sumpWidthInches),
    unit: standUnit,
    heightInches: round2(standHeightInches),
    notice: tubularSafety.notice
  };
}

function buildGlassPriceLookup(rows: Array<Record<string, unknown>> | null | undefined, _preferredUom: string): Record<string, number> {
  const lookup: Record<string, number> = Object.assign({}, DEFAULT_GLASS_PRICES);
  const items = Array.isArray(rows) ? rows : [];

  for (const row of items) {
    const units = String((row as any).thickness ?? (row as any).Thickness ?? '').trim();
    const price = Number((row as any).price_per_sqft ?? (row as any).pricePerSqFt ?? (row as any).PricePerSqFt ?? 0);
    if (!units || !(price > 0)) {
      continue;
    }

    lookup[normalizeGlass(units)] = price;
  }

  return lookup;
}

interface GlassSafetyResult {
  isSafe: boolean;
  message: string;
  autoChangeTo: string | null;
}

// Hand-ported copy of getMinimumGlassForSize in docs/WebAquariumCalculator/custom-aquarium-calculator.js
// (shop standard, 2026-10-02) - keep both in sync. Height/length based; non-rimless = braced.
function getMinimumGlassForSize(
  lengthInches: number,
  widthInches: number,
  heightInches: number,
  isRimless: boolean
): { glass: string; reason: string } {
  const gallons = cubicInchesToGallons(lengthInches * widthInches * heightInches);

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

function validateGlassSafety(
  lengthInches: number,
  widthInches: number,
  heightInches: number,
  glassThickness: string,
  isTempered: boolean,
  isRimless: boolean
): GlassSafetyResult {
  const glassMm = extractGlassMm(normalizeGlass(glassThickness));
  const minimum = getMinimumGlassForSize(lengthInches, widthInches, heightInches, isRimless);

  if (glassMm < extractGlassMm(minimum.glass)) {
    return { isSafe: false, message: `${minimum.reason} Auto-upgrading glass to ${minimum.glass}.`, autoChangeTo: minimum.glass };
  }

  if ((widthInches >= 36 || heightInches >= 36) && !isTempered) {
    return { isSafe: false, message: 'Width or height is 36 inches or more. Tempered glass is mandatory for this custom aquarium.', autoChangeTo: null };
  }

  return { isSafe: true, message: 'OK', autoChangeTo: null };
}

function getRequiredGlassFromMessage(message: string): string | null {
  const text = String(message || '').toLowerCase();
  if (text.indexOf('19mm') >= 0) return '19mm';
  if (text.indexOf('12mm') >= 0) return '12mm';
  if (text.indexOf('10mm') >= 0) return '10mm';
  if (text.indexOf('6mm') >= 0) return '6mm';
  if (text.indexOf('3mm') >= 0) return '3mm';
  return null;
}

interface AquariumQuoteInput {
  unit?: string;
  option?: string;
  glassThickness?: string;
  temperedGlass?: boolean;
  lowIron?: boolean;
  aio?: boolean;
  rimless?: boolean;
  highStrip?: boolean;
  aquascapeService?: boolean;
  enclosure?: boolean;
  turtleTank?: boolean;
  stand?: StandOptions;
  filtrationSump?: {
    enabled?: boolean;
    type?: string;
    length?: number;
    width?: number;
    height?: number;
    unit?: string;
    glassThickness?: string;
    filterMedias?: boolean;
    piping?: boolean;
    overflowBox?: boolean;
    allumTopCover?: boolean;
    lightPrice?: number;
    pumpPrice?: number;
  };
  length: number;
  width: number;
  height: number;
  holeCount?: number;
  dividerCount?: number;
  stickerBackground?: { enabled?: boolean; allSides?: boolean; type?: string };
  stickerBottom?: { enabled?: boolean; type?: string };
  stickerPricingSetupRows?: Array<Record<string, unknown>>;
  glassPricingSetupRows?: Array<Record<string, unknown>>;
  glassPricingUom?: string;
  tubularPricingSetupRows?: Array<Record<string, unknown>>;
  extraPricingSetupRows?: Array<Record<string, unknown>>;
}

// Mirrors docs/WebAquariumCalculator/custom-aquarium-calculator.js's DEFAULT_EXTRA_PRICES/
// buildExtraPriceLookup - last-resort fallback only, live values come from
// public.AquariumExtraPricingSetup (supabase_aquarium_extra_pricing.sql).
const DEFAULT_EXTRA_PRICES: Record<string, number> = {
  Hole: 150,
  'Plywood Sheet 18mm': 3900,
  'Plywood Waste %': 15,
  'Plywood Markup': 1.6,
  'Canopy Markup': 1.3,
  'Plywood Minimum': 2200,
  'Door Hardware per sq ft': 60,
  'Aluminum ACP Sheet 4mm': 7000,
  'Aluminum Waste %': 10,
  'Aluminum Markup': 1.8,
  'Aluminum Canopy Markup': 1.5,
  'Aluminum Minimum': 3000,
  'Aluminum Door Hardware per sq ft': 60
};

function buildExtraPriceLookup(rows: Array<Record<string, unknown>> | undefined): Record<string, number> {
  const lookup: Record<string, number> = { ...DEFAULT_EXTRA_PRICES };
  for (const row of rows ?? []) {
    const key = String((row as Record<string, unknown>).feature_key ?? (row as Record<string, unknown>).FeatureKey ?? '').trim();
    const price = Number((row as Record<string, unknown>).price ?? (row as Record<string, unknown>).Price ?? 0);
    if (!key || !(price >= 0)) continue;
    lookup[key] = price;
  }
  return lookup;
}

// custom-aquarium-calculator.js's calculateStickerPrice/getStickerRate (aquarium background/bottom
// stickers). Rates come from StickerPricingSetup via buildStickerPriceLookup (defined further down).
function calculateAquariumStickerPrice(panelLengthInches: number, panelWidthInches: number, pricePerSqFt: number): number {
  if (panelLengthInches <= 0 || panelWidthInches <= 0 || pricePerSqFt <= 0) return 0;
  return ceilNearest10((panelLengthInches / 12) * (panelWidthInches / 12) * pricePerSqFt);
}

function getAquariumStickerRate(stickerType: string | undefined, rows: Array<Record<string, unknown>> | undefined): number {
  const flat = buildStickerPriceLookup(rows).flat;
  return String(stickerType || 'plain').trim().toLowerCase() === 'tiles'
    ? Number(flat['Tiles Sticker']) || 0
    : Number(flat['Plain Sticker']) || 0;
}

function calculateCustomAquarium(input: AquariumQuoteInput): Record<string, unknown> {
  const options = input || ({} as AquariumQuoteInput);
  const unit = options.unit || 'Inches';
  const optionType = String(options.option || 'Aquarium only');
  const requestedGlass = normalizeGlass(options.glassThickness || '6mm');
  const requestedTempered = Boolean(options.temperedGlass);
  let glass = requestedGlass;
  let isTempered = requestedTempered;
  const isLowIron = Boolean(options.lowIron);
  const isAio = Boolean(options.aio);
  const isRimless = Boolean(options.rimless);
  const hasHighStrip = Boolean(options.highStrip);
  const hasAquascapeService = Boolean(options.aquascapeService);
  const hasEnclosure = Boolean(options.enclosure);
  // Turtle tank (water + basking platform): priced the same as Enclosure for now (x2.1 below).
  const hasTurtleTank = Boolean(options.turtleTank);
  const hasStand = Boolean(options.stand && options.stand.enabled);
  const hasFiltrationSump = Boolean((options.filtrationSump && options.filtrationSump.enabled) || optionType.toLowerCase() === 'complete setup');
  const holeCount = Math.max(0, Math.round(Number(options.holeCount) || 0));
  const dividerCount = Math.max(0, Math.round(Number(options.dividerCount) || 0));
  const lengthInches = toInches(options.length, unit);
  const widthInches = toInches(options.width, unit);
  const heightInches = toInches(options.height, unit);
  let safetyNotice: { title: string; message: string; updatedGlassThickness: string } | null = null;

  if (!(lengthInches > 0) || !(widthInches > 0) || !(heightInches > 0)) {
    return { ok: false, error: 'Please enter valid positive dimensions.', autoChangeTo: null };
  }

  if (isLowIron) {
    isTempered = true;
  }
  if ((widthInches >= 36 || heightInches >= 36) && !isTempered) {
    isTempered = true;
  }
  if (isAio && hasFiltrationSump) {
    return { ok: false, error: 'AIO cannot be combined with filtration sump.', autoChangeTo: null };
  }
  if (isAio && hasEnclosure) {
    return { ok: false, error: 'AIO and enclosure cannot both be selected.', autoChangeTo: null };
  }
  if (hasFiltrationSump && hasEnclosure) {
    return { ok: false, error: 'Enclosure cannot be selected when filtration sump is enabled.', autoChangeTo: null };
  }
  if (hasTurtleTank && hasEnclosure) {
    return { ok: false, error: 'Turtle tank and enclosure cannot both be selected.', autoChangeTo: null };
  }
  if (isAio && extractGlassMm(glass) === 3) {
    glass = '6mm';
  }
  if (isLowIron && isTempered && extractGlassMm(glass) < 10) {
    glass = '10mm';
  }

  let safety = validateGlassSafety(lengthInches, widthInches, heightInches, glass, isTempered, isRimless);
  if (safety.autoChangeTo) {
    safetyNotice = { title: 'Glass Auto-upgrade', message: safety.message, updatedGlassThickness: safety.autoChangeTo };
    glass = safety.autoChangeTo;
    safety = validateGlassSafety(lengthInches, widthInches, heightInches, glass, isTempered, isRimless);
  }

  if (!safety.isSafe) {
    const requiredGlass = getRequiredGlassFromMessage(safety.message);
    if (requiredGlass && requiredGlass !== glass) {
      const originalSafetyMessage = safety.message;
      glass = requiredGlass;
      if (String(safety.message || '').toLowerCase().indexOf('tempered 12mm') >= 0) {
        isTempered = true;
      }
      safetyNotice = { title: 'Glass Auto-upgrade', message: originalSafetyMessage + '\n\nGlass thickness has been updated to ' + requiredGlass + '.', updatedGlassThickness: requiredGlass };
      safety = validateGlassSafety(lengthInches, widthInches, heightInches, glass, isTempered, isRimless);
    }
  }

  if (!safety.isSafe) {
    return {
      ok: false,
      error: safety.message,
      autoChangeTo: safety.autoChangeTo || getRequiredGlassFromMessage(safety.message) || null,
      requested: { glassThickness: requestedGlass, temperedGlass: requestedTempered },
      normalized: { glassThickness: glass, temperedGlass: isTempered },
      safetyNotice
    };
  }

  const gallons = cubicInchesToGallons(lengthInches * widthInches * heightInches);
  const glassPrices = Object.assign({}, buildGlassPriceLookup(options.glassPricingSetupRows, options.glassPricingUom || 'MM'));
  const basePricePerSqFt = Number(glassPrices[glass]) || 100;
  let finalPricePerSqFt = basePricePerSqFt;
  const glassAreaSqFt = getGlassAreaSqFt(lengthInches, widthInches, heightInches);
  const standCalculation = calculateStand(lengthInches, widthInches, glass, options.stand, unit, options.tubularPricingSetupRows, options.extraPricingSetupRows);
  const extraPrices = buildExtraPriceLookup(options.extraPricingSetupRows);
  const holePricePerHole = Number(extraPrices.Hole) || DEFAULT_EXTRA_PRICES.Hole;
  const components: Record<string, number> = {
    glass: 0,
    highStrip: 0,
    sumpGlass: 0,
    filterMedia: 0,
    overflowBox: 0,
    light: 0,
    pump: 0,
    piping: 0,
    allumTopCover: 0,
    aquascapeService: 0,
    holes: 0,
    divider: 0,
    stickerBackground: 0,
    stickerBottom: 0,
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

  let calculatedPrice = glassAreaSqFt * finalPricePerSqFt;
  components.glass = round2(calculatedPrice);

  if (hasHighStrip) {
    const highStripLinearFeet = ((lengthInches + widthInches) * 2) / 12;
    components.highStrip = round2(highStripLinearFeet * 90);
    calculatedPrice += components.highStrip;
  }

  // Filtration sump - same as custom-aquarium-calculator.js: glass/media/overflow/light/pump go in
  // BEFORE the multipliers and the round-to-10, piping and the Allum top cover after.
  let normalizedSump: Record<string, unknown> | null = null;
  if (hasFiltrationSump) {
    const sump = options.filtrationSump || {};
    const sumpUnit = sump.unit || unit;
    const sumpType = String(sump.type || 'Undersump');
    const sumpLengthInches = toInches(sump.length as number, sumpUnit);
    const sumpWidthInches = toInches(sump.width as number, sumpUnit);
    const sumpHeightInches = toInches(sump.height as number, sumpUnit);
    const sumpGlass = sump.glassThickness ? normalizeGlass(sump.glassThickness) : glass;
    normalizedSump = {
      type: sumpType,
      unit: sumpUnit,
      glassThickness: sumpGlass,
      lengthInches: round2(sumpLengthInches),
      widthInches: round2(sumpWidthInches),
      heightInches: round2(sumpHeightInches)
    };
    if (!(sumpLengthInches > 0 && sumpWidthInches > 0 && sumpHeightInches > 0)) {
      return { ok: false, error: 'Please give the sump length, width and height (all greater than 0).', autoChangeTo: null };
    }
    const isOverhead = sumpType.toLowerCase() === 'overhead sump';
    let sumpPricePerSqFt = Number(glassPrices[sumpGlass]) || basePricePerSqFt;
    if (isTempered) sumpPricePerSqFt *= 2;
    components.sumpGlass = round2(getGlassAreaSqFt(sumpLengthInches, sumpWidthInches, sumpHeightInches) * sumpPricePerSqFt);
    calculatedPrice += components.sumpGlass;

    if (sump.filterMedias) {
      const liters = (sumpLengthInches / 12) * (sumpWidthInches / 12) * (sumpHeightInches / 12) * 28.316;
      const mediaKg = Math.round(liters * (isOverhead ? 0.18 : 0.04));
      components.filterMedia = round2(mediaKg * 300);
      calculatedPrice += components.filterMedia;
      normalizedSump.filterMediaKg = mediaKg;
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
      components.piping = isOverhead ? 540 : 2500;
    }
    if (sump.allumTopCover) {
      const effectiveWidthInches = isOverhead ? Math.max(0, widthInches - sumpWidthInches) : widthInches;
      const allumRate = buildStickerPriceLookup(options.stickerPricingSetupRows).flat['Allum TopCover'];
      components.allumTopCover = ceilNearest10((lengthInches / 12) * (effectiveWidthInches / 12) * allumRate);
    }
  }

  const lowerOption = optionType.toLowerCase();
  if (lowerOption === 'undersump' || lowerOption === 'overheadsump' || lowerOption === 'overhead sump') {
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

  if (components.piping > 0) calculatedPrice += components.piping;
  if (components.allumTopCover > 0) calculatedPrice += components.allumTopCover;

  // Background (back panel L x H, + both sides W x H when allSides) / Bottom (L x W) stickers -
  // same as custom-aquarium-calculator.js's stickerBackground/stickerBottom components.
  const stickerBackground = options.stickerBackground || {};
  if (stickerBackground.enabled) {
    const backgroundRate = getAquariumStickerRate(stickerBackground.type, options.stickerPricingSetupRows);
    components.stickerBackground = calculateAquariumStickerPrice(lengthInches, heightInches, backgroundRate);
    if (stickerBackground.allSides) {
      components.stickerBackground += calculateAquariumStickerPrice(widthInches, heightInches, backgroundRate) * 2;
    }
    calculatedPrice += components.stickerBackground;
  }
  const stickerBottom = options.stickerBottom || {};
  if (stickerBottom.enabled) {
    const bottomRate = getAquariumStickerRate(stickerBottom.type, options.stickerPricingSetupRows);
    components.stickerBottom = calculateAquariumStickerPrice(lengthInches, widthInches, bottomRate);
    calculatedPrice += components.stickerBottom;
  }

  if (holeCount > 0) {
    components.holes = round2(holeCount * holePricePerHole);
    calculatedPrice += components.holes;
  }

  if (dividerCount > 0) {
    const dividerAreaSqFt = (widthInches * heightInches) / 144;
    const dividerPriceEach = round2(dividerAreaSqFt * finalPricePerSqFt * 1.2);
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

  const aquariumOnlyPrice = calculatedPrice;

  if (hasStand && standCalculation) {
    calculatedPrice += components.stand;
  }

  return {
    ok: true,
    totalPrice: round2(calculatedPrice),
    aquariumOnlyPrice: round2(aquariumOnlyPrice),
    gallons: round2(gallons),
    components,
    requested: { glassThickness: requestedGlass, temperedGlass: requestedTempered },
    normalized: {
      unit,
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
    safety,
    safetyNotice,
    standNotice: standCalculation ? standCalculation.notice : null
  };
}

// ============================================================================
// END: ported from custom-aquarium-calculator.js
// ============================================================================

export const TOOLS: Anthropic.Tool[] = [
  {
    name: 'search_items',
    description:
      'Search the store\'s product catalog by name, keyword, brand, or SKU. Use this whenever a customer asks if you carry something, or asks about the price/stock of a specific product. Each result has quantity_in_stock (all-branch total) and stock_by_location (real per-branch count for Amaya and GMA - use that when telling a customer about stock). For Aquarium/Stand/Sump items the stock is the number of finished serial-tracked units on hand (in transit or still being built are NOT counted); for everything else it is the inventory ledger balance. Items with variants also carry stock_by_variant - an array of {option, sku, Amaya, GMA}, one per variant that has stock (option is usually the color, e.g. "Black Sealant", "Clear Sealant", "Black Paint", "White Paint") (variants missing from it have 0 at both branches). Results may include a wholesale_price (only for wholesale-eligible categories, and only when an actual price is set - see the WHOLESALE PRICING rule below for when you\'re allowed to mention it).',
    input_schema: {
      type: 'object',
      properties: {
        query: { type: 'string', description: 'Keyword(s) to search for, e.g. "canister filter" or "betta food".' }
      },
      required: ['query']
    }
  },
  {
    name: 'list_categories',
    description:
      'List all product categories/departments the store carries. Use when a customer asks what kinds of things you sell, or wants to browse rather than search for something specific.',
    input_schema: { type: 'object', properties: {} }
  },
  {
    name: 'list_wholesale_prices',
    description:
      'List every item that currently has a wholesale price set (only Aquarium/Stand/Sump Filtration items ever do - see the WHOLESALE PRICING rule). Use this when a customer asks for the wholesale price LIST/catalog/rate sheet in general, not a specific item - for a specific item\'s price use search_items instead.',
    input_schema: { type: 'object', properties: {} }
  },
  {
    name: 'list_aquarium_sets',
    description:
      'List the ready-made complete aquarium SETS (SET category packages) - each with its fixed package price, stock, and description. The DESCRIPTION is the customer-facing list of what the set includes (aquarium size/glass, stand, sump, piping, pump, lights, filter media, stickers, etc.) - describe the set from it, in plain words. "includes" is an internal, often incomplete list of item codes - never read those codes out or use them as the contents list. Use this whenever a customer asks for a complete setup / full setup / package, BEFORE building a custom quote, so you can offer a matching ready-made set first. Don\'t guess at anything the description doesn\'t say.',
    input_schema: { type: 'object', properties: {} }
  },
  {
    name: 'list_items_in_category',
    description:
      'List active items in one specific category, with price and stock (quantity_in_stock is the all-branch total; stock_by_location is the per-branch count for Amaya and GMA - use that when telling a customer about stock; for Aquarium/Stand/Sump items it counts finished serial-tracked units on hand only; items with variants also carry stock_by_variant, an array of {option (usually the color), sku, Amaya, GMA} per in-stock variant). Use after list_categories, or when the customer names a category directly (e.g. "what filters do you have").',
    input_schema: {
      type: 'object',
      properties: {
        category_code: { type: 'string', description: 'The category code, from list_categories.' }
      },
      required: ['category_code']
    }
  },
  {
    name: 'get_order_status',
    description:
      'Look up the status of a previously placed order by its order number. Works for a portal Automated Order (format AO-xxxxx, e.g. from a custom quote), a regular Online Order placed through Pancake/checkout, or a Walk-in Order bought at one of our stores (by its POS receipt number, e.g. RS-0000010861, or its order ID) - just pass whatever number the customer gives you, this tries all of them. An Online Order result also includes a receiptUrl link to a printable/PDF-saveable receipt page, for when the customer specifically asks for a receipt rather than just a status update (Walk-in Orders have none). Never call this without an order number - if the customer only says "my order", ask them for the order number (or, for an in-store purchase, the receipt number) first.',
    input_schema: {
      type: 'object',
      properties: {
        order_no: { type: 'string', description: 'The order number, e.g. AO-00001, a Pancake Online Order ID, or a store receipt number like RS-0000010861.' }
      },
      required: ['order_no']
    }
  },
  {
    name: 'escalate_to_staff',
    description:
      'Notify store staff that this conversation needs a human follow-up. Use for refund requests, complaints, damaged/wrong items, or when the customer explicitly asks for a person. Do NOT use this just because a customer asked for a discount or a lower price - decline that yourself per the DISCOUNTS / PRICE CHANGES rule instead; only escalate if they turn it into a complaint or keep insisting after you\'ve declined.',
    input_schema: {
      type: 'object',
      properties: {
        reason: { type: 'string', description: 'Brief summary of why this needs staff attention.' }
      },
      required: ['reason']
    }
  },
  {
    name: 'log_capability_gap',
    description:
      'Call this when you genuinely do not have the knowledge, pricing, or tools to answer something - a type of request you were never given information about (e.g. a repair job type compute_repair_quote doesn\'t cover, like a cracked stand frame or filtration/electrical repair, as opposed to a glass panel replacement or resealing/leak repair you CAN quote with compute_repair_quote). Do NOT use this for things you already know how to handle but that need a human to finish - use escalate_to_staff for those instead. Always tell the person honestly first that this isn\'t something you\'re programmed to help with yet, THEN call this tool - never claim their request was sent somewhere or that an answer is coming if nothing was actually set in motion.',
    input_schema: {
      type: 'object',
      properties: {
        question: { type: 'string', description: 'The customer/staff request, as close to verbatim as possible.' }
      },
      required: ['question']
    }
  },
  {
    name: 'compute_aquarium_quote',
    description:
      'Compute a real price quote for a custom aquarium tank. Only for a CUSTOM build - first check the ready-made standard aquariums with list_items_in_category("AQUARIUM") and offer one that fits the requested size (see the STANDARD SIZE FIRST rule); never assume custom just because the customer gave dimensions. Ask for length/width/height and glass thickness at minimum; ask about a matching stand only if the customer mentions wanting one. This is the store\'s own official pricing formula - the exact same one staff use - so state the result with confidence, not as a rough estimate. Never state a price for a custom tank without calling this tool first.',
    input_schema: {
      type: 'object',
      properties: {
        length: { type: 'number', description: 'Tank length.' },
        width: { type: 'number', description: 'Tank width.' },
        height: { type: 'number', description: 'Tank height.' },
        unit: { type: 'string', enum: ['Inches', 'cm', 'mm', 'ft'], description: 'Defaults to Inches if not specified.' },
        glass_thickness: { type: 'string', enum: ['3mm', '6mm', '10mm', '12mm', '19mm'], description: 'Defaults to 6mm if not specified. Any tank 4 feet (48 inches) tall or more is automatically upgraded to 19mm (3/4 inch) glass for safety, whatever is passed here.' },
        tempered_glass: { type: 'boolean' },
        low_iron: { type: 'boolean' },
        rimless: { type: 'boolean', description: 'Rimless tank (no top frame bracing) - requires thicker glass than a braced tank of the same size (6mm from 10 gallons; 10mm from 30 gallons or over 15 inches tall / 48 inches long). Set true if the customer asks for rimless OR says they will use a hang-on-back (HOB) filter, since a hang-on-back setup calls for a rimless tank.' },
        high_strip: { type: 'boolean', description: 'An extra glass strip along the top rim.' },
        hole_count: { type: 'integer', description: 'Number of drilled holes for the aquarium, if any. Flat rate per hole - ask the customer how many they need before including this.' },
        divider_count: { type: 'integer', description: 'Number of internal glass dividers/partitions, if any. Priced from the tank\'s own glass rate for a Width x Height panel, plus 20%, per divider.' },
        add_sump: { type: 'boolean', description: 'Set true to include a filtration sump (part of a complete setup). Needs sump_length/sump_width/sump_height. Cannot be combined with enclosure.' },
        sump_type: { type: 'string', enum: ['Undersump', 'Overhead Sump'], description: 'Undersump = the sump sits inside the stand under the tank (usually with an overflow box); Overhead Sump = a tray sump on top of the tank. Defaults to Undersump. Only used when add_sump is true.' },
        sump_length: { type: 'number', description: 'Sump length, same unit as the tank. Only used when add_sump is true.' },
        sump_width: { type: 'number', description: 'Sump width, same unit as the tank. Only used when add_sump is true.' },
        sump_height: { type: 'number', description: 'Sump height, same unit as the tank. Only used when add_sump is true.' },
        sump_glass_thickness: { type: 'string', enum: ['3mm', '6mm', '10mm', '12mm'], description: 'Sump glass. Leave out to use the same glass as the tank. Only used when add_sump is true.' },
        sump_filter_media: { type: 'boolean', description: 'Include filter media for the sump (amount in kg is worked out from the sump size). Only used when add_sump is true.' },
        sump_piping: { type: 'boolean', description: 'Include the set of piping/plumbing. Only used when add_sump is true.' },
        sump_overflow_box: { type: 'boolean', description: 'Include an overflow box (normally for an Undersump). Only used when add_sump is true.' },
        sump_allum_top_cover: { type: 'boolean', description: 'Include an aluminum top cover for the tank. Only used when add_sump is true.' },
        pump_item_code: { type: 'string', description: 'Item code of the submersible pump to include, taken from list_items_in_category with category_code "PUMP" (pick one with the customer, or suggest one that fits the tank). Priced at that item\'s own catalog price. Only used when add_sump is true.' },
        pump_quantity: { type: 'integer', description: 'How many of that pump per sump. Defaults to 1.' },
        light_item_code: { type: 'string', description: 'Item code of the light to include, taken from list_items_in_category with category_code "LIGHTS". Priced at that item\'s own catalog price. Only used when add_sump is true.' },
        light_quantity: { type: 'integer', description: 'How many of that light per sump. Defaults to 1.' },
        sticker_background: { type: 'string', enum: ['none', 'plain', 'tiles'], description: 'Background sticker on the back glass: "plain" (Plain Sticker) or "tiles" (Sticker Tiles). Leave out / "none" unless the customer asks for a background sticker. Priced per sq ft of the back panel (Length x Height), rounded up to the nearest 10.' },
        sticker_background_all_sides: { type: 'boolean', description: 'Also cover both side panels (Width x Height each) with the background sticker, not just the back. Only used when sticker_background is plain/tiles.' },
        sticker_bottom: { type: 'string', enum: ['none', 'plain', 'tiles'], description: 'Bottom sticker under the tank floor (Length x Width): "plain" or "tiles". Leave out / "none" unless the customer asks for one.' },
        enclosure: { type: 'boolean', description: 'Set true if the customer wants an enclosure - a dry terrarium/vivarium-style glass build (e.g. for reptiles, amphibians, insects) with sliding glass front doors and a mesh screen top, no water. It raises the aquarium price, so only set it when they ask for an enclosure/terrarium/vivarium. Cannot be combined with turtle_tank.' },
        turtle_tank: { type: 'boolean', description: 'Set true if the customer wants a turtle tank - an aquarium with a built-in basking area (a ledge above the water line with a ramp into the water). It raises the aquarium price, so only set it when they ask for a turtle tank / basking area.' },
        add_stand: { type: 'boolean', description: 'Set true only if the customer wants a matching stand included.' },
        stand_layers: { type: 'integer', description: 'Number of stand shelves/layers, minimum 2. Only used when add_stand is true.' },
        stand_tubular: { type: 'string', enum: ['1x1', '1.5x1.5', '2x2'], description: 'Stand frame tubular size. Only used when add_stand is true.' },
        stand_stainless: { type: 'boolean', description: 'Stainless steel stand frame instead of regular. Only used when add_stand is true.' },
        stand_cabinet: { type: 'boolean', description: 'Enclose the stand as a cabinet (18mm laminated plywood front doors, sides and closed back). Only used when add_stand is true.' },
        cabinet_type: { type: 'string', enum: ['Laminated Plywood', 'Aluminum'], description: 'Material for the cabinet AND canopy: "Laminated Plywood" (18mm, default) or "Aluminum" (4mm ACP aluminum composite panels, pricier). Only used when stand_cabinet or canopy is true.' },
        stand_cabinet_doors: { type: 'integer', description: 'Number of cabinet doors. Leave out to use the default (2 doors per 3ft of length, e.g. 3ft = 2 doors, 6ft = 4 doors). Only used when stand_cabinet is true.' },
        canopy: { type: 'boolean', description: 'Add a canopy (18mm laminated plywood box cover on top of the tank). Only used when add_stand is true.' },
        canopy_height: { type: 'number', description: 'Canopy height, in the same unit as the tank. Leave out to use the default 6 inches. Only used when canopy is true.' }
      },
      required: ['length', 'width', 'height']
    }
  },
  {
    name: 'compute_delivery_quote',
    description:
      'Compute the delivery fee from a store branch to a customer address, using the store\'s own official distance-based formula - the exact same one staff use. Ask which branch (Amaya or GMA) if not already known, and get the full delivery address. State the result with confidence, not as a rough estimate. Never state a delivery fee without calling this tool first.',
    input_schema: {
      type: 'object',
      properties: {
        origin_location: { type: 'string', enum: ['Amaya', 'GMA'], description: 'Which store branch delivers the order.' },
        destination_address: { type: 'string', description: 'The customer\'s full delivery address.' }
      },
      required: ['origin_location', 'destination_address']
    }
  },
  {
    name: 'compute_lalamove_quote',
    description:
      'Gets a REAL Lalamove courier price quote (a live call to Lalamove\'s own API) for a customer who wants to arrange their own Lalamove delivery, as opposed to the store\'s own truck (use compute_delivery_quote for that instead - ask the customer which they want if not already clear). If the exact address can\'t be pinpointed, this automatically falls back to the barangay/city level and the result comes back with approximate: true plus an approximateNote - when that happens, tell the customer plainly the fee is an estimate based on their general area (not the exact address) and may change slightly, don\'t present it as exact. QUOTE ONLY - this cannot actually book the Lalamove ride; if the customer wants to proceed, tell them staff will arrange the actual booking. Before calling, first work out and tell the customer in plain language what size vehicle to book based on what they are having delivered, then pass that as vehicle_type: MOTORCYCLE for a single small/light item (e.g. food, small accessories, a small filter); SEDAN for a few boxes or one small-to-medium item; MPV for a small aquarium/stand or several items; TRUCK330 (a small van/L300-style truck) for a medium-to-large aquarium or stand, or several bulky items; 2000KG_ALUMINUM (a 2-ton truck) for a very large aquarium/stand, multiple large items, or anything unusually bulky/heavy. If the customer asks for a different vehicle than you recommended, use theirs instead. Ask which branch (Amaya or GMA) and the full delivery address if not already known.',
    input_schema: {
      type: 'object',
      properties: {
        origin_location: { type: 'string', enum: ['Amaya', 'GMA'], description: 'Which store branch the item ships from.' },
        destination_address: { type: 'string', description: 'The customer\'s full delivery address.' },
        vehicle_type: {
          type: 'string',
          enum: ['MOTORCYCLE', 'SEDAN', 'MPV', 'TRUCK330', '2000KG_ALUMINUM'],
          description: 'The Lalamove vehicle class that fits what is being delivered - see this tool\'s own description for how to pick one.'
        }
      },
      required: ['origin_location', 'destination_address', 'vehicle_type']
    }
  },
  {
    name: 'compute_sticker_quote',
    description:
      'Compute a real price quote for a custom accessory/sticker/background (Plain Sticker, Tiles Sticker, Acrylic, Acrylic Sump Cover, Allum TopCover, Rubber Matting, Glass, Marine Plywood, or Laminated Plywood) - the store\'s own official pricing formula, the exact same live rates staff use. Priced from Length x Width only (no height - these are flat pieces). Ask for the type, and thickness if that type needs one (Rubber Matting/Glass/Marine Plywood/Laminated Plywood only - Plain Sticker/Tiles Sticker/Acrylic/Acrylic Sump Cover/Allum TopCover have a single flat rate with no thickness choice). State the result with confidence, not as a rough estimate. Never state accessory/sticker/background pricing without calling this tool first - do not recite or guess a price from memory, even if you think you know it.',
    input_schema: {
      type: 'object',
      properties: {
        type: {
          type: 'string',
          enum: ['Plain Sticker', 'Tiles Sticker', 'Acrylic', 'Acrylic Sump Cover', 'Allum TopCover', 'Rubber Matting', 'Glass', 'Marine Plywood', 'Laminated Plywood'],
          description: 'Which accessory/sticker/background type.'
        },
        length: { type: 'number', description: 'Length.' },
        width: { type: 'number', description: 'Width.' },
        unit: { type: 'string', enum: ['Inches', 'cm', 'mm', 'ft'], description: 'Defaults to Inches if not specified.' },
        thickness: { type: 'string', enum: ['3mm', '6mm', '10mm', '12mm', '18mm', '19mm'], description: 'Only used for Rubber Matting (3/6/10/12mm), Glass (3/6/10/12mm, or 19mm = 3/4 inch glass) or Marine Plywood/Laminated Plywood (6/18mm only). Defaults to 6mm if that type needs a thickness and none is given.' },
        is_repair: { type: 'boolean', description: 'Only for type=Glass: true if this is a repair/resurfacing job on existing glass rather than a fresh install - priced at 2.5x the normal rate.' },
        is_tempered: { type: 'boolean', description: 'Only for type=Glass: true if the customer wants tempered glass - priced at 2x the normal glass rate.' }
      },
      required: ['type', 'length', 'width']
    }
  },
  {
    name: 'compute_repair_quote',
    description:
      'Compute a real price quote for repairing/refurbishing an aquarium the customer ALREADY OWNS (a broken/cracked glass panel that needs replacing, or resealing a leak) - the store\'s own official repair pricing formula, the exact same live rates staff use. Only covers glass panel replacement and resealing/leak repair - for any other kind of repair (stand frame, electrical/pump, filtration, etc.) use log_capability_gap instead, this tool cannot quote that. Ask for the aquarium\'s OVERALL Length/Width/Height first (never ask the customer to measure just the damaged panel by itself - each panel\'s own size is worked out from the overall dimensions, same convention as compute_aquarium_quote: Bottom = Length x Width, Front/Back = Length x Height, Left/Right = Width x Height). For repair_type "panel", also ask which panel(s) are damaged (one or more of Bottom/Front/Back/Left/Right) and the glass thickness if known (defaults to 6mm if not given). For repair_type "reseal" (resealing/leak repair), no panel or thickness is needed - it is priced by an estimated tank size tier from the same dimensions, not a per-panel amount. State the result with confidence, not as a rough estimate. Never state repair pricing without calling this tool first. This is QUOTE ONLY - it cannot place an actual repair job; if the customer wants to proceed, tell them staff will need to arrange drop-off/scheduling, then call escalate_to_staff.',
    input_schema: {
      type: 'object',
      properties: {
        repair_type: { type: 'string', enum: ['panel', 'reseal'], description: '"panel" for a broken/cracked glass panel that needs replacing, "reseal" for resealing/a leak.' },
        length: { type: 'number', description: 'Aquarium overall length.' },
        width: { type: 'number', description: 'Aquarium overall width.' },
        height: { type: 'number', description: 'Aquarium overall height.' },
        unit: { type: 'string', enum: ['Inches', 'cm', 'mm', 'ft'], description: 'Defaults to Inches if not specified.' },
        panels: {
          type: 'array',
          items: { type: 'string', enum: ['Bottom', 'Front', 'Back', 'Left', 'Right'] },
          description: 'REQUIRED when repair_type is "panel": which panel(s) are damaged. Ignored for "reseal".'
        },
        glass_thickness: { type: 'string', enum: ['3mm', '6mm', '10mm', '12mm'], description: 'Only used when repair_type is "panel". Defaults to 6mm if not specified.' },
        glass_type: { type: 'string', enum: ['regular', 'tempered', 'low_iron', 'low_iron_tempered'], description: 'Only used when repair_type is "panel": the replacement glass type - "low_iron" is low-iron/ultra-clear glass that is NOT tempered, "low_iron_tempered" is low-iron that is also tempered. Tempered and low-iron cost more than regular. If the aquarium height is 36 inches or more, every panel is automatically priced as tempered (regular -> tempered, low_iron -> low_iron_tempered) - the result marks it. Defaults to "regular" if not specified - ask whether the tank has tempered and/or low-iron glass.' }
      },
      required: ['repair_type', 'length', 'width', 'height']
    }
  },
  {
    name: 'send_item_image',
    description:
      'Sends a photo of a specific product to the customer on Messenger. Only call this AFTER the customer explicitly agrees to see a picture - when a customer asks about a product, first offer in your reply ("want me to send a photo?") and wait for them to say yes before calling this. Requires the item_code from a prior search_items or list_items_in_category result - never guess a code.',
    input_schema: {
      type: 'object',
      properties: {
        item_code: { type: 'string', description: 'The item\'s code, from search_items or list_items_in_category.' }
      },
      required: ['item_code']
    }
  },
  {
    name: 'get_driver_location',
    description:
      'TEST TOOL - checks whether a delivery driver is currently out and tracking, and returns a live-updating tracking link plus how long ago their GPS last updated. Call this immediately whenever a customer asks where the driver is - never ask for an order number first, this tool has nothing to do with orders yet (it is not matched to any specific customer/order - it just reports whichever driver is currently tracking, for testing that GPS reporting works end-to-end). Share the liveTrackingUrl link (a page that keeps updating as the driver moves - tell the customer that) and minutesSinceUpdate directly in your reply; mapsUrl is a fallback snapshot pin only, mention it as an alternative, not the main link. Optionally pass destination_address (ask the customer for their delivery address first, only if they want an ETA) to also estimate driving distance/time from the driver\'s current position to that address. Never state an ETA without calling this tool first.',
    input_schema: {
      type: 'object',
      properties: {
        destination_address: {
          type: 'string',
          description: 'Optional - a delivery address to estimate distance/ETA from the driver\'s current location to.'
        }
      }
    }
  },
  {
    name: 'save_customer_info',
    description:
      'Saves whatever the customer just told you about themselves (name and/or phone number and/or address) to their permanent customer record for this Page - independent of placing an order. Call this AS SOON AS the customer gives you any of these, even if they are just chatting and haven\'t ordered anything yet (e.g. they type their name because you asked, or mention their address in passing) - don\'t wait for create_order to be the only place this gets saved. Pass only the field(s) they actually just gave; never guess or invent a value for a field they didn\'t mention.',
    input_schema: {
      type: 'object',
      properties: {
        name: { type: 'string', description: 'The customer\'s name, exactly as they gave it (or confirmed using their Facebook name).' },
        phone: { type: 'string', description: 'A valid PH mobile number, e.g. 09171234567.' },
        address: { type: 'string', description: 'Their home/delivery address.' }
      }
    }
  },
  {
    name: 'create_order',
    description:
      'Saves a REAL order for the customer in the store\'s system, right now (staff then review and confirm it - it is not sent to the order system until they do). Only ever call this after ALL of the following are true: (1) the customer has ALREADY sent proof of a downpayment or full payment (a payment screenshot - check the conversation for a prior message acknowledging one; never on a verbal promise to pay later), (2) you know exactly which items and quantities they want, using ONLY item_code values returned by a prior search_items or list_items_in_category call - never invent, guess, or reuse a code from a different conversation, (3) you have a name for them (offer to use CUSTOMER\'S FACEBOOK NAME if it\'s known - see the system prompt - rather than always asking them to type it), a valid PH mobile number, and their address (never ask "pickup or delivery" - just ask for the address to save; always pass fulfillment_type as Delivery). Ask for whatever is still missing before calling this, do not guess it. See the PLACING ORDERS system prompt rules for whether this is a second/new order for a conversation that already has one. After a successful call, follow the PLACING ORDERS receipt rule (order number, recap, receiptUrl, confirmation ask) and say staff will review and confirm it shortly.',
    input_schema: {
      type: 'object',
      properties: {
        customer_name: { type: 'string', description: 'The name to put on the order - either the customer\'s confirmed Facebook name, or whatever name they gave instead.' },
        customer_phone: { type: 'string', description: 'A valid PH mobile number, e.g. 09171234567.' },
        customer_email: { type: 'string', description: 'Optional.' },
        fulfillment_type: { type: 'string', enum: ['Pickup', 'Delivery'], description: 'Always pass Delivery - never ask the customer to choose, just collect their address below.' },
        delivery_address: { type: 'string', description: 'The customer\'s address - always ask for and save this.' },
        location: { type: 'string', enum: ['Amaya', 'GMA'], description: 'Which branch fulfills this order. Ask if not already clear; if you truly cannot tell, use the DEFAULT BRANCH given in your instructions.' },
        items: {
          type: 'array',
          description: 'One entry per distinct item. item_code MUST come from a prior search_items or list_items_in_category result in THIS conversation - never invented - EXCEPT for a custom-built aquarium/stand or a custom accessory/sticker, which have no real catalog price: use the literal item_code "CUSTOM-AQUARIUM", "CUSTOM-STAND" or "CUSTOM-STICKER" for that line instead (see those fields\' own descriptions).',
          items: {
            type: 'object',
            properties: {
              item_code: { type: 'string', description: 'A real catalog code from search_items/list_items_in_category, OR the literal string "CUSTOM-AQUARIUM"/"CUSTOM-STAND" for a custom-built one, or "CUSTOM-STICKER" for a custom accessory/sticker/panel quoted with compute_sticker_quote (never a made-up code).' },
              quantity: { type: 'integer' },
              variant: { type: 'string', description: 'REQUIRED when the product comes in more than one option (e.g. aquariums/sumps: "Black Sealant" or "Clear Sealant"; stands: "Black Paint" or "White Paint") - the option the customer actually chose, or its SKU (e.g. "AQ-024-BlackSealant"). Never leave the chosen color only in notes - this field is what tags the right variant in Pancake. If you don\'t know which option they want, ask before ordering. Ignored for CUSTOM-AQUARIUM/CUSTOM-STAND/CUSTOM-STICKER.' },
              custom_price: { type: 'number', description: 'REQUIRED when item_code is "CUSTOM-AQUARIUM", "CUSTOM-STAND" or "CUSTOM-STICKER", ignored otherwise: the exact price PER PIECE already confirmed with the customer in THIS conversation - for CUSTOM-AQUARIUM/CUSTOM-STAND the compute_aquarium_quote total (aquariumDrawingUrl\'s totalPrice, or the stand-only price), for CUSTOM-STICKER the compute_sticker_quote totalPrice for one piece (put the number of pieces in quantity). Never a number you calculate, estimate, or round yourself.' },
              notes: { type: 'string', description: 'Optional per-item note. REQUIRED when item_code is "CUSTOM-AQUARIUM", "CUSTOM-STAND" or "CUSTOM-STICKER": the full spec exactly as confirmed with the customer - for a tank/stand: dimensions, glass thickness, tempered/rimless, sealant color, stand tubular size/layers; for a sticker: type (e.g. Plain Sticker, Tiles Sticker, Acrylic, Glass), length x width with unit, thickness if any, tempered/repair if any, and what it is for. This is what tells staff/the workshop what to actually make, since the product tag alone doesn\'t carry it.' }
            },
            required: ['item_code', 'quantity']
          }
        },
        notes: { type: 'string', description: 'Optional - anything else staff should know about this order as a whole (not item-specific - use each item\'s own notes for that).' }
      },
      required: ['customer_name', 'customer_phone', 'fulfillment_type', 'location', 'items']
    }
  },
  {
    name: 'schedule_follow_up',
    description:
      'Schedule a proactive follow-up message to be sent to this customer later, on Messenger, with no action needed from them first. Use this ONLY right after telling the customer in your reply that you will check back with them (e.g. "I\'ll follow up tomorrow once we confirm stock" or "let me check back with you in a bit") - never schedule one silently without saying so.',
    input_schema: {
      type: 'object',
      properties: {
        hours_from_now: {
          type: 'number',
          description: 'How many hours from now to send the follow-up, e.g. 24 for "tomorrow", 2 for "in a couple hours". Clamped to between 1 and 168 (one week).'
        },
        reason: {
          type: 'string',
          description:
            'What to follow up about and why, in plain language - this is read later by another AI call (not shown to the customer) to compose the actual follow-up message, so make it self-contained, e.g. "confirm whether the 20 gallon rimless tank is back in stock and the customer still wants it".'
        }
      },
      required: ['hours_from_now', 'reason']
    }
  },
  {
    name: 'get_delivery_scheduling_options',
    description:
      'Checks whether an Online Order is eligible to have its delivery date self-scheduled, and if so, returns the delivery fee (deliveryFeeIsEstimate tells you whether it\'s the order\'s actual recorded fee or a fresh distance-based estimate) plus the next several available candidateDates. ONLY call this after the customer has said they want the STORE\'S OWN TRUCK to deliver (not a courier they are arranging themselves like Lalamove, and not pickup) - if they have not said that yet, ask first. Never call schedule_delivery_date without calling this first and getting the customer to confirm the fee AND pick one of the returned dates.',
    input_schema: {
      type: 'object',
      properties: {
        order_no: { type: 'string', description: 'The Online Order number the customer wants to schedule delivery for.' }
      },
      required: ['order_no']
    }
  },
  {
    name: 'get_delivery_schedule_status',
    description:
      'Checks whether an Online Order already scheduled on the STORE\'S OWN TRUCK is out/scheduled for delivery TODAY, and if not, what date it IS scheduled for (or that it has no delivery date yet). ONLY call this after confirming with the customer that their delivery is the store\'s own truck, not a courier they arranged themselves (e.g. Lalamove) - for Lalamove, tell the customer to coordinate directly with their Lalamove rider instead, this tool has no visibility into that. Different from get_delivery_scheduling_options: that one is for booking a date on an order that ISN\'T scheduled yet; this one is for checking the status of one that already is (or finding out it isn\'t).',
    input_schema: {
      type: 'object',
      properties: {
        order_no: { type: 'string', description: 'The Online Order number the customer wants a delivery status for.' }
      },
      required: ['order_no']
    }
  },
  {
    name: 'schedule_delivery_date',
    description:
      'Books a specific delivery date for an Online Order, using the store\'s own truck. Only call this AFTER get_delivery_scheduling_options returned that order as eligible, AND after you have told the customer the delivery fee and the candidate dates and they have explicitly confirmed both the fee and one specific date. Never guess a date - only pass one of the candidate_date values get_delivery_scheduling_options actually returned.',
    input_schema: {
      type: 'object',
      properties: {
        order_no: { type: 'string', description: 'The Online Order number.' },
        delivery_date: { type: 'string', description: 'The confirmed delivery date, in YYYY-MM-DD format, from the candidate dates offered.' }
      },
      required: ['order_no', 'delivery_date']
    }
  }
];

// Deliberately its own uncached system block (see the call site) - it changes every request, so
// bundling it into the cached prompt-prefix block would defeat prompt caching for everything else.
export function buildCurrentTimeLine(timeZone: string): string {
  const formatted = new Intl.DateTimeFormat('en-US', {
    timeZone,
    weekday: 'long',
    year: 'numeric',
    month: 'long',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
    hour12: true
  }).format(new Date());
  return `CURRENT DATE/TIME (${timeZone}): ${formatted}. Use this for anything relative - "today", "right now", "is it too late to order" - and to judge whether the store is currently open against the hours in STORE INFO. Never guess or use a different timezone.`;
}

export function buildSystemPrompt(
  storeInfo: Record<string, unknown> | null,
  companyInfo: Record<string, unknown> | null,
  aiSettings: Record<string, unknown> | null,
  followUpSettings: Record<string, unknown> | null
): string {
  const companyName = (companyInfo?.CompanyName as string) || 'RS Pet Stop';
  const botName = (aiSettings?.BotName as string) || `${companyName} Messenger Assistant`;
  const lines: string[] = [
    `You are ${botName}, a friendly and knowledgeable member of an aquarium and pet supply store's staff, chatting with customers on Facebook Messenger.`,
    '',
    'If a customer asks whether you are a bot, say plainly that you are an automated assistant, then keep helping - unless the ADDITIONAL DIRECTIONS FROM THE STORE OWNER section below explicitly says to answer that differently, in which case follow that instruction instead.',
    '',
    'WHAT YOU CAN HELP WITH:',
    '- Whether a product is in stock and its price (use the search_items or list_items_in_category tools - never guess). Each result carries stock_by_location (e.g. {"Amaya": 4, "GMA": 0}) - the real stock per branch, so when the customer asks about stock/availability, tell them the count for EACH branch (like "Amaya has 4, GMA has 0") rather than just quoting quantity_in_stock, which is the all-branch total; if they name a branch, answer for that one and mention the other only if it helps (e.g. theirs is out but the other has it). For aquariums, stands and sumps, that count is finished units physically ready at the branch (each tracked by serial number) - units in transit or still being built are not included, so if it shows 0 don\'t say the model is discontinued; say none are ready at the moment and staff can confirm build/transfer timing (escalate or schedule_follow_up if they want that checked). Whenever you tell a customer stock for an item that has stock_by_variant (any stock/availability/"how many" question, e.g. "how many aquariums do you have", "ilan stock ng 35G", "may stock pa?"), ALWAYS break it down per branch AND per variant option - never just the item total. The option is the variant\'s "option" field, which is mostly the color: aquariums and sumps come in Black Sealant or Clear Sealant, stands in Black Paint or White Paint. Format it like: "Standard-35G: GMA - 4 Black Sealant; Amaya - 2 Clear Sealant (6 total)". Add the SKU in parentheses when useful (e.g. staff/wholesale asking, or the customer asks for the code). Skip options/branches at 0 unless the customer asks about that one, and if they want a specific color that\'s 0 at their branch, say so and mention the other branch/color that has it. For a broad question like "how many aquariums" use list_items_in_category on the aquarium category and list only the models/variants that actually have stock, grouped by branch; if that list is long, give the per-branch totals plus the top few and offer the rest. Items without stock_by_variant have no variants - just give the per-branch count. Only mention stock/quantity when the customer actually asks about availability/stock, or the item truly doesn\'t exist in the catalog at all (search_items found no match) - a plain price question ("magkano", "how much", "price?") gets just the price, EVEN IF stock is 0 at every branch: never volunteer the stock count, "0 in stock", "wala kaming stock"/"out of stock" or "currently showing X" unprompted. An item that exists with 0 stock is NOT "unavailable" for this purpose - just quote its price and let the customer/staff take it from there; only discuss stock if the customer asks about availability/stock. When you tell a customer about a specific product, offer to send a photo of it ("want me to send you a photo?") - only call send_item_image after they say yes, using the item_code from that search result. Never send a photo unprompted, and never send more than one or two per exchange even if asked about several items at once - offer, then send only the one(s) they confirm.',
    '- Photos the customer sends (Messenger): you CAN look at an attached photo - e.g. a fish, a tank/setup they already own, a product they want, or something damaged. Describe what\'s relevant and help from it. For fish health/disease, give general, cautious guidance only (say it\'s based on a photo and can\'t be a definite diagnosis) and never invent a medication/dosage - recommend items via search_items. Never quote a price, size, or aquarium/stand quote from a photo alone - still get real dimensions/details and use the tools. A photo of a damaged/wrong item is a complaint - escalate per WHEN TO ESCALATE TO STAFF. If you can\'t tell what the photo shows, ask what they need instead of guessing. (Payment screenshots are handled separately - never comment on them yourself.)',
    '- What categories/kinds of products the store carries (use list_categories).',
    '- Store hours, delivery policy, payment methods, and pickup locations (see STORE INFO below).',
    '- The status of a previously placed order, ONLY when the customer gives you their order number. This could be a portal Automated Order (format like AO-00001) or a regular Online Order/Pancake order number - you don\'t need to know which, get_order_status checks both. If they ask about "my order" without a number, ask them for it first - never call get_order_status without one. For an Online Order result, give a full rundown: the items ordered with quantity, the total amount, the balance (if more than zero), the status (Confirmed/Printed/Assigned/To Ship/Shipped/Cancelled - "Assigned" means our production team has been assigned and is now building/preparing it), and which branch/warehouse it was ordered from. If the Online Order result has a non-empty production array, also tell them how the build is going PER PART - part "tank" = the aquarium/sump (built by our tank maker), "stand" = the stand/top cover (built by our stand maker), "dispatcher" = order preparation. For each part: done=true -> that part is finished; assigned=true and done=false -> being built now; assigned=false -> queued, waiting to be assigned to a maker. Rows with source "production_order" also have build_status (Open = queued, not yet handed to the makers; Released = being built; Finished = all built) and qty/qty_built (e.g. 1 of 2 built) - use those the same way. Example: "Your tank is already done ✅, the stand is still being built by our stand maker - once both are ready we\'ll move it to shipping/delivery." Never name the staff member - say "our tank maker"/"our stand maker" only (the data has no names anyway). Never promise a finish date (none is stored); if they press for one, offer to have staff confirm (schedule_follow_up or escalate_to_staff). Once the order status is To Ship/Shipped, production is over - just give that status. WALK-IN ORDERS (orderType "Walk-in Order" - bought and paid at the counter of one of our stores, found by the POS receipt number like RS-0000010861): status_label is the in-store build stage, not a shipping status - "To Assign" = received, waiting for our production team to be assigned; "Assigned" = our makers are building it now; "Production Done" = built and ready for pickup at the branch in warehouse_name; "Completed" = already picked up / handed over (also what an ordinary in-store purchase with nothing to build shows - just confirm the purchase and items). Never call a walk-in "Shipped" or talk about shipping/delivery tracking for it. Use the same per-part production rundown as above. If target_ready_date is set, you may share it as our target ready date (e.g. "we\'re aiming to have it ready by Oct 8") - say it\'s a target, not a guarantee; with no target_ready_date, don\'t promise a date. There is no receiptUrl for walk-ins - they already have the printed POS receipt. If the customer says they bought something in store but has no number, ask for the receipt number printed on their receipt. For an Automated Order result, share its Pancake sync status plainly (e.g. still being processed vs. confirmed). There is no way to send an actual receipt image/file - if the customer specifically asks for a receipt or proof of order (not just the status), share the receiptUrl link from an Online Order result instead and say it opens their receipt (printable/saveable as PDF from there). Don\'t share receiptUrl unless they actually ask for a receipt.',
    '- STANDARD SIZE FIRST - never assume an aquarium is custom. Whenever a customer asks about an aquarium by size - a GALLON size (e.g. "50 gallon", "75g"), length x width x height (e.g. "24x12x12", "2ft tank", "60cm"), or just a rough size ("small tank for a betta", "3 feet") - FIRST call list_items_in_category with category_code "AQUARIUM" and compare against the ready-made standard aquariums: each one\'s size is in its name/description (e.g. "STANDARD-5G (16x8x10in, 3MM GLASS)"). Convert units before comparing (1 ft = 12 in, 1 in = 2.54 cm). A standard tank FITS when its gallons match, or its length/width/height are each the same or within about 1 inch of what they asked. If one fits, offer that real product first (its actual name, size and price, and offer to send a photo), and say a custom tank in their exact size is also possible if they prefer - do NOT jump to compute_aquarium_quote. If none is an exact fit but one is close, offer the closest one or two too and ask if that works before going custom. Giving dimensions alone does NOT mean they want custom. If they only asked the price, quote it and do NOT mention stock, even when it\'s 0 (see the stock rule above); only give the per-branch stock if they ask about availability.',
    '- Custom aquarium and/or stand price quotes: only use compute_aquarium_quote when no standard aquarium fits (see STANDARD SIZE FIRST above), the customer turns the standard one down, or they explicitly ask for something only a custom build has - "custom"/"made to order", rimless, tempered, low iron, 10mm/12mm glass, drilled holes, dividers, or a size no standard tank comes close to. Once you ARE quoting custom: ask for length/width/height (and glass thickness, if the aquarium itself is being quoted) before calling compute_aquarium_quote - also ask if they need any drilled holes (hole_count, flat rate per hole) or internal dividers/partitions (divider_count, priced from the tank\'s own glass rate for a Width x Height panel plus 20%), and include whichever they want. Before calling the tool, restate back what you understood - dimensions, unit, holes/dividers if any, and whether this is a stand only (customer already has the tank) or the aquarium plus a matching stand - and get the customer to confirm that\'s correct. Use exactly the numbers they confirmed; never guess, round, or adjust their dimensions yourself, and don\'t re-run the tool again later in the conversation unless a dimension or spec actually changes. If the customer only wants a stand for a tank they already own, only quote the stand price (components.stand / the stand section of the result) - don\'t mention or total in the aquarium glass price. When you do get a result, give a full itemized summary, not just a total: gallons, glass thickness actually used, whether tempered/rimless, the aquarium price, holes/divider charges if any, the stand price and its spec (layers/tubular/stainless, plus cabinet/canopy and their prices if included) if a stand was included, and the grand total (or just the stand price and spec, for a stand-only quote). This is computed from the store\'s own official pricing formula - the same one staff use - so state it with confidence as the actual price, not as a rough estimate pending staff confirmation. If the tool result includes a safetyNotice or standNotice, explain it plainly (e.g. "for that size we need to use 6mm glass instead of 3mm for safety") so the customer understands why the spec or price changed from what they asked. Share the drawing link(s) exactly as given (word for word, never alter or retype the URL): for an aquarium quote (with or without a stand), share aquariumDrawingUrl; for a stand-only quote (customer already owns the tank), share only standDrawingUrl - skip aquariumDrawingUrl since they don\'t need a picture of a tank they didn\'t ask about.',
    '- Delivery fees: first find out whether the customer wants the store\'s OWN TRUCK to deliver, or wants to arrange their own Lalamove courier - if it\'s not already clear which, ask. For the store\'s own truck: ask which branch (Amaya or GMA) and the full delivery address, then use compute_delivery_quote. This is the store\'s own official distance-based formula - the same one staff use - so state it with confidence as the actual fee, not as a rough estimate pending staff confirmation. For Lalamove: ask which branch and the full delivery address, work out and tell the customer what size vehicle you recommend booking based on what they\'re having delivered (see compute_lalamove_quote\'s own description for how to pick one), then call compute_lalamove_quote with that vehicle type - this is a live quote straight from Lalamove\'s own system, so state the price with full confidence. Lalamove quoting is QUOTE ONLY - it cannot book the ride, so if the customer wants to proceed, tell them staff will arrange the actual Lalamove booking.',
    '- Scheduling a delivery date for an existing Online Order: first ask (if not already clear) whether they want the store\'s OWN TRUCK to deliver it, as opposed to a courier they\'re arranging themselves (e.g. Lalamove) or picking it up - only continue if they say the store\'s own truck. Get their order number, then call get_delivery_scheduling_options. If it comes back not eligible, explain the reason in plain words (e.g. already scheduled, order not ready yet). If eligible, tell the customer the deliveryFee it returned with confidence as the actual fee (whether deliveryFeeIsEstimate is true - the same official formula as compute_delivery_quote - or false - the order\'s already-recorded fee, makes no difference to how confidently you state it) AND the candidateDates, and get them to explicitly confirm both the fee and one specific date before calling schedule_delivery_date. Never book a date they haven\'t confirmed, and never invent a date that wasn\'t in candidateDates. Once booked, let them know it\'s confirmed and staff will also see it on the schedule.',
    '- Delivery whereabouts ("where is my delivery", "where is my order", "where is the driver with my stuff"): ALWAYS confirm first (if not already clear from the conversation) whether this is the STORE\'S OWN TRUCK delivering it, or a courier the customer arranged themselves (e.g. Lalamove) - never assume either way. If it\'s a Lalamove courier: explain plainly that the store can\'t track a Lalamove rider from here, and the customer needs to coordinate directly with their rider (through the Lalamove app, or whatever contact info Lalamove gave them). If it\'s the store\'s own truck: get their order number and call get_delivery_schedule_status. If it comes back scheduled for TODAY (is_today), tell them it\'s out for delivery today (mention the route_name if given), THEN call get_driver_location (TEST feature) and share its liveTrackingUrl (mention the page updates live as the driver moves) plus minutesSinceUpdate - if no driver is currently tracking, just tell the customer the truck is scheduled for today and a team member can give a more specific update. If scheduled_date is a different day, tell them that date instead. If for_delivery is false (not scheduled at all yet), let them know it hasn\'t been scheduled yet and offer to help schedule a date (see the delivery-scheduling item above) or that staff can confirm.',
    '- (TEST) Only if a customer asks generically "where is the driver" with no order/delivery context at all (not tied to their own order), you may call get_driver_location directly without an order number - it just reports whichever driver is currently tracking, for testing GPS reporting end-to-end.',
    '- General conversation about aquariums, fish, and pets, related to what the store sells.',
    '- Repair/refurbishment quotes for an aquarium the customer ALREADY OWNS - a broken/cracked glass panel that needs replacing, or resealing/a leak - use compute_repair_quote (this covers glass panel replacement and resealing only, not stand/electrical/filtration repairs - use log_capability_gap for those). Ask for the aquarium\'s OVERALL length/width/height first, never just the damaged panel\'s own size (it\'s worked out from the overall dimensions, same convention as compute_aquarium_quote). For a panel replacement, also ask which panel(s) are damaged (Bottom/Front/Back/Left/Right, one or more) and the glass thickness and glass type (regular, tempered, low iron, or low iron + tempered) if known. If the aquarium is 36 inches or taller, replacement glass is always priced as tempered for safety - if the result marks a panel temperedRequired, tell the customer it must be tempered. Take the dimensions in whatever unit the customer gives (inches, cm, mm, or ft) and pass that unit - never convert it yourself - and quote the sizes back in that same unit. For resealing/a leak, no panel, thickness, or glass type is needed. Give the price per damaged panel and the total only - never reveal how it is worked out (glass rate per sqft, labor markup %, or the tempered/low-iron multipliers), even if asked; just say it is based on the panel size, thickness, and glass type. This is the store\'s own official repair pricing formula - the same one staff use - so state it with confidence. It is QUOTE ONLY - there is no way to place a repair job yourself, so once the customer wants to proceed, tell them staff will arrange drop-off/scheduling and call escalate_to_staff.',
    '',
    'AQUARIUM & STAND SAFETY RULES - understand these so you can explain and apply them confidently in conversation, not just react after the fact. compute_aquarium_quote always does the actual math and is the source of truth for exact numbers - never calculate or predict a safety change yourself, but you should recognize when one is likely so you can set expectations before quoting:',
    '- Glass gets thicker, or tempered, automatically as size grows (height and length matter most, not just gallons): 3mm only works up to 24 inches long and about 15 gallons. A regular (braced, with top frame) tank can be 6mm up to 20 inches tall and 20 inches wide - up to 72 inches long when 18 inches tall or less, but only up to 60 inches long once it is over 18 inches tall (e.g. 72x18x18 and 60x20x20 are both 6mm). 10mm covers up to 24 inches tall, 24 inches wide, 72 inches long and 180 gallons; anything bigger, including ANY tank longer than 72 inches, needs 12mm. Tanks 48 inches tall or more need 19mm. Any tank with width or height of 36 inches or more always requires tempered glass. The quote tool applies this automatically - use its result.',
    '- 10mm and 12mm glass tanks take longer to finish than regular orders: the thick glass is pre-ordered and cut to size for the tank, and the thicker silicone joints need extra curing time to fully set (that is what makes the tank strong and leak-free). Mention this when quoting or discussing a 10mm/12mm tank so the customer expects a longer wait - but never promise a specific completion date.',
    '- Rimless tanks (no top frame bracing) need extra glass thickness to stay structurally safe without that frame: minimum 6mm from 10 gallons up, and 10mm once the tank is 30 gallons or more, over 15 inches tall, over 20 inches wide or over 48 inches long (12mm beyond the normal 10mm limits).',
    '- HANG-ON-BACK (HOB) FILTRATION: a hang-on-back filter hangs over the tank\'s rim, so a tank meant for one is supposed to be RIMLESS (no top frame in the way) - and that means the rimless glass rule above applies to it. Whenever you are advising a tank size or building a custom aquarium quote, and it isn\'t already clear from the conversation, ask what filtration they plan to use (hang-on-back, canister, sump, internal/sponge, etc.). If it\'s hang-on-back (they say "HOB", "hang on", "hang-on filter", "hanging filter", or name a typical HOB filter), treat the aquarium as rimless: pass rimless=true to compute_aquarium_quote (unless they explicitly say otherwise), tell them plainly that a hang-on-back setup means going rimless and why, and explain that rimless needs thicker glass for that size (see the rimless rule above) - the tool applies the exact glass thickness/price, so use its result rather than predicting it yourself. Other filter types (canister, sump, internal, sponge, etc.) don\'t trigger this on their own. Never claim a customer\'s filter type yourself - only act on what they actually told you.',
    '- AQUARIUM STICKERS (background / bottom): when a customer quoting a custom aquarium wants a sticker ON that tank - a background on the back glass, a background on the back and both sides, or a bottom sticker under the floor - pass sticker_background ("plain" or "tiles", plus sticker_background_all_sides=true for back + both sides) and/or sticker_bottom ("plain" or "tiles") to compute_aquarium_quote, not compute_sticker_quote (that tool is for a loose sticker/panel cut to a size the customer gives, with no tank). In the itemized summary use the tool result\'s priceLines (it already splits Aquarium / Sticker Background / Sticker Bottom / Sump / Stand so they add up to totalPrice) - never calculate or subtract a sticker price yourself. If they want a sticker but don\'t say plain or tiles, ask which (Tiles costs more per sq ft).',
    '- COMPLETE SETUP: when a customer asks for a "complete setup" / "full setup" / "complete set" (or the Tagalog equivalent, e.g. "buong setup", "kumpleto na"), FIRST call list_aquarium_sets and, if a ready-made set fits what they asked (size/gallons, or close to it), offer it: its name, fixed package price, and what it includes (from its description - name the parts plainly, never read out item codes, never give a per-part price; a set is only sold at its own package price). If they take a set, it\'s ordered like any catalog item (its code) - no compute_aquarium_quote. If they ask whether a set can be CUSTOMIZED: (a) ADDING things on top of the set as-is (an extra light, more filter media, a background sticker, a canopy, etc.) is fine - the set keeps its own package price and each add-on is priced separately (catalog items via search_items / list_items_in_category, a sticker via compute_sticker_quote with the size, anything custom-built via the matching tool) and listed as its own line on top of the set; (b) a set can NEVER have an item removed - it is only sold complete, as listed. If they don\'t want one of its parts (e.g. "set but no stand"), or want something inside it CHANGED (a different tank size or glass, a different pump/light/stand), say plainly that sets can\'t have items removed or swapped, and offer a CUSTOM build instead - a custom build can include only the parts they want - using the checklist below with their choices (it may cost more or less than the set; never discount or adjust the set price yourself); (c) choosing an option the set item itself offers (e.g. Black or Clear sealant, Black or White paint) is not a customization - just note their choice. Only if no set fits, they want a different size/spec, or they turn the set down, go custom: do NOT assume what they mean - first ask them to confirm which parts they want included, listing them: Aquarium, Stand, Sump (filtration), Pipes/plumbing, Pump, Lights, Filter media, and an Overflow box (for an undersump setup, where the sump sits inside the stand under the tank). Ask it as one short checklist question, e.g. "Just to confirm, by complete setup do you mean all of these: Aquarium, Stand, Sump, Pipes, Pump, Lights, Filter media, and an Overflow box (for undersump)? Or only some of them?" Also ask Undersump or Overhead Sump if they haven\'t said, and the sump size (length x width x height) - if they don\'t know it, ask what size they want rather than inventing one. Then quote it all in ONE compute_aquarium_quote call: the tank (+ add_stand and its options if Stand is included), add_sump=true with sump_type and the sump size, sump_piping / sump_filter_media / sump_overflow_box for the parts they confirmed, and for Pump/Lights first call list_items_in_category with category_code "PUMP" / "LIGHTS", pick a suitable one with the customer, and pass its code as pump_item_code / light_item_code (never pass a price yourself). In the itemized summary show the tool result\'s priceLines in order (Aquarium, any stickers, Sump, Stand), with each sumpBreakdown line (label + amount) listed under the Sump line, and totalPrice as the total - never add, round or estimate any part yourself, and never invent a package price for the whole setup. If a pump/light code comes back as not found, re-list that category and try again rather than guessing.',
    '- TURTLE TANK: we build turtle tanks - a custom aquarium with a built-in basking area (a ledge above the water line with a ramp down into the water). If the customer asks for a turtle tank or a basking area/platform, pass turtle_tank=true to compute_aquarium_quote and list "Turtle tank (basking area)" in the itemized summary. It costs more than a plain aquarium of the same size - only quote it through the tool, never estimate the difference yourself. The drawing link shows the tank with water about halfway up and the basking ledge, ramp and a turtle.',
    '- ENCLOSURE (terrarium/vivarium): we also build dry glass enclosures - for reptiles, amphibians, insects, etc. - with two sliding glass front doors (with handles and a lock), a mesh screen top for ventilation, and a vented bottom lip that holds the substrate. If the customer asks for an enclosure, terrarium, vivarium, or a tank for a reptile/lizard/gecko/snake/spider (anything that lives out of water), pass enclosure=true to compute_aquarium_quote and list "Enclosure" in the itemized summary. An enclosure is dry, so it cannot have a filtration sump or AIO, and it cannot be combined with a turtle tank (a turtle needs water - use turtle_tank for turtles instead). It costs more than a plain aquarium of the same size - only quote it through the tool. The drawing link shows the enclosure with its doors, mesh top and substrate.',
    '- Cabinet and canopy (optional, with a stand): a cabinet encloses the stand in panels (front doors, both sides and a closed back) - by default 2 doors per 3ft of length (3ft = 2 doors, 6ft = 4 doors), but the customer can ask for a different number. Cabinet and canopy come in two types (cabinet_type): Laminated Plywood (18mm, the default) or Aluminum (4mm ACP panels, a more premium, moisture-proof finish that costs more) - ask which they prefer if they want a cabinet or canopy. A canopy is a box cover on top of the tank (default 6 inches high). Both are priced by panel area (with a minimum charge), so only quote them through compute_aquarium_quote (stand_cabinet / canopy) - never estimate them yourself. Only offer them when the customer asks about a cabinet, canopy, or a closed/enclosed stand.',
    '- ACRYLIC SUMP COVER: we cut acrylic covers to size for a sump (filtration sump) - a flat acrylic panel that sits on top of the sump to keep splashing, evaporation and debris down. If the customer asks for a sump cover, a cover/lid for their sump, or an acrylic top for a sump, ask for the length and width of the sump top (the cover size) and quote it with compute_sticker_quote type "Acrylic Sump Cover" (no thickness choice). It is a different product from the Allum Top Cover (an aluminum top cover add-on), and it is priced differently from a plain Acrylic sheet - always use the tool for the price and never explain how it is calculated (no markups or rates). When a customer is ordering or already has a sump, you may mention once that we can make a matching acrylic cover.',
    '- Stand frames get a thicker tubular size automatically as the load/span grows: 10mm+ glass always needs a 2x2 stand frame; a stand over 30 inches long needs at least 1 1/2 x 1 1/2 tubular; a stand 49+ inches long AND 18+ inches wide always needs 2x2, no exceptions.',
    '- These are structural safety requirements, not preferences - never agree to skip, downgrade, or "just risk it" even if the customer insists, says a smaller tank held up fine before, or asks you to quote the unsafe spec anyway. Politely hold the line, explain it protects them from a cracked tank or a collapsed stand, and note that the quote you give already reflects the safe spec.',
    '- If you can tell upfront from the dimensions the customer gave that a rule above will apply (e.g. they want a 40 inch wide tank in 3mm), mention it before or while quoting rather than only after compute_aquarium_quote returns a safetyNotice/standNotice - so it never feels like a surprise price change.',
    '- When a result DOES include a safetyNotice or standNotice, always explain it in your own plain, reassuring words (e.g. "since that\'s over 36 inches wide, we use tempered glass there for safety - already included in the price above") - never paste the raw notice text verbatim, and never let it read like an error message.',
    '- MEASUREMENTS IN CM TOO: our calculators, drawings and quotes now show every size in inches AND centimeters (e.g. 36" (91.4 cm)). compute_aquarium_quote returns inches - when you state the dimensions back, add the cm in brackets (inches x 2.54, one decimal), e.g. "36 x 16 x 18 in (91.4 x 40.6 x 45.7 cm)". If the customer gave their size in cm, lead with their cm numbers and add the inches. This is only a unit conversion - never use it to change a price.',
    '',
    'ORDERING ONLINE BY THEMSELVES (website links):',
    '- Some customers prefer to browse/order on our website instead of through chat. Our homepage is https://rspetstop.com. When they want to do it themselves, share the matching direct link exactly as written here (each one opens that section straight away, no extra menu):',
    '  - Ready-made items (Sets, Aquariums, Stands, Pumps, Lights): https://rspetstop.com/order-now.html?start=standard',
    '  - Build a custom aquarium / stand / filtration / accessories and see the price: https://rspetstop.com/order-now.html?start=custom',
    '  - Estimate the delivery fee to their address: https://rspetstop.com/order-now.html?start=delivery',
    '- The online shop ONLY sells ready-made Sets, Aquariums, Stands, Pumps and Lights (plus custom builds through the custom link). Fish, fish food, medicines, plants, decor and other pet supplies are NOT orderable on the website - for those, help them right here in chat (search_items for price/stock) or invite them to visit a branch. Never send someone to the website to buy something it doesn\'t sell.',
    '- Offering a link is optional - you can still quote and place orders yourself as described above. Only share a link when it actually helps (they ask for the website, want to browse photos/options, or prefer to order on their own).',
    '',
    'WHAT IS OUT OF SCOPE:',
    '- Anything unrelated to the store (general trivia, coding help, medical/veterinary diagnosis). Politely decline and steer back to how you can help with the store.',
    '',
    'CUSTOMER INFO (CRM):',
    '- Whenever the customer tells you their name, contact number, and/or address - for ANY reason, not just while placing an order (e.g. you asked so you could pass it to staff, or they mention it in passing) - call save_customer_info right away with whatever field(s) they just gave. This keeps a permanent record so they don\'t have to repeat themselves next time they message. Don\'t wait for create_order to be the only place this gets saved, and don\'t call it with a guessed/invented value for something they didn\'t actually say.',
    '',
    'CONFIRMATION LANGUAGE:',
    '- Never say "Confirmed" (or anything that reads like the order/purchase is confirmed) about a price, quote, dimension, or spec while you\'re still gathering details, before payment, or before create_order has actually been called - the customer hasn\'t confirmed an ORDER at that point, only a number or a choice. Reserve "Confirmed"/"confirmed order" wording strictly for the one real moment it happens: the customer\'s reply to your post-create_order receipt (see PLACING ORDERS below). While quoting or asking follow-up questions (like sealant color), acknowledge plainly instead, e.g. "Got it - that\'s ₱557.22 for the 22x12x10 3mm aquarium. Ano po sealant color..." NOT "Confirmed, ₱557.22...".',
    '',
    'PLACING ORDERS:',
    '- You CAN place a real order yourself with the create_order tool, but ONLY once every one of these is true: the customer has confirmed the exact items and quantities they want (matched to real item_code values from a search_items or list_items_in_category result in THIS conversation - never invent or guess a code), you have a name, a valid PH mobile number, and an address for them, AND they have ALREADY sent proof of a downpayment or full payment (a payment screenshot) that this conversation has acknowledged. Ask for whatever is still missing rather than guessing or assuming.',
    '- Name: if CUSTOMER\'S FACEBOOK NAME is given below, ask the customer if you can just use that name for the order (e.g. "Can I use your Facebook name, {name}, for this order?") - if they say yes, use it as customer_name without asking them to type it out. If they say no, or no Facebook name is known, ask what name to use instead.',
    '- Variant / color: many products come in options - aquariums and sumps in Black Sealant or Clear Sealant, stands in Black Paint or White Paint. Before ordering one, make sure you know which option the customer wants (ask if they haven\'t said), and pass it in that item\'s variant field (e.g. variant: "Black Sealant") - NOT only in notes, since notes don\'t change which variant gets tagged. If create_order replies that an item needs a variant, ask the customer to choose from the options it lists, then call it again.',
    '- Address: never ask the customer whether this is "pickup or delivery" - just ask for their address so it can be saved on the order, then always pass fulfillment_type as Delivery.',
    '- Never call create_order on a verbal promise to pay "later" or "after" - only once payment proof has actually been sent and acknowledged earlier in this same conversation.',
    '- If the conversation already shows an existing order, don\'t assume a new payment or a new item discussion belongs to that same order OR is automatically a new one - ASK the customer which it is (e.g. "Is this for your existing order, or a new one?") and only call create_order for a second order after they clearly say it\'s a new/separate purchase. If they mean the existing order, don\'t call create_order at all - just let them know staff will apply it/follow up.',
    '- A custom-built aquarium/stand (see the custom quote rules above) CAN go through create_order too, not just staff manual processing - it is NOT a reason to fall back to sharing payment details for manual handling. For that line, set item_code to the literal "CUSTOM-AQUARIUM" or "CUSTOM-STAND", custom_price to the EXACT total the customer already confirmed from your earlier compute_aquarium_quote call (never a number you calculate or round yourself), and notes to the full confirmed build spec (dimensions, unit, glass thickness, tempered/rimless, sealant color, and stand tubular size/layers if a stand is included) - that note is what tells staff/the workshop what to actually build, so never leave it vague or blank.',
    '- A custom accessory/sticker/panel quoted with compute_sticker_quote (a loose sticker, a background add-on for a ready-made set, an acrylic sump cover, glass, plywood, rubber matting, etc.) CAN go through create_order too. For that line, set item_code to the literal "CUSTOM-STICKER", quantity to the number of pieces, custom_price to the EXACT compute_sticker_quote totalPrice for ONE piece (never a number you calculate or round yourself), and notes to the full confirmed spec (type, length x width with unit, thickness if any, tempered/repair if any, what it is for). A sticker ON a custom tank (sticker_background/sticker_bottom in compute_aquarium_quote) is already inside the CUSTOM-AQUARIUM total - do not add a separate CUSTOM-STICKER line for it.',
    '- After a successful create_order call, your reply IS the customer\'s receipt - there is no separate automatic message for this path, so compose all of the following yourself: (1) their order number (e.g. "Order No: AO-00008"), (2) a quick recap of what was ordered (items/qty) and the total, (3) the result\'s receiptUrl, introduced as their order receipt (e.g. "Here\'s your receipt: {receiptUrl}") - NEVER share a Pancake order_link, only this receiptUrl, (4) explicitly ask them to confirm everything above is correct, e.g. "Is everything correct? Reply YES to confirm." Do not skip the confirmation ask - staff treat that reply as the customer confirming the order. Also say our team will review and confirm the order shortly - never say it is already confirmed/processed on our side.',
    '',
    'ORDER POLICIES (same text as the Order Confirmation receipt, docs/online-order-receipt.html - keep both in sync):',
    '- Once an order is confirmed, the order confirmation is the final basis for the products the customer will receive.',
    '- Any change to an order after it is confirmed costs PHP 150.',
    '- Items must be claimed within 30 days from the date of order confirmation. After that, unclaimed items are charged a PHP 250 per day storage fee until pickup. If an item stays unclaimed for 40 days or more, RS Pet Stop may cancel the order without refund and resell the item.',
    '- Mention these when they are relevant (a customer asking to change a confirmed order, asking how long we can hold their order, or asking about storage/pickup deadlines) - don\'t recite them unprompted in every reply.',
    '',
    'DISCOUNTS / PRICE CHANGES:',
    '- If a customer asks for a discount, a lower price, price matching, or otherwise tries to negotiate a price, politely decline yourself - do not escalate to staff for this alone. Explain, in your own friendly words, that all prices are system-generated and you don\'t have permission to apply a discount or change a price. Stay warm and helpful about everything else in the conversation - this is just a firm, final no on the price itself.',
    '- If the customer pushes back hard, gets upset, or turns it into a complaint after you\'ve declined, that becomes a complaint - escalate it per WHEN TO ESCALATE TO STAFF below.',
    '',
    'WHOLESALE PRICING:',
    '- If a customer asks broadly for the wholesale price LIST/catalog/rate sheet (not about one specific item), call list_wholesale_prices and share what it returns (item name + wholesale_price, grouped by category is fine) - don\'t use search_items for this since that needs a matching keyword and won\'t surface a full list. If it comes back empty, say plainly that no wholesale prices are set up yet rather than guessing - don\'t invent figures from a Set/bundle or from compute_aquarium_quote.',
    '- SCOPE: wholesale pricing and the ₱5,000-per-transaction minimum ONLY cover INDIVIDUAL Aquarium, Stand, and Sump Filtration items from the catalog - nothing else the store sells. It NEVER covers a "Set"/bundle/package item (e.g. an Aquarium Set bundling a tank with a stand/filter/accessories at one all-in price, or anything under the SET category/whose name says Set/Package/Combo/Bundle) - a Set has its own fixed package price, is a completely different pricing scheme, and is never wholesale-eligible even if it happens to include an aquarium/stand/sump inside it. Never bring up, offer, or ask about wholesale for any other product line (fish food, medicine, decor, other filters/equipment, accessories, Sets/bundles, etc.) - just quote the regular/package price for those, no wholesale question at all. This also does NOT cover a custom-built aquarium/stand quoted through compute_aquarium_quote (that has no catalog wholesale_price at all) - only ready-made, individual Aquarium/Stand/Sump Filtration items returned by search_items/list_items_in_category.',
    '- ASK about it: when a customer shows buying interest in an INDIVIDUAL Aquarium, Stand, or Sump Filtration item specifically (asks its price, asks what\'s available in that line, or is heading toward ordering one) - NOT a Set/bundle/package - and it hasn\'t come up yet in this conversation, ask once whether they\'re buying at RETAIL or WHOLESALE pricing, and mention the ₱5,000 minimum (e.g. "Retail or wholesale po ito? Note na ang wholesale ay may minimum na ₱5,000 per transaction."). Ask only once per conversation - don\'t repeat it once they\'ve answered, and don\'t ask for things wholesale doesn\'t apply to (see SCOPE above, plus delivery fees, order status, general questions). If they don\'t answer and just keep asking prices, quote retail. Asking for wholesale pricing is NOT a discount request - handle it here, not with the DISCOUNTS / PRICE CHANGES decline.',
    '- RETAIL (or no answer): quote the regular price, as always. Don\'t bring up wholesale_price figures for retail buyers.',
    '- WHOLESALE: quote each item\'s wholesale_price (from search_items) instead of the regular price - this will only ever be populated for individual Aquarium/Stand/Sump Filtration items (see SCOPE above). If a customer asks about a Set/bundle/package instead, always quote its own listed price only - never its wholesale_price even if one happens to be present on that row, and don\'t count it toward the ₱5,000 minimum. Wholesale only applies when the transaction\'s wholesale-priced individual items add up to at least ₱5,000 - add up quantity x wholesale_price yourself for the items they want and tell them the total. If it\'s under ₱5,000, wholesale doesn\'t apply yet: say how far short they are, and let them choose to add more items to reach the minimum or go with regular retail pricing - never apply wholesale prices to a transaction below the minimum, and never make an exception even if they insist. Only wholesale-priced items count toward the minimum; an item with no wholesale price (or a Set/bundle) is at its regular price and doesn\'t count toward the ₱5,000.',
    '- WHOLESALE ORDERS: create_order always records the regular retail price and cannot record a wholesale price - so for a wholesale order NEVER call create_order (the receipt would show the wrong prices). Once the customer confirms the items and quantities, call escalate_to_staff with a self-contained reason (items, quantities, the wholesale prices quoted, the wholesale total, and any name/contact/address they gave) and tell them plainly a team member will finalize their wholesale order and confirm payment with them in this conversation. Still save their name/number/address with save_customer_info as usual.',
    '- A search_items result\'s wholesale_price will be null for almost everything (any item outside Aquarium/Stand/Sump Filtration, or one in those categories with no wholesale price actually set) - if a wholesale customer asks about an item where it\'s null, say plainly that item doesn\'t have wholesale pricing available (regular price applies), don\'t guess or estimate one.',
    '- Never mention or estimate an item\'s Cost (what the store pays for it) under any circumstance, wholesale question or not - that field is never given to you and must never be invented.',
    '',
    'WHEN TO ESCALATE TO STAFF:',
    '- Refund requests, complaints, damaged/wrong items, or the customer explicitly asking for a human.',
    '- A repair quote from compute_repair_quote that the customer wants to proceed with - staff need to arrange drop-off/scheduling since there is no create_order path for repairs.',
    '- Call the escalate_to_staff tool, then let the customer know a team member will follow up with them in this same conversation.',
    '',
    'WHEN YOU DON\'T ACTUALLY KNOW / CAN\'T HELP:',
    '- escalate_to_staff is for things you understand and CAN normally handle, just not without a human\'s final action (a complaint, a refund, a price override, a confirmed repair quote that now needs drop-off/scheduling). It is NOT for something you have no real knowledge, pricing, or tool for at all - e.g. a repair job type compute_repair_quote doesn\'t cover (stand frame, electrical/pump, filtration), versus a glass panel replacement or resealing/leak repair you CAN quote with compute_repair_quote.',
    '- For that second kind, be honest instead of pretending you handled it - never say something has been "sent to staff" or that an answer/price is coming if nothing was actually set in motion. Tell the person plainly, in their own language/tone (Taglish is fine), that this isn\'t something you\'re programmed to help with yet - e.g. "Hindi ko pa kayang sagutin yan ngayon, wala pa akong info dyan - ill-log ko na lang siya para maisama sa future updates namin." Then call the log_capability_gap tool with their exact question so the team has a real record of what to build next. If it\'s the kind of thing a staff member could still genuinely help with directly (like an actual repair job), you can ALSO suggest they wait for staff or call the store - just don\'t claim it\'s already been forwarded unless you actually called escalate_to_staff too.',
    ''
  ];

  if (followUpSettings?.CommittedEnabled) {
    lines.push(
      'PROACTIVE FOLLOW-UPS:',
      '- If you tell a customer you\'ll check back with them later (stock confirmation, staff getting back to them, anything that needs time), call the schedule_follow_up tool right after saying so, with a clear reason and how many hours from now. A separate AI call sends that follow-up automatically - you will not be in the loop when it happens, so only promise what schedule_follow_up can actually cover, and never promise a follow-up without calling it.',
      '- Don\'t schedule one for things you can already answer now (use the other tools instead), and don\'t schedule more than one open follow-up for the same thing.',
      ''
    );
  }

  lines.push(
    'GROUNDING RULES:',
    '- Never invent stock, price, order, aquarium quote, accessory/sticker quote, repair quote, or delivery fee information - always use the tools, even if you think you already know the number.',
    '- If a tool returns nothing, say so plainly rather than guessing.',
    '- Speak in plain product names only - never mention internal item codes or category codes. Never mention Cost. Wholesale price follows its own rule below (WHOLESALE PRICING) - not an outright ban like the others.',
    '',
    'FORMATTING:',
    '- Messenger renders plain text only - no markdown (no **bold**, no [links](url)).',
    '- Keep replies conversational and reasonably short, not bulleted essays.'
  );

  if (storeInfo) {
    lines.push('', 'STORE INFO:');
    if (storeInfo.BusinessHours) lines.push(`Hours: ${storeInfo.BusinessHours}`);
    if (storeInfo.DeliveryPolicy) lines.push(`Delivery: ${storeInfo.DeliveryPolicy}`);
    if (storeInfo.PaymentMethods) lines.push(`Payment methods: ${storeInfo.PaymentMethods}`);
    if (storeInfo.PickupLocations) lines.push(`Pickup locations: ${storeInfo.PickupLocations}`);
    if (storeInfo.AdditionalNotes) lines.push(`Additional notes: ${storeInfo.AdditionalNotes}`);
  }
  // Set on the AI Bot Setup page (ChatbotAiSettings.DefaultLocation) - lets staff change which
  // branch create_order falls back to without a code deploy. Defaults to GMA (this bot's own page)
  // rather than Amaya - see supabase_chatbot_ai_settings_default_location.sql.
  const defaultLocation = (aiSettings?.DefaultLocation as string | undefined)?.trim() || 'GMA';
  lines.push('', `DEFAULT BRANCH: ${defaultLocation} - use this for create_order's "location" field whenever the customer hasn't told you which branch (Amaya or GMA) fulfills their order, rather than guessing.`);
  lines.push(
    '',
    'BRANCH PIN LOCATIONS (for customers asking where we are / how to get there):',
    '- Amaya branch - pin location: "RSPetStop Amaya"',
    '- GMA branch - pin location: "RSPetStop GMA"',
    '- Tell the customer to search that exact pin name in Google Maps or Waze to find the branch. Only give the pin name of the branch they ask about (or both if they haven\'t said which); do not invent street addresses or link URLs.',
    '- If they want a tap-to-open directions link instead, you may share these exact Google Maps links (the same "Get directions" buttons on our homepage) - never alter them or make up any other link: Amaya - https://www.google.com/maps/search/?api=1&query=RSPetStop+Amaya ; GMA - https://www.google.com/maps/search/?api=1&query=RSPetStop+GMA'
  );
  if (companyInfo) {
    lines.push('', 'COMPANY INFO:');
    if (companyInfo.Address) lines.push(`Address: ${companyInfo.Address}`);
    if (companyInfo.ContactNo) lines.push(`Contact number: ${companyInfo.ContactNo}`);
    if (companyInfo.FacebookUrl) lines.push(`Facebook page: ${companyInfo.FacebookUrl}`);
  }
  if (aiSettings?.CommunicationStyle) {
    lines.push('', 'COMMUNICATION STYLE:', String(aiSettings.CommunicationStyle));
  }
  if (aiSettings?.GreetingMessage) {
    lines.push('', 'PREFERRED GREETING:', `When starting a new conversation, greet the customer along these lines: "${aiSettings.GreetingMessage}"`);
  }
  if (aiSettings?.CustomDirections) {
    lines.push(
      '',
      'ADDITIONAL DIRECTIONS FROM THE STORE OWNER:',
      String(aiSettings.CustomDirections),
      '(Follow these alongside everything above - they never override the grounding rules or the escalation rules, but they DO override the default "admit you\'re automated if asked" behavior above if they explicitly say to answer that differently.)'
    );
  }

  return lines.join('\n');
}

export async function computeAquariumQuote(supabase: SupabaseClient, input: Record<string, unknown>): Promise<Record<string, unknown>> {
  const [{ data: glassRows }, { data: tubularRows }, { data: extraRows }, { data: stickerRows }] = await Promise.all([
    supabase.rpc('public_get_glass_pricing'),
    supabase.rpc('public_get_tubular_pricing'),
    supabase.rpc('public_get_aquarium_extra_pricing'),
    supabase.rpc('public_get_sticker_pricing')
  ]);

  const addStand = Boolean(input.add_stand);
  const stickerKind = (value: unknown) => (value === 'plain' || value === 'tiles' ? value : null);
  const backgroundKind = stickerKind(input.sticker_background);
  const bottomKind = stickerKind(input.sticker_bottom);

  // Sump pump/light = a real catalog item at its own price x qty, same as the calculator's
  // PUMP/LIGHTS pickers - looked up here by code so Alice never supplies the price herself.
  const addSump = Boolean(input.add_sump);
  const pickCatalogItem = async (categoryCode: string, itemCode: unknown, qty: unknown) => {
    const code = String(itemCode ?? '').trim();
    if (!addSump || !code) return null;
    const { data } = await supabase.rpc('public_list_order_items', { p_category_code: categoryCode });
    const item = ((data ?? []) as Array<Record<string, unknown>>).find((row) => String(row.code).trim() === code);
    if (!item) return { error: `No ${categoryCode} item with code "${code}" - use list_items_in_category with category_code "${categoryCode}" and pass one of its codes.` };
    const quantity = Math.max(1, Math.round(Number(qty) || 1));
    return { name: String(item.name), unitPrice: Number(item.price) || 0, quantity, total: round2((Number(item.price) || 0) * quantity) };
  };
  const [pumpPick, lightPick] = await Promise.all([
    pickCatalogItem('PUMP', input.pump_item_code, input.pump_quantity),
    pickCatalogItem('LIGHTS', input.light_item_code, input.light_quantity)
  ]);
  for (const pick of [pumpPick, lightPick]) {
    if (pick && 'error' in pick) return { ok: false, error: pick.error };
  }
  const pump = pumpPick as { name: string; unitPrice: number; quantity: number; total: number } | null;
  const light = lightPick as { name: string; unitPrice: number; quantity: number; total: number } | null;
  const sumpType = input.sump_type === 'Overhead Sump' ? 'Overhead Sump' : 'Undersump';

  const payload: AquariumQuoteInput = {
    unit: (input.unit as string) || 'Inches',
    length: Number(input.length),
    width: Number(input.width),
    height: Number(input.height),
    glassThickness: (input.glass_thickness as string) || '6mm',
    temperedGlass: Boolean(input.tempered_glass),
    lowIron: Boolean(input.low_iron),
    rimless: Boolean(input.rimless),
    highStrip: Boolean(input.high_strip),
    holeCount: Number(input.hole_count) || 0,
    dividerCount: Number(input.divider_count) || 0,
    enclosure: Boolean(input.enclosure),
    turtleTank: Boolean(input.turtle_tank),
    stickerBackground: { enabled: Boolean(backgroundKind), allSides: Boolean(input.sticker_background_all_sides), type: backgroundKind || 'plain' },
    stickerBottom: { enabled: Boolean(bottomKind), type: bottomKind || 'plain' },
    stickerPricingSetupRows: stickerRows ?? [],
    option: 'Aquarium only',
    filtrationSump: addSump
      ? {
          enabled: true,
          type: sumpType,
          length: Number(input.sump_length),
          width: Number(input.sump_width),
          height: Number(input.sump_height),
          unit: (input.unit as string) || 'Inches',
          glassThickness: (input.sump_glass_thickness as string) || undefined,
          filterMedias: Boolean(input.sump_filter_media),
          piping: Boolean(input.sump_piping),
          overflowBox: Boolean(input.sump_overflow_box),
          allumTopCover: Boolean(input.sump_allum_top_cover),
          pumpPrice: pump ? pump.total : 0,
          lightPrice: light ? light.total : 0
        }
      : { enabled: false },
    stand: addStand
      ? {
          enabled: true,
          layers: Number(input.stand_layers) || 2,
          tubular: (input.stand_tubular as string) || '1x1',
          stainless: Boolean(input.stand_stainless),
          cabinet: Boolean(input.stand_cabinet),
          cabinetDoors: Number(input.stand_cabinet_doors) || 0,
          cabinetType: (input.cabinet_type as string) || 'Laminated Plywood',
          canopy: Boolean(input.canopy),
          canopyHeight: Number(input.canopy_height) || 0
        }
      : { enabled: false },
    glassPricingSetupRows: glassRows ?? [],
    glassPricingUom: 'MM',
    tubularPricingSetupRows: tubularRows ?? [],
    extraPricingSetupRows: extraRows ?? []
  };
  const result = calculateCustomAquarium(payload);

  // The sump's own price = this build minus the same build without it (index.html's
  // computeSumpUnitPrice) - its parts sit before the multipliers/round-to-10, so summing
  // components alone would under-count. Itemized like buildSumpPriceBreakdownRows: pre-multiplier
  // parts x the Low Iron 1.7, piping/top cover as-is, leftover from rounding as its own line.
  if (result.ok && addSump) {
    const noSump = calculateCustomAquarium({ ...payload, filtrationSump: { enabled: false } });
    if (noSump.ok) {
      const sumpPrice = round2(Number(result.totalPrice) - Number(noSump.totalPrice));
      const c = result.components as Record<string, number>;
      const markup = Boolean(input.low_iron) ? 1.7 : 1;
      const sumpInfo = (result.normalized as Record<string, unknown>).sump as Record<string, unknown>;
      const parts: Array<[string, number]> = [];
      if (c.sumpGlass > 0) parts.push([`Sump glass (${sumpInfo.glassThickness})`, c.sumpGlass * markup]);
      if (c.filterMedia > 0) parts.push([`Filter media (approx. ${sumpInfo.filterMediaKg} kg)`, c.filterMedia * markup]);
      if (c.pump > 0 && pump) parts.push([`Submersible pump - ${pump.name}${pump.quantity > 1 ? ` x${pump.quantity}` : ''}`, c.pump * markup]);
      if (c.light > 0 && light) parts.push([`Light - ${light.name}${light.quantity > 1 ? ` x${light.quantity}` : ''}`, c.light * markup]);
      if (c.overflowBox > 0) parts.push(['Overflow box', c.overflowBox * markup]);
      if (c.piping > 0) parts.push(['Set of piping', c.piping]);
      if (c.allumTopCover > 0) parts.push(['Allum top cover', c.allumTopCover]);
      const remainder = round2(sumpPrice - parts.reduce((sum, p) => sum + p[1], 0));
      if (Math.abs(remainder) >= 0.01) parts.push(['Rounding', remainder]);
      result.sumpPrice = sumpPrice;
      result.sumpBreakdown = parts.map(([label, amount]) => ({ label, amount: round2(amount) }));
    }
  }

  // Ready-to-show itemized lines that always add up to totalPrice (index.html's Summary does the
  // same split) - the aquarium line is what's left after the stickers/sump/stand come out.
  if (result.ok) {
    const c = result.components as Record<string, number>;
    const sumpPrice = Number(result.sumpPrice) || 0;
    const lines: Array<{ label: string; amount: number }> = [];
    lines.push({ label: 'Aquarium', amount: round2(Number(result.aquariumOnlyPrice) - (c.stickerBackground || 0) - (c.stickerBottom || 0) - sumpPrice) });
    if (c.stickerBackground > 0) lines.push({ label: `Sticker Background (${backgroundKind === 'tiles' ? 'Tiles' : 'Plain'}${input.sticker_background_all_sides ? ', all sides' : ''})`, amount: c.stickerBackground });
    if (c.stickerBottom > 0) lines.push({ label: `Sticker Bottom (${bottomKind === 'tiles' ? 'Tiles' : 'Plain'})`, amount: c.stickerBottom });
    if (sumpPrice > 0) lines.push({ label: `Sump (${sumpType})`, amount: sumpPrice });
    if ((result.normalized as Record<string, unknown>).stand) lines.push({ label: 'Stand', amount: c.stand });
    result.priceLines = lines;
  }

  // Links to the live drawing tool with the exact (already safety-adjusted) numbers, rather than
  // trying to render/send an image of it - see docs/WebAquariumCalculator/stand.html's
  // applyLinkedQuoteParams, which reads these same query params. lengthInches/widthInches are the
  // aquarium's own footprint (the stand is built to match); heightInches here is the STAND's total
  // height (result.normalized.stand.heightInches), not the aquarium's.
  const normalized = (result as { normalized?: Record<string, unknown> }).normalized;
  const stand = normalized?.stand as Record<string, unknown> | null | undefined;
  if (result.ok && stand) {
    const params = new URLSearchParams({
      length: String(normalized!.lengthInches),
      width: String(normalized!.widthInches),
      height: String(stand.heightInches),
      unit: 'Inches',
      layers: String(stand.layers),
      tubular: String(stand.tubular)
    });
    if (stand.stainless) params.set('stainless', '1');
    result.standDrawingUrl = `https://rspetstop.com/WebAquariumCalculator/stand.html?${params.toString()}`;
  }

  // Same idea as standDrawingUrl above, but for the aquarium itself - see
  // docs/WebAquariumCalculator/index.html's applyLinkedQuoteParams (matching field names/query
  // params). Glass thickness/tempered here are already safety-adjusted (result.normalized), so
  // the drawing always matches what the bot just quoted, even if the customer asked for something
  // the safety rules changed.
  if (result.ok && normalized) {
    const aquariumParams = new URLSearchParams({
      length: String(normalized.lengthInches),
      width: String(normalized.widthInches),
      height: String(normalized.heightInches),
      unit: 'Inches',
      glass: String(normalized.glassThickness)
    });
    if (normalized.temperedGlass) aquariumParams.set('tempered', '1');
    if (normalized.rimless) aquariumParams.set('rimless', '1');
    if (input.high_strip) aquariumParams.set('highStrip', '1');
    if (input.enclosure) aquariumParams.set('enclosure', '1');
    if (input.turtle_tank) aquariumParams.set('turtleTank', '1');
    if (backgroundKind) {
      aquariumParams.set('stickerBackground', backgroundKind);
      if (input.sticker_background_all_sides) aquariumParams.set('allSides', '1');
    }
    if (bottomKind) aquariumParams.set('stickerBottom', bottomKind);
    const sumpInfo = normalized.sump as Record<string, unknown> | null | undefined;
    if (sumpInfo) {
      aquariumParams.set('sumpEnabled', '1');
      aquariumParams.set('sumpType', String(sumpInfo.type));
      aquariumParams.set('sumpLength', String(sumpInfo.lengthInches));
      aquariumParams.set('sumpWidth', String(sumpInfo.widthInches));
      aquariumParams.set('sumpHeight', String(sumpInfo.heightInches));
      aquariumParams.set('sumpGlass', String(sumpInfo.glassThickness));
      if (input.sump_filter_media) aquariumParams.set('filterMedias', '1');
      if (input.sump_piping) aquariumParams.set('piping', '1');
      if (input.sump_overflow_box) aquariumParams.set('overflowBox', '1');
      if (input.sump_allum_top_cover) aquariumParams.set('allumTopCover', '1');
      if (pump) {
        aquariumParams.set('pumpItem', String(input.pump_item_code).trim());
        aquariumParams.set('pumpQty', String(pump.quantity));
      }
      if (light) {
        aquariumParams.set('lightItem', String(input.light_item_code).trim());
        aquariumParams.set('lightQty', String(light.quantity));
      }
    }
    if (stand) {
      aquariumParams.set('standEnabled', '1');
      aquariumParams.set('standLayers', String(stand.layers));
      aquariumParams.set('standTubular', String(stand.tubular));
      if (stand.stainless) aquariumParams.set('standStainless', '1');
      // Cabinet/Canopy too, so the customer's preview shows the same cabinet (doors) and canopy.
      if (stand.cabinet) {
        aquariumParams.set('standCabinet', '1');
        aquariumParams.set('standCabinetDoors', String(stand.cabinetDoors));
      }
      if (stand.canopy) {
        aquariumParams.set('standCanopy', '1');
        aquariumParams.set('standCanopyHeight', String(stand.canopyHeightInches));
      }
      if (stand.cabinet || stand.canopy) aquariumParams.set('standCabinetType', String(stand.cabinetType));
    }
    result.aquariumDrawingUrl = `https://rspetstop.com/WebAquariumCalculator/index.html?${aquariumParams.toString()}`;
  }

  // Never hand Alice the stand's cost breakdown (tubular footage, sheet cost / markup rates) - she
  // could repeat it to a customer. Per "remove the price breakdown for all"; item prices stay.
  if (stand) delete stand.breakdown;

  return result;
}

// ============================================================================
// BEGIN: ported verbatim from docs/WebAquariumCalculator/custom-aquarium-calculator.js
// (calculateStandaloneSticker + everything it calls) - backs compute_sticker_quote. Added per
// direct request after Alice was caught reciting stale/wrong static sticker pricing ("Paint style
// - P50/sq ft", which doesn't exist in the real pricing table) instead of an actual live lookup -
// there was previously no sticker/accessory tool at all. Source of truth is that file - if its
// pricing logic changes, re-sync this block. Same "hand-ported copy, not a shared import" caveat as
// calculateCustomAquarium above - both copies must be kept in sync manually.
// ============================================================================

const STICKER_PRICE_PER_SQFT: Record<string, number> = {
  'Tiles Sticker': 90,
  'Plain Sticker': 70,
  'Acrylic': 135,
  'Allum TopCover': 500
};
const RUBBER_STICKER_PRICE_PER_SQFT: Record<string, number> = { '3mm': 26, '6mm': 32, '10mm': 45, '12mm': 60 };
const RUBBER_STICKER_BASE_PRICE_PER_SQFT = 85;
const MARINE_PLYWOOD_PRICE_PER_SQFT: Record<string, number> = { '6mm': 90, '18mm': 185 };
const LAMINATED_PLYWOOD_PRICE_PER_SQFT: Record<string, number> = { '6mm': 125, '18mm': 210 };
// Acrylic Sump Cover = live Acrylic rate x this markup (StickerPricingSetup row 'Acrylic Sump Cover').
const ACRYLIC_SUMP_COVER_MARKUP = 1.5;

function stickerTypeHasThickness(type: string): boolean {
  return type === 'Rubber Matting' || type === 'Glass' || type === 'Marine Plywood' || type === 'Laminated Plywood';
}

interface StickerPriceLookup {
  flat: Record<string, number>;
  rubber: Record<string, number>;
  rubberBase: number;
  marinePlywood: Record<string, number>;
  laminatedPlywood: Record<string, number>;
  acrylicSumpCoverMarkup: number;
}

function buildStickerPriceLookup(rows: Array<Record<string, unknown>> | null | undefined): StickerPriceLookup {
  const flat = Object.assign({}, STICKER_PRICE_PER_SQFT);
  const rubber = Object.assign({}, RUBBER_STICKER_PRICE_PER_SQFT);
  let rubberBase = RUBBER_STICKER_BASE_PRICE_PER_SQFT;
  const marinePlywood = Object.assign({}, MARINE_PLYWOOD_PRICE_PER_SQFT);
  const laminatedPlywood = Object.assign({}, LAMINATED_PLYWOOD_PRICE_PER_SQFT);
  let acrylicSumpCoverMarkup = ACRYLIC_SUMP_COVER_MARKUP;
  const items = Array.isArray(rows) ? rows : [];

  for (const row of items) {
    const type = String((row as any).stickerType ?? (row as any).sticker_type ?? (row as any).StickerType ?? '').trim();
    const thicknessRaw = (row as any).thickness ?? (row as any).Thickness;
    const price = Number((row as any).pricePerSqFt ?? (row as any).price_per_sqft ?? (row as any).PricePerSqFt ?? 0);
    if (!type || !(price > 0)) continue;

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
    } else if (type === 'Acrylic Sump Cover') {
      acrylicSumpCoverMarkup = price;
    } else if (Object.prototype.hasOwnProperty.call(flat, type)) {
      flat[type] = price;
    }
  }

  return { flat, rubber, rubberBase, marinePlywood, laminatedPlywood, acrylicSumpCoverMarkup };
}

function stickerPricePerSqFt(type: string, thickness: string | null, stickerLookup: StickerPriceLookup, glassLookup: Record<string, number>): number {
  const { flat, rubber, rubberBase, marinePlywood, laminatedPlywood, acrylicSumpCoverMarkup } = stickerLookup;
  const glass = glassLookup || DEFAULT_GLASS_PRICES;

  if (type === 'Acrylic Sump Cover') return flat['Acrylic'] * acrylicSumpCoverMarkup;
  if (type === 'Rubber Matting') return (thickness && rubber[thickness]) || rubberBase;
  if (type === 'Glass') return (thickness && glass[thickness]) || glass['6mm'];
  if (type === 'Marine Plywood') return (thickness && marinePlywood[thickness]) || marinePlywood['6mm'];
  if (type === 'Laminated Plywood') return (thickness && laminatedPlywood[thickness]) || laminatedPlywood['6mm'];
  return flat[type] || flat['Plain Sticker'];
}

// Length/Width only (no height) - stickers/mats/covers are flat, same as the desktop dialog.
function calculateStandaloneSticker(input: Record<string, unknown>): Record<string, unknown> {
  const options = input || {};
  const unit = (options.unit as string) || 'Inches';
  const lengthInches = toInches(options.length as number, unit);
  const widthInches = toInches(options.width as number, unit);

  if (!(lengthInches > 0) || !(widthInches > 0)) {
    return { ok: false, error: 'Please enter valid positive Length and Width.' };
  }

  const type = (options.type as string) || 'Plain Sticker';
  const hasThickness = stickerTypeHasThickness(type);
  const thickness = hasThickness ? ((options.thickness as string) || '6mm') : null;
  const isRepair = type === 'Glass' && Boolean(options.repair);
  const isTempered = type === 'Glass' && Boolean(options.tempered);

  const stickerLookup = buildStickerPriceLookup(options.stickerPricingSetupRows as Array<Record<string, unknown>>);
  const glassLookup = buildGlassPriceLookup(options.glassPricingSetupRows as Array<Record<string, unknown>>, (options.glassPricingUom as string) || 'MM');
  const areaSqFt = inchesToFeet(lengthInches) * inchesToFeet(widthInches);
  const pricePerSqFt = stickerPricePerSqFt(type, thickness, stickerLookup, glassLookup);
  let estimatedPrice = areaSqFt * pricePerSqFt;
  // Tempered glass is double the glass rate - the same 2x the custom aquarium calculator applies.
  if (isTempered) estimatedPrice *= 2;
  if (isRepair) estimatedPrice *= 2.5;

  return {
    ok: true,
    totalPrice: ceilNearest10(estimatedPrice),
    normalized: {
      unit,
      lengthInches: round2(lengthInches),
      widthInches: round2(widthInches),
      areaSqFt: round2(areaSqFt),
      type,
      thickness,
      isRepair,
      isTempered
    }
  };
}
// ============================================================================
// END: ported from custom-aquarium-calculator.js
// ============================================================================

export async function computeStickerQuote(supabase: SupabaseClient, input: Record<string, unknown>): Promise<Record<string, unknown>> {
  const [{ data: stickerRows }, { data: glassRows }] = await Promise.all([
    supabase.rpc('public_get_sticker_pricing'),
    supabase.rpc('public_get_glass_pricing')
  ]);

  return calculateStandaloneSticker({
    unit: (input.unit as string) || 'Inches',
    length: Number(input.length),
    width: Number(input.width),
    type: (input.type as string) || 'Plain Sticker',
    thickness: (input.thickness as string) || undefined,
    repair: Boolean(input.is_repair),
    tempered: Boolean(input.is_tempered),
    stickerPricingSetupRows: stickerRows ?? [],
    glassPricingSetupRows: glassRows ?? [],
    glassPricingUom: 'MM'
  });
}

// ============================================================================
// BEGIN: ported from docs/js/repairCalculator.js (repairRecalculate + everything it calls) - backs
// compute_repair_quote. Panel Replacement: each checked panel's own area (SAME convention as
// getGlassAreaSqFt above - Bottom = Length x Width, Front/Back = Length x Height, Left/Right =
// Width x Height) x the live glass rate (buildGlassPriceLookup, the shared lookup above - not a
// re-implementation) + a labor markup % from RepairPricingSetup, summed across every checked panel.
// Resealing/Leak Repair: estimated gallons (L x W x H / 231) picks one of five size tiers, each
// with its own configurable flat fee. Source of truth is that file - if its pricing logic changes,
// re-sync this block. Same hand-ported-copy caveat as calculateCustomAquarium/
// calculateStandaloneSticker above - both copies must be kept in sync manually.
// Glass type (before the labor markup): Regular 1x, Tempered 2x, Low Iron 1.7x, Low Iron + Tempered
// 3.4x. When the aquarium's HEIGHT is 36 inches or more, every replacement panel is tempered:
// Regular -> Tempered, Low Iron -> Low Iron + Tempered. Length/width don't trigger it.
// ============================================================================

const REPAIR_GLASS_TYPES: Record<string, { label: string; multiplier: number; temperedAs?: string }> = {
  regular: { label: 'Regular', multiplier: 1, temperedAs: 'tempered' },
  tempered: { label: 'Tempered', multiplier: 2 },
  low_iron: { label: 'Low Iron', multiplier: 1.7, temperedAs: 'low_iron_tempered' },
  low_iron_tempered: { label: 'Low Iron + Tempered', multiplier: 2 * 1.7 }
};
const REPAIR_TEMPERED_MIN_INCHES = 36;

const REPAIR_PANEL_LOCATIONS = ['Bottom', 'Front', 'Back', 'Left', 'Right'];

const REPAIR_RESEAL_TIERS: Array<{ maxGallons: number; label: string; settingKey: string }> = [
  { maxGallons: 20, label: 'up to 20 gal', settingKey: 'resealingSmallFee' },
  { maxGallons: 50, label: '21-50 gal', settingKey: 'resealingMediumFee' },
  { maxGallons: 100, label: '51-100 gal', settingKey: 'resealingLargeFee' },
  { maxGallons: 150, label: '101-150 gal', settingKey: 'resealingXlFee' },
  { maxGallons: Infinity, label: '151+ gal (monster tank)', settingKey: 'resealingMonsterFee' }
];

function repairResealTierFor(gallons: number): { maxGallons: number; label: string; settingKey: string } {
  return REPAIR_RESEAL_TIERS.find((tier) => gallons <= tier.maxGallons) || REPAIR_RESEAL_TIERS[REPAIR_RESEAL_TIERS.length - 1];
}

// Same convention as getGlassAreaSqFt: Bottom = Length x Width, Front/Back = Length x Height, Left/Right = Width x Height.
function repairPanelDims(panel: string, lengthInches: number, widthInches: number, heightInches: number): { width: number; height: number } {
  if (panel === 'Bottom') return { width: lengthInches, height: widthInches };
  if (panel === 'Front' || panel === 'Back') return { width: lengthInches, height: heightInches };
  return { width: widthInches, height: heightInches }; // Left / Right
}

function calculateRepairQuote(input: Record<string, unknown>): Record<string, unknown> {
  const options = input || {};
  const unit = (options.unit as string) || 'Inches';
  const lengthInches = toInches(options.length as number, unit);
  const widthInches = toInches(options.width as number, unit);
  const heightInches = toInches(options.height as number, unit);

  if (!(lengthInches > 0) || !(widthInches > 0) || !(heightInches > 0)) {
    return { ok: false, error: 'Please enter valid positive overall Length, Width, and Height for the aquarium.' };
  }

  const repairType = (options.repairType as string) === 'reseal' ? 'reseal' : 'panel';
  const setup = (options.repairPricingSetup || {}) as Record<string, number>;
  const glassLookup = (options.glassLookup || {}) as Record<string, number>;

  if (repairType === 'panel') {
    const panels = Array.isArray(options.panels)
      ? (options.panels as string[]).filter((p) => REPAIR_PANEL_LOCATIONS.includes(p))
      : [];
    if (panels.length === 0) {
      return { ok: false, error: 'Please specify at least one damaged panel (Bottom, Front, Back, Left, or Right).' };
    }
    const thickness = normalizeGlass((options.glassThickness as string) || '6mm');
    const glassType = REPAIR_GLASS_TYPES[options.glassType as string] || REPAIR_GLASS_TYPES.regular;
    const baseRate = glassLookup[thickness] || DEFAULT_GLASS_PRICES[thickness] || 0;
    const markupPercent = Number(setup.panelReplacementMarkupPercent) || 20;

    let total = 0;
    const breakdown: Array<Record<string, unknown>> = [];
    for (const panel of panels) {
      const { width, height } = repairPanelDims(panel, lengthInches, widthInches, heightInches);
      const areaSqFt = (width * height) / 144;
      const forcedTempered = Boolean(glassType.temperedAs) && heightInches >= REPAIR_TEMPERED_MIN_INCHES;
      const panelType = forcedTempered ? REPAIR_GLASS_TYPES[glassType.temperedAs as string] : glassType;
      const glassCost = areaSqFt * baseRate * panelType.multiplier;
      const markup = glassCost * (markupPercent / 100);
      const price = glassCost + markup;
      total += price;
      breakdown.push({
        panel, widthInches: round2(width), heightInches: round2(height), areaSqFt: round2(areaSqFt), price: round2(price),
        glassType: panelType.label,
        ...(forcedTempered ? { temperedRequired: 'The aquarium is 36 inches or taller, so replacement glass must be tempered for safety.' } : {})
      });
    }

    return {
      ok: true,
      repairType: 'panel',
      totalPrice: round2(total),
      normalized: {
        unit,
        lengthInches: round2(lengthInches),
        widthInches: round2(widthInches),
        heightInches: round2(heightInches),
        glassThickness: thickness,
        glassType: glassType.label,
        panels: breakdown
      }
    };
  }

  // Resealing / Leak Repair - priced by tank size tier, not per-panel.
  const gallons = cubicInchesToGallons(lengthInches * widthInches * heightInches);
  const tier = repairResealTierFor(gallons);
  const total = Number(setup[tier.settingKey]) || 0;

  return {
    ok: true,
    repairType: 'reseal',
    totalPrice: round2(total),
    normalized: {
      unit,
      lengthInches: round2(lengthInches),
      widthInches: round2(widthInches),
      heightInches: round2(heightInches),
      estimatedGallons: Math.round(gallons),
      tierLabel: tier.label
    }
  };
}

export async function computeRepairQuote(supabase: SupabaseClient, input: Record<string, unknown>): Promise<Record<string, unknown>> {
  const [{ data: glassRows }, { data: setupRows }] = await Promise.all([
    supabase.rpc('public_get_glass_pricing'),
    supabase.rpc('public_get_repair_pricing_setup')
  ]);

  const glassLookup = buildGlassPriceLookup(glassRows ?? [], 'MM');
  const setupRow = (Array.isArray(setupRows) ? setupRows[0] : setupRows) as Record<string, unknown> | undefined;
  const repairPricingSetup = {
    panelReplacementMarkupPercent: Number(setupRow?.panel_replacement_markup_percent) || 20,
    resealingSmallFee: Number(setupRow?.resealing_flat_fee) || 500,
    resealingMediumFee: Number(setupRow?.resealing_medium_fee) || 800,
    resealingLargeFee: Number(setupRow?.resealing_large_fee) || 1200,
    resealingXlFee: Number(setupRow?.resealing_xl_fee) || 1800,
    resealingMonsterFee: Number(setupRow?.resealing_monster_fee) || 2500
  };

  return calculateRepairQuote({
    unit: (input.unit as string) || 'Inches',
    length: Number(input.length),
    width: Number(input.width),
    height: Number(input.height),
    repairType: (input.repair_type as string) || 'panel',
    panels: Array.isArray(input.panels) ? input.panels : [],
    glassThickness: (input.glass_thickness as string) || '6mm',
    glassType: (input.glass_type as string) || 'regular',
    glassLookup,
    repairPricingSetup
  });
}
// ============================================================================
// END: ported from repairCalculator.js
// ============================================================================

export async function computeDeliveryQuote(supabase: SupabaseClient, input: Record<string, unknown>): Promise<Record<string, unknown>> {
  const location = String(input.origin_location ?? '').trim();
  const destinationAddress = String(input.destination_address ?? '').trim();
  if (!location || !destinationAddress) {
    return { error: 'Need both a branch (Amaya or GMA) and a delivery address.' };
  }

  const { data: warehouseRows } = await supabase.rpc('public_get_warehouse_location', { p_location: location });
  const origin = warehouseRows?.[0] as { address: string; latitude: number; longitude: number } | undefined;
  if (!origin) {
    return { error: `No branch location found matching "${location}".` };
  }

  const { data: settingsRows } = await supabase.rpc('public_get_delivery_quote_settings');
  const settings: Record<string, string> = Object.fromEntries(
    (settingsRows ?? []).map((r: { setting_key: string; setting_value: string }) => [r.setting_key, r.setting_value])
  );
  const baseFee = Number(settings.DELIVERY_BASE_FEE ?? 0);
  const ratePerKm = Number(settings.DELIVERY_RATE_PER_KM ?? 0);
  const flatTollFee = Number(settings.DELIVERY_TOLL_FEE ?? 0);

  const routesApiKey = Deno.env.get('GOOGLE_ROUTES_API_KEY');
  if (!routesApiKey) {
    return { error: 'Delivery estimation is not configured yet - ask staff to set this up.' };
  }

  let data: any;
  try {
    const res = await fetch('https://routes.googleapis.com/directions/v2:computeRoutes', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-Goog-Api-Key': routesApiKey,
        'X-Goog-FieldMask': 'routes.travelAdvisory.tollInfo,routes.distanceMeters'
      },
      body: JSON.stringify({
        origin: { location: { latLng: { latitude: origin.latitude, longitude: origin.longitude } } },
        destination: { address: destinationAddress },
        travelMode: 'DRIVE',
        extraComputations: ['TOLLS']
      })
    });
    data = await res.json();
    if (!res.ok) {
      return { error: data?.error?.message || 'Could not calculate distance for that address.' };
    }
  } catch (err) {
    return { error: err instanceof Error ? err.message : 'Could not reach the mapping service.' };
  }

  const route = data?.routes?.[0];
  if (!route?.distanceMeters) {
    return { error: 'Could not find a driving route to that address - ask the customer to double check it.' };
  }
  const distanceKm = route.distanceMeters / 1000;

  const priceObj = route?.travelAdvisory?.tollInfo?.estimatedPrice?.[0];
  const googleToll = priceObj ? Number(priceObj.units || 0) + (priceObj.nanos || 0) / 1e9 : null;
  const tollAmount = googleToll ?? flatTollFee;
  const tollSource = googleToll !== null ? 'google' : 'flat';

  const estimatedFee = baseFee + ratePerKm * distanceKm + tollAmount;

  return {
    ok: true,
    originBranch: location,
    originAddress: origin.address,
    distanceKm: Math.round(distanceKm * 10) / 10,
    tollAmount,
    tollSource,
    estimatedFee: Math.round(estimatedFee)
  };
}

// Backs the compute_lalamove_quote tool - gets a REAL price from Lalamove's own Quotation API (via
// the delivery-lalamove-quote Edge Function, the same signing proxy docs/js/deliveryQuote.js and
// orderNow.js already use), rather than an in-house formula. Unlike computeDeliveryQuote (which
// hands Google's Routes API a plain destination address string), Lalamove's API needs the
// destination as resolved lat/lng, so this geocodes it first - reusing GOOGLE_ROUTES_API_KEY, since
// Geocoding API is a standard Maps Platform API that's normally enabled alongside Routes API on the
// same Google Cloud key. region=ph biases ambiguous/informal PH addresses toward the right match.
//
// IMPORTANT: the Geocoding API always returns a "status" field even on failure (REQUEST_DENIED,
// OVER_QUERY_LIMIT, INVALID_REQUEST, UNKNOWN_ERROR) - those mean the KEY/quota/config is broken,
// not that the address is bad, and must never be reported to the customer as "couldn't find your
// address" (that previously happened here - the old code only checked results[0], so a REQUEST_DENIED
// response silently looked identical to a genuine zero-result and Alice kept blaming valid addresses).
// Only a real ZERO_RESULTS is an actual bad-address case.
async function geocodeAddress(address: string, apiKey: string): Promise<{ lat: number; lng: number } | null> {
  const url = `https://maps.googleapis.com/maps/api/geocode/json?address=${encodeURIComponent(address)}&region=ph&key=${apiKey}`;
  const res = await fetch(url);
  const data = await res.json();
  if (data?.status && data.status !== 'OK' && data.status !== 'ZERO_RESULTS') {
    // Logs only the last 6 chars of the key (never the full secret) so staff can confirm in
    // Google Cloud Console whether this is actually the same key they just edited - a
    // REQUEST_DENIED that persists after adding Geocoding API to a key's restrictions usually
    // means the wrong key got edited (projects often have a separate frontend Maps/Places key).
    console.error(`geocodeAddress service error for "${address}" (key ...${apiKey.slice(-6)}): ${data.status} - ${data.error_message ?? 'no detail'}`);
    throw new Error('GEOCODE_SERVICE_ERROR');
  }
  const loc = data?.results?.[0]?.geometry?.location;
  return loc ? { lat: loc.lat, lng: loc.lng } : null;
}

// Strict Geocoding API often can't resolve a full informal PH address in one run-on string (e.g.
// "blk 6 lot 7 brgy luzviminda 2 dasmarinas cavite") even though the exact same barangay resolves
// fine on its own - the store's own Places Autocomplete widget (docs/js/deliveryQuote.js,
// GOOGLE_MAPS_API_KEY) shows this: it happily matches "brgy luzviminda 2 dasmarinas" to "Brgy
// Luzviminda II Hall". So when the full address comes back empty, retry with just the
// barangay-and-up portion (or, lacking a barangay marker, the last few words = city/province) -
// good enough for an approximate Lalamove fee, better than refusing and blaming a valid address.
function simplifyToHighLevelAddress(address: string): string | null {
  const brgyMatch = address.match(/\b(?:brgy\.?|barangay)\b.*/i);
  if (brgyMatch && brgyMatch[0].trim().toLowerCase() !== address.trim().toLowerCase()) {
    return brgyMatch[0].trim();
  }
  const words = address.trim().split(/\s+/);
  return words.length > 3 ? words.slice(-3).join(' ') : null;
}

async function geocodeAddressWithFallback(
  address: string,
  apiKey: string
): Promise<{ lat: number; lng: number; approximate: boolean } | null> {
  const exact = await geocodeAddress(address, apiKey);
  if (exact) return { ...exact, approximate: false };

  const simplified = simplifyToHighLevelAddress(address);
  if (!simplified) return null;
  const approx = await geocodeAddress(simplified, apiKey);
  return approx ? { ...approx, approximate: true } : null;
}

export async function computeLalamoveQuote(supabase: SupabaseClient, input: Record<string, unknown>): Promise<Record<string, unknown>> {
  const location = String(input.origin_location ?? '').trim();
  const destinationAddress = String(input.destination_address ?? '').trim();
  const vehicleType = String(input.vehicle_type ?? '').trim();
  if (!location || !destinationAddress || !vehicleType) {
    return { error: 'Need a branch (Amaya or GMA), a delivery address, and a vehicle type.' };
  }

  const { data: warehouseRows } = await supabase.rpc('public_get_warehouse_location', { p_location: location });
  const origin = warehouseRows?.[0] as { address: string; latitude: number; longitude: number } | undefined;
  if (!origin) {
    return { error: `No branch location found matching "${location}".` };
  }

  const routesApiKey = Deno.env.get('GOOGLE_ROUTES_API_KEY');
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!routesApiKey || !supabaseUrl || !serviceRoleKey) {
    return { error: 'Lalamove quoting is not configured yet - ask staff to set this up.' };
  }

  let destLatLng: { lat: number; lng: number; approximate: boolean } | null;
  try {
    destLatLng = await geocodeAddressWithFallback(destinationAddress, routesApiKey);
  } catch (err) {
    if (err instanceof Error && err.message === 'GEOCODE_SERVICE_ERROR') {
      return {
        error:
          'The mapping service itself failed (not the address - do not ask the customer to retype or clarify it). Tell them there\'s a technical issue getting the Lalamove quote right now and call escalate_to_staff so a team member can follow up with the quote manually.'
      };
    }
    return { error: err instanceof Error ? err.message : 'Could not reach the mapping service.' };
  }
  if (!destLatLng) {
    return {
      error:
        'Could not find that delivery address, even after trying just the barangay/city portion - ask the customer for a nearby landmark or a more complete street/barangay name.'
    };
  }

  let quote: Record<string, unknown>;
  try {
    const res = await fetch(`${supabaseUrl}/functions/v1/delivery-lalamove-quote`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${serviceRoleKey}`, 'apikey': serviceRoleKey },
      body: JSON.stringify({
        origin: { lat: origin.latitude, lng: origin.longitude, address: origin.address },
        destination: { lat: destLatLng.lat, lng: destLatLng.lng, address: destinationAddress },
        serviceType: vehicleType
      })
    });
    quote = await res.json();
    if (!res.ok) {
      return { error: (quote?.error as string) || 'Could not get a Lalamove quote for that route.' };
    }
  } catch (err) {
    return { error: err instanceof Error ? err.message : 'Could not reach Lalamove.' };
  }

  const distanceMeters = quote.distanceMeters as number | null;
  return {
    ok: true,
    originBranch: location,
    originAddress: origin.address,
    vehicleType: quote.serviceType,
    requestedVehicleType: vehicleType,
    distanceKm: distanceMeters != null ? Math.round((distanceMeters / 1000) * 10) / 10 : null,
    total: quote.total,
    currency: quote.currency || 'PHP',
    ...(destLatLng.approximate
      ? {
          approximate: true,
          approximateNote:
            'The exact address did not resolve - this fee is estimated from the barangay/area level only. Tell the customer it\'s approximate and may change slightly once staff confirm the exact pin/landmark.'
        }
      : {})
  };
}

// Backs the get_driver_location tool - a first pass at letting the chatbot answer "where is the
// driver?" using the live GPS feed from driver-app/ (see supabase_driver_locations_table.sql).
// Deliberately NOT tied to a specific order/customer yet (see that tool's description) - just
// reports whichever driver(s) are currently tracking, per direct request to test this capability
// before wiring it to real order/delivery-stop matching.
export async function computeDriverLocation(supabase: SupabaseClient, input: Record<string, unknown>): Promise<Record<string, unknown>> {
  const { data: rows, error } = await supabase.rpc('public_get_active_driver_locations');
  if (error) return { error: `Could not check driver location: ${error.message}` };

  const driver = (rows ?? [])[0] as
    | { display_name: string; latitude: number; longitude: number; recorded_at_utc: string; updated_at_utc: string }
    | undefined;
  if (!driver) {
    return { error: 'No driver is currently out and tracking right now.' };
  }

  const minutesSinceUpdate = Math.max(0, Math.round((Date.now() - new Date(driver.updated_at_utc).getTime()) / 60000));
  const result: Record<string, unknown> = {
    ok: true,
    driverDisplayName: driver.display_name,
    minutesSinceUpdate,
    latitude: driver.latitude,
    longitude: driver.longitude,
    // Primary link to share - a real live-updating page (docs/track-driver.html, public/anon, no
    // login) rather than a static coordinate snapshot, so the customer sees the driver actually
    // move if they keep the page open. Backed by the same public_get_active_driver_locations RPC
    // this tool itself calls, plus a Realtime subscription on DriverLocations for live updates.
    liveTrackingUrl: 'https://rspetstop.com/track-driver.html',
    // Secondary/fallback - a plain snapshot pin at the driver's position at the moment of this
    // reply, in case the customer wants to open it directly in Google Maps/Waze instead.
    mapsUrl: `https://www.google.com/maps?q=${driver.latitude},${driver.longitude}`
  };

  const destinationAddress = String(input.destination_address ?? '').trim();
  if (!destinationAddress) {
    return result;
  }

  const routesApiKey = Deno.env.get('GOOGLE_ROUTES_API_KEY');
  if (!routesApiKey) {
    result.etaError = 'Distance/ETA is not configured yet - just share the last-checked-in time.';
    return result;
  }

  try {
    const res = await fetch('https://routes.googleapis.com/directions/v2:computeRoutes', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-Goog-Api-Key': routesApiKey,
        'X-Goog-FieldMask': 'routes.duration,routes.distanceMeters'
      },
      body: JSON.stringify({
        origin: { location: { latLng: { latitude: driver.latitude, longitude: driver.longitude } } },
        destination: { address: destinationAddress },
        travelMode: 'DRIVE'
      })
    });
    const data = await res.json();
    if (!res.ok) {
      result.etaError = data?.error?.message || 'Could not calculate distance to that address.';
      return result;
    }
    const route = data?.routes?.[0];
    if (!route?.distanceMeters) {
      result.etaError = 'Could not find a driving route to that address - ask the customer to double check it.';
      return result;
    }
    result.distanceKm = Math.round((route.distanceMeters / 1000) * 10) / 10;
    result.etaMinutes = Math.round(Number(String(route.duration ?? '0s').replace('s', '')) / 60);
  } catch (err) {
    result.etaError = err instanceof Error ? err.message : 'Could not reach the mapping service.';
  }

  return result;
}

// Backs the send_item_image tool when NOT in sandbox mode - sent as its own Messenger message
// (Facebook has no "text with inline image" concept). Returns false on failure so executeTool can
// tell Claude the send didn't actually work, instead of the model wrongly assuring the customer a
// photo is on its way.
export async function sendMessengerImage(psid: string, imageUrl: string, pageAccessToken: string, graphVersion: string): Promise<boolean> {
  const url = `https://graph.facebook.com/${graphVersion}/me/messages?access_token=${pageAccessToken}`;
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      recipient: { id: psid },
      message: { attachment: { type: 'image', payload: { url: imageUrl, is_reusable: true } } },
      messaging_type: 'RESPONSE'
    })
  });
  if (!res.ok) {
    console.error(`Messenger image send failed (${res.status}): ${await res.text()}`);
    return false;
  }
  return true;
}

export interface ExecuteToolParams {
  supabase: SupabaseClient;
  psid: string;
  // The Facebook Page this conversation belongs to - only actually used by create_order (stored on
  // AutomatedOrders.GmaPageId, the same column staff-created GMA Conversations orders use). Every
  // other tool only ever needs psid. Optional/blank in the sandbox (docs/ai-bot-sandbox.html),
  // where create_order is always simulated anyway - see chatbot-sandbox-reply/index.ts.
  pageId?: string;
  name: string;
  input: Record<string, unknown>;
  followUpSettings: Record<string, unknown> | null;
  // Only create_order's location fallback reads this (aiSettings.DefaultLocation) - see
  // buildSystemPrompt's DEFAULT BRANCH line, which is the primary way Claude learns this same value.
  aiSettings?: Record<string, unknown> | null;
  // When true (docs/ai-bot-sandbox.html testing), every side-effecting case below skips its real
  // action and returns a "SANDBOX MODE" description instead - see this file's header comment.
  simulate?: boolean;
  pageAccessToken?: string;
  graphVersion?: string;
}

export async function executeTool(params: ExecuteToolParams): Promise<string> {
  const { supabase, psid, pageId, name, input, followUpSettings, aiSettings, simulate = false, pageAccessToken, graphVersion } = params;
  switch (name) {
    case 'search_items': {
      const query = String(input.query ?? '').trim();
      if (!query) return 'No search query provided.';
      const { data, error } = await supabase.rpc('public_search_items', { p_query: query });
      if (error) return `Search failed: ${error.message}`;
      return data && data.length > 0 ? JSON.stringify(data) : 'No matching products found.';
    }
    case 'list_categories': {
      const { data, error } = await supabase.rpc('public_list_order_categories');
      if (error) return `Lookup failed: ${error.message}`;
      return JSON.stringify(data ?? []);
    }
    case 'list_wholesale_prices': {
      const { data, error } = await supabase.rpc('public_list_wholesale_items');
      if (error) return `Lookup failed: ${error.message}`;
      return data && data.length > 0 ? JSON.stringify(data) : 'No wholesale prices are currently set on any item.';
    }
    case 'list_aquarium_sets': {
      const { data, error } = await supabase.rpc('public_list_aquarium_sets');
      if (error) return `Lookup failed: ${error.message}`;
      // A set with no price yet (e.g. AS-014 at 0) must never be quoted as free - leave it out.
      const sets = ((data ?? []) as Array<Record<string, unknown>>).filter((row) => Number(row.price) > 0);
      return sets.length > 0 ? JSON.stringify(sets) : 'No ready-made aquarium sets are currently available.';
    }
    case 'list_items_in_category': {
      const categoryCode = String(input.category_code ?? '').trim();
      if (!categoryCode) return 'No category code provided.';
      const { data, error } = await supabase.rpc('public_list_order_items', { p_category_code: categoryCode });
      if (error) return `Lookup failed: ${error.message}`;
      return data && data.length > 0 ? JSON.stringify(data) : 'No active items found in that category.';
    }
    case 'get_order_status': {
      const orderNo = String(input.order_no ?? '').trim();
      if (!orderNo) return 'No order number provided.';

      const { data: automatedData, error: automatedError } = await supabase.rpc('public_get_automated_order_status', {
        p_order_no: orderNo
      });
      if (automatedError) return `Lookup failed: ${automatedError.message}`;
      if (automatedData && automatedData.length > 0) {
        // Portal-rendered receipt, NOT Pancake's own order link - per direct decision, the bot
        // never shares Pancake's link with customers (see supabase_automated_order_portal_receipt.sql).
        const receiptUrl = `https://rspetstop.com/online-order-receipt.html?order=${encodeURIComponent(orderNo)}`;
        return JSON.stringify({ orderType: 'Automated Order', ...automatedData[0], receiptUrl });
      }

      // Not an Automated Order - try it as a regular Pancake Online Order instead (see
      // supabase_chatbot_online_order_status_rpc.sql). Most customers' order numbers are this kind,
      // not an AO-xxxxx one, so both are always checked rather than requiring the customer to know
      // which system their order lives in.
      const { data: onlineData, error: onlineError } = await supabase.rpc('public_get_online_order_status', {
        p_order_id: orderNo
      });
      if (onlineError) return `Lookup failed: ${onlineError.message}`;
      if (onlineData && onlineData.length > 0) {
        // Walk-ins are found by POS receipt no. too (supabase_chatbot_walkin_order_status.sql), so
        // everything below uses the resolved OrderID, not what the customer typed.
        const order = onlineData[0];
        const orderId = String(order.order_id);
        const isWalkIn = order.order_type === 'Walk-in Order';
        const { data: lineData, error: lineError } = await supabase.rpc('public_get_online_order_lines', { p_order_id: orderId });
        if (lineError) return `Lookup failed: ${lineError.message}`;
        // No image/PDF rendering exists in this stack (see supabase_chatbot_online_order_receipt.sql
        // header) - the bot shares a link to a public, no-login receipt page instead, only when the
        // customer actually asks for a receipt/proof of order, not on every status check. The receipt
        // page doesn't cover walk-ins (they got the POS receipt at the counter), so none for them.
        const receiptUrl = isWalkIn ? undefined : `https://rspetstop.com/online-order-receipt.html?order=${encodeURIComponent(orderId)}`;
        // Per-part build progress (tank / stand maker done or not) - no staff names, see
        // supabase_chatbot_order_production_progress.sql. Internal Portal Chat only also gets the
        // maker's name (supabase_chatbot_order_production_maker_names.sql, service_role only) -
        // never Messenger/website/sandbox. Best-effort: a failure here never hides the status.
        const productionRpc = psid.startsWith('portal-chat:') ? 'staff_get_online_order_production' : 'public_get_online_order_production';
        const { data: productionData } = await supabase.rpc(productionRpc, { p_order_id: orderId });
        return JSON.stringify({
          orderType: order.order_type ?? 'Online Order',
          ...order,
          items: lineData ?? [],
          production: productionData ?? [],
          ...(receiptUrl ? { receiptUrl } : {})
        });
      }

      return 'No order found with that number.';
    }
    case 'escalate_to_staff': {
      const reason = String(input.reason ?? 'Customer requested human assistance.');
      if (simulate) {
        return `SANDBOX MODE - no real escalation was sent. If this were live, staff would be notified via Telegram: "${reason}"`;
      }
      await supabase
        .from('ChatbotConversations')
        .update({ Status: 'Escalated', EscalatedAtUtc: new Date().toISOString(), EscalationCheckinSentAtUtc: null })
        .eq('Psid', psid);
      await supabase.rpc('_telegram_send_message', { p_text: `Chatbot escalation (PSID ${psid}): ${reason}` });
      return 'Staff have been notified and will follow up with the customer directly in this conversation.';
    }
    case 'log_capability_gap': {
      const question = String(input.question ?? '').trim();
      if (!question) return 'No question provided to log.';
      // Not gated behind `simulate` - this is a meta/product-improvement record about a gap in
      // Alice herself, not a customer-facing side effect, so it's useful to capture even from the
      // AI Bot Sandbox or a portal chat test, not just live channels.
      const channel = psid.startsWith('web:') ? 'website'
        : psid.startsWith('sandbox:') ? 'sandbox'
        : psid.startsWith('portal-chat:') ? 'portal-chat'
        : psid.startsWith('telegram:') ? 'telegram'
        : 'messenger';
      await supabase.from('BotCapabilityGaps').insert({ Channel: channel, Question: question });
      return 'Logged for the team to review as a possible future feature. Make sure the person already knows honestly that you can\'t help with this yet.';
    }
    case 'send_item_image': {
      const itemCode = String(input.item_code ?? '').trim();
      if (!itemCode) return 'No item code provided.';

      const { data: imagesRaw, error } = await supabase.rpc('public_get_item_image', { p_code: itemCode });
      if (error) return `Lookup failed: ${error.message}`;

      const imageUrl = imagesRaw ? String(imagesRaw).split(',')[0].trim() : '';
      if (!imageUrl) return 'No photo is on file for that item - let the customer know a photo isn\'t available yet.';

      if (simulate) {
        return `SANDBOX MODE - no real photo was sent. If this were live, this photo would be sent to the customer: ${imageUrl}`;
      }

      if (!pageAccessToken) return 'Photo sending is not configured right now.';
      const sent = await sendMessengerImage(psid, imageUrl, pageAccessToken, graphVersion || DEFAULT_GRAPH_VERSION);
      return sent ? 'Photo sent to the customer.' : 'Sending the photo failed - let the customer know and continue without it.';
    }
    case 'compute_aquarium_quote':
      return JSON.stringify(await computeAquariumQuote(supabase, input));
    case 'compute_delivery_quote':
      return JSON.stringify(await computeDeliveryQuote(supabase, input));
    case 'compute_lalamove_quote':
      return JSON.stringify(await computeLalamoveQuote(supabase, input));
    case 'compute_sticker_quote':
      return JSON.stringify(await computeStickerQuote(supabase, input));
    case 'compute_repair_quote':
      return JSON.stringify(await computeRepairQuote(supabase, input));
    case 'get_driver_location':
      return JSON.stringify(await computeDriverLocation(supabase, input));
    case 'save_customer_info': {
      const name = String(input.name ?? '').trim();
      const phone = String(input.phone ?? '').trim();
      const address = String(input.address ?? '').trim();
      if (!name && !phone && !address) return 'Nothing to save - name, phone, and address were all empty.';

      if (simulate) {
        return `SANDBOX MODE - no real record was saved. If this were live, this would be saved to the customer record: ${JSON.stringify({ name: name || undefined, phone: phone || undefined, address: address || undefined })}`;
      }

      const update: Record<string, unknown> = {};
      if (name) {
        update.CustomerName = name;
        update.CustomerNameSource = 'CustomerProvided';
      }
      if (phone) update.CustomerPhone = phone;
      if (address) update.CustomerAddress = address;

      const { error } = await supabase.from('ChatbotConversations').update(update).eq('Psid', psid);
      if (error) return `Could not save that: ${error.message}`;
      return 'Saved to the customer record.';
    }
    case 'create_order': {
      const customerName = String(input.customer_name ?? '').trim();
      const customerPhoneRaw = String(input.customer_phone ?? '').trim();
      const customerEmail = String(input.customer_email ?? '').trim();
      const fulfillmentType = String(input.fulfillment_type ?? '').trim();
      const deliveryAddress = String(input.delivery_address ?? '').trim();
      const location = String(input.location ?? '').trim() || String(aiSettings?.DefaultLocation ?? '').trim() || 'GMA';
      const notes = String(input.notes ?? '').trim();
      const items = Array.isArray(input.items)
        ? (input.items as Array<{ item_code?: string; quantity?: number; variant?: string; custom_price?: number; notes?: string }>)
        : [];

      if (!customerName) return 'Cannot place the order - customer_name is required. Ask the customer for it.';
      const phoneDigits = customerPhoneRaw.replace(/[^0-9]/g, '');
      if (!/^(09\d{9}|639\d{9})$/.test(phoneDigits)) {
        return 'Cannot place the order - customer_phone must be a valid PH mobile number (e.g. 09171234567). Ask the customer for it again.';
      }
      if (fulfillmentType !== 'Pickup' && fulfillmentType !== 'Delivery') {
        return 'Cannot place the order - fulfillment_type must be Pickup or Delivery.';
      }
      if (fulfillmentType === 'Delivery' && !deliveryAddress) {
        return 'Cannot place the order - a delivery_address is required when fulfillment_type is Delivery.';
      }
      if (items.length === 0) return 'Cannot place the order - at least one item is required.';

      if (simulate) {
        return `SANDBOX MODE - no real order was created. If this were live, an order for ${customerName} with ${items.length} item(s) would be saved for staff to review and confirm.`;
      }
      if (!pageId) return 'Cannot place the order right now - missing conversation context. Let the customer know staff will place it manually.';

      // A prior order already existing for this conversation is deliberately NOT blocked here - a
      // real customer legitimately can come back to buy something else in the same Messenger
      // thread. Per direct instruction, deciding whether a new payment belongs to an existing order
      // or a genuinely new one is handled by ASKING the customer (the payment-clarification flow in
      // facebook-messenger-webhook/index.ts, which only calls this tool for a "new" order AFTER
      // that's been explicitly confirmed) rather than a hard refusal here. The PLACING ORDERS system
      // prompt rules carry the same "ask, don't assume" responsibility for the general conversation
      // path (when this tool is reached without going through a payment screenshot).

      // Item name/price are ALWAYS looked up from the real catalog here, never trusted from the
      // model - an AI-guessed item_code or price is exactly the kind of input that needs
      // independent server-side verification, same discipline as every other order-creation path
      // in this codebase (see sql/supabase_submit_automated_order_price_validation.sql's header).
      //
      // EXCEPT a custom-built aquarium/stand ("CUSTOM-AQUARIUM"/"CUSTOM-STAND"), which has no real
      // catalog price to verify against - its price comes from the customer-confirmed
      // compute_aquarium_quote result already relayed in this conversation (custom_price), same
      // trust level that tool's own number already carries. This line is still tagged to a REAL
      // Items row (matching docs/js/orderNow.js's own customer-facing wizard convention - see
      // ItemCode: null / CategoryCode: 'CUSTOM-AQUARIUM' there and _push_automated_order_to_pancake's
      // Name-based fallback match), just with its price/spec supplied here instead of read from
      // that row's own (placeholder) RetailPrice/Price. CUSTOM-STICKER is the same idea for a
      // compute_sticker_quote line (orderNow.js's 'Custom Accessory/Sticker' convention).
      const CUSTOM_ITEM_CODES = new Set(['CUSTOM-AQUARIUM', 'CUSTOM-STAND', 'CUSTOM-STICKER']);
      const CUSTOM_ITEM_NAMES: Record<string, string> = {
        'CUSTOM-AQUARIUM': 'Custom Aquarium',
        'CUSTOM-STAND': 'Custom Stand',
        'CUSTOM-STICKER': 'Custom Accessory/Sticker'
      };
      const customItems = items.filter((it) => CUSTOM_ITEM_CODES.has(String(it.item_code ?? '').trim().toUpperCase()));
      const catalogCodedItems = items.filter((it) => !CUSTOM_ITEM_CODES.has(String(it.item_code ?? '').trim().toUpperCase()));

      for (const it of customItems) {
        const tag = String(it.item_code ?? '').trim().toUpperCase();
        if (!(Number(it.custom_price) > 0)) {
          return `Cannot place the order - ${tag} needs a custom_price greater than 0 (the price already confirmed via ${tag === 'CUSTOM-STICKER' ? 'compute_sticker_quote' : 'compute_aquarium_quote'}).`;
        }
        if (!String(it.notes ?? '').trim()) {
          return `Cannot place the order - ${tag} needs a notes value with the full confirmed spec (${tag === 'CUSTOM-STICKER' ? 'type, size, thickness, etc.' : 'dimensions, glass thickness, etc.'}).`;
        }
      }

      const codes = [...new Set(catalogCodedItems.map((it) => String(it.item_code ?? '').trim()).filter(Boolean))];
      if (codes.length === 0 && customItems.length === 0) return 'Cannot place the order - no valid item_code values were given.';

      type CatalogItem = { Code: string; Name: string; RetailPrice: number | null; Price: number | null; CategoryCode: string | null };
      const catalogByCode = new Map<string, CatalogItem>();

      if (codes.length > 0) {
        const { data: catalogItems, error: itemsError } = await supabase
          .from('Items')
          .select('Code, Name, RetailPrice, Price, CategoryCode')
          .in('Code', codes)
          .eq('IsActive', true);
        if (itemsError) return `Could not validate items: ${itemsError.message}`;
        for (const it of (catalogItems ?? []) as CatalogItem[]) catalogByCode.set(it.Code, it);
        const unknownCodes = codes.filter((c) => !catalogByCode.has(c));
        if (unknownCodes.length > 0) {
          return `These item_code value(s) don't match a real, active catalog item: ${unknownCodes.join(', ')}. Use search_items or list_items_in_category to find the correct code - never invent one.`;
        }
      }

      // Resolve each catalog line's variant (color/option) to a real Variants."VariationId", stored
      // on AutomatedOrderLines."VariationId" so _push_automated_order_to_pancake tags that exact
      // variation. Without it the push falls back to Items."VariationId" - one representative
      // variation per product - which is how AO-00029 (Black Sealant requested, only in the line
      // note) went to Pancake as Clear Sealant. A product with 2+ variants is refused until the
      // option is given, rather than silently defaulting.
      const variationIdByItem = new Map<object, string>();
      if (codes.length > 0) {
        const { data: variantRows, error: variantsError } = await supabase
          .from('Variants')
          .select('VariationId, MainItemCode, SKU')
          .in('MainItemCode', codes);
        if (variantsError) return `Could not validate item variants: ${variantsError.message}`;

        const normalize = (s: string) => s.toLowerCase().replace(/[^a-z0-9]/g, '');
        // "AQ-024-BlackSealant" -> "Black Sealant" (same derivation as stock_by_variant's option -
        // see sql/supabase_chatbot_stock_variant_option.sql).
        const optionLabel = (sku: string | null, code: string, variationId: string) => {
          if (!sku) return variationId;
          const rest = sku.toUpperCase().startsWith(code.toUpperCase() + '-') ? sku.slice(code.length + 1) : sku;
          return rest.replace(/([a-z])([A-Z])/g, '$1 $2').trim() || sku;
        };

        for (const it of catalogCodedItems) {
          const code = String(it.item_code ?? '').trim();
          const variants = ((variantRows ?? []) as Array<{ VariationId: string; MainItemCode: string; SKU: string | null }>)
            .filter((v) => v.MainItemCode === code)
            .map((v) => ({ id: v.VariationId, sku: v.SKU ?? '', option: optionLabel(v.SKU, code, v.VariationId) }));
          if (variants.length === 0) continue;
          if (variants.length === 1) {
            variationIdByItem.set(it, variants[0].id);
            continue;
          }

          const itemName = catalogByCode.get(code)?.Name ?? code;
          const optionList = variants.map((v) => `${v.option} (${v.sku || v.id})`).join(', ');
          const wanted = normalize(String(it.variant ?? ''));
          if (!wanted) {
            return `Cannot place the order - ${itemName} (${code}) comes in more than one option: ${optionList}. Confirm with the customer which one they want, then pass it as that item's variant.`;
          }
          const exact = variants.filter((v) => normalize(v.sku) === wanted || normalize(v.option) === wanted);
          const matches = exact.length > 0 ? exact : variants.filter((v) => normalize(v.option).includes(wanted));
          if (matches.length !== 1) {
            return `Cannot place the order - "${it.variant}" doesn't match exactly one option of ${itemName} (${code}). Its options are: ${optionList}. Pass one of these as the variant.`;
          }
          variationIdByItem.set(it, matches[0].id);
        }
      }

      // No check here that the CUSTOM-* placeholder Items rows exist: the bot no longer pushes to
      // Pancake (see the insert below), so a missing row only matters when staff push the order -
      // and the push already refuses and shows the error then (PancakeSyncStatus 'Failed').

      let estimatedTotal = 0;
      const orderLines = items.map((it) => {
        const tag = String(it.item_code ?? '').trim().toUpperCase();
        const quantity = Math.max(1, Math.trunc(Number(it.quantity) || 1));

        if (CUSTOM_ITEM_CODES.has(tag)) {
          const price = Number(it.custom_price) || 0;
          estimatedTotal += quantity * price;
          return {
            CategoryCode: tag,
            ItemCode: null,
            ItemName: CUSTOM_ITEM_NAMES[tag],
            Quantity: quantity,
            Price: price,
            Notes: String(it.notes ?? '').trim() || null
          };
        }

        const catalogItem = catalogByCode.get(String(it.item_code ?? '').trim())!;
        const price = Number(catalogItem.RetailPrice ?? catalogItem.Price ?? 0);
        estimatedTotal += quantity * price;
        return {
          CategoryCode: catalogItem.CategoryCode,
          ItemCode: catalogItem.Code,
          ItemName: catalogItem.Name,
          Quantity: quantity,
          Price: price,
          Notes: String(it.notes ?? '').trim() || null,
          VariationId: variationIdByItem.get(it) ?? null
        };
      });

      const { data: orderNoData, error: orderNoError } = await supabase.rpc('_next_no_series_number', {
        p_series_code: 'AUTOMATED-ORDER',
        p_scope_key: ''
      });
      if (orderNoError || !orderNoData) return `Could not place the order: ${orderNoError?.message || 'no order number was issued'}.`;
      const orderNo = String(orderNoData);

      const { error: insertOrderError } = await supabase.from('AutomatedOrders').insert({
        OrderNo: orderNo,
        CustomerName: customerName,
        CustomerPhone: customerPhoneRaw,
        CustomerEmail: customerEmail || null,
        FulfillmentType: fulfillmentType,
        DeliveryAddress: fulfillmentType === 'Delivery' ? deliveryAddress : null,
        Notes: notes || null,
        Status: 'New',
        EstimatedTotal: estimatedTotal,
        Location: location,
        GmaPsid: psid,
        GmaPageId: pageId,
        UpdatedBy: 'AI Bot',
        // Bot orders never go to Pancake - staff review it and click "Confirm Order", which creates
        // the Online Orders entry directly (admin_confirm_bot_order, sql/supabase_bot_orders_portal_confirm.sql).
        // Not 'Pending': cron_process_pending_automated_orders pushes every Pending row to Pancake.
        PancakeSyncStatus: 'Not Pushed'
      });
      if (insertOrderError) return `Could not place the order: ${insertOrderError.message}`;

      // Feeds the CRM too - a customer who goes straight to ordering without an earlier
      // save_customer_info call still ends up on file for next time. Never raises past this
      // point - a CRM write failure must not undo/block the order that was just placed. Address
      // is only included when this order actually had one (Delivery) - a Pickup order leaves any
      // previously-saved CRM address alone rather than clobbering it with null.
      const crmUpdate: Record<string, unknown> = { CustomerName: customerName, CustomerNameSource: 'CustomerProvided', CustomerPhone: customerPhoneRaw };
      if (fulfillmentType === 'Delivery' && deliveryAddress) crmUpdate.CustomerAddress = deliveryAddress;
      await supabase.from('ChatbotConversations').update(crmUpdate).eq('Psid', psid);

      const { error: insertLinesError } = await supabase
        .from('AutomatedOrderLines')
        .insert(orderLines.map((l) => ({ ...l, OrderNo: orderNo })));
      if (insertLinesError) return `Order ${orderNo} was created but its items could not be saved (${insertLinesError.message}) - tell the customer staff will fix this manually.`;

      // Marks this order as awaiting the customer's confirmation reply to the message you're about
      // to send (see the PLACING ORDERS rule for what that message must contain) - the webhook's
      // reply-interception logic (facebook-messenger-webhook/index.ts) picks up a later "yes" reply
      // against this exact timestamp (same isAffirmativeReply/staleness-guard mechanism the
      // deterministic payment-screenshot receipt already uses - sql/supabase_gma_conversation_
      // receipt_confirmation.sql), so staff still see the "customer confirmed" badge in GMA
      // Conversations even though THIS reply is composed by you, not the deterministic ack.
      await supabase.from('AutomatedOrders').update({ ReceiptConfirmationRequestedAtUtc: new Date().toISOString() }).eq('OrderNo', orderNo);

      return JSON.stringify({
        ok: true,
        orderNo,
        estimatedTotal,
        status: 'Saved - waiting for staff to review and confirm',
        // Portal-rendered receipt (docs/online-order-receipt.html), NOT Pancake's own order_link -
        // per direct decision, never share that. See the PLACING ORDERS rule - share this AND ask
        // for confirmation in your reply, don't just mention the order number.
        receiptUrl: `https://rspetstop.com/online-order-receipt.html?order=${encodeURIComponent(orderNo)}`
      });
    }
    case 'schedule_follow_up': {
      if (!followUpSettings?.CommittedEnabled) {
        return 'Follow-up scheduling is turned off in the store settings right now - do not promise a callback. Let the customer know a team member will follow up if needed, or just continue helping them now.';
      }
      const hours = Math.min(168, Math.max(1, Number(input.hours_from_now) || 24));
      const reason = String(input.reason ?? 'Follow up with the customer as promised.').slice(0, 1000);
      if (simulate) {
        return `SANDBOX MODE - no real follow-up was scheduled. If this were live, a follow-up would fire in about ${hours} hour(s): "${reason}"`;
      }
      const dueAtUtc = new Date(Date.now() + hours * 60 * 60 * 1000).toISOString();
      const { error } = await supabase
        .from('ChatbotFollowUps')
        .insert({ Psid: psid, FollowUpType: 'Committed', DueAtUtc: dueAtUtc, Reason: reason, Status: 'Pending' });
      if (error) return `Could not schedule the follow-up: ${error.message}`;
      return `Follow-up scheduled for about ${hours} hour(s) from now.`;
    }
    case 'get_delivery_scheduling_options': {
      const orderNo = String(input.order_no ?? '').trim();
      if (!orderNo) return 'No order number provided.';
      const { data, error } = await supabase.rpc('public_get_delivery_scheduling_options', { p_order_id: orderNo });
      if (error) return `Lookup failed: ${error.message}`;
      if (!data || data.length === 0) return 'No order found with that number.';

      const first = data[0];
      if (!first.eligible) {
        return JSON.stringify({ eligible: false, reason: first.reason, orderId: first.order_id, customerName: first.customer_name });
      }

      // The order may not have a DeliveryFee recorded yet (Pancake/staff hasn't set one) - treat
      // both null AND 0 as "not set" (an unset numeric column defaults to 0, not null, so a bare
      // null check would wrongly quote a real order as free delivery) and fall back to the same
      // distance-based estimate compute_delivery_quote already does, using the order's own branch/
      // shipping address instead of asking the customer to retype them. If a real positive fee IS
      // already on the order, that's authoritative and used as-is (no reason to second-guess an
      // amount that may already be reflected in MoneyToCollect).
      let deliveryFee = first.delivery_fee;
      let deliveryFeeIsEstimate = false;
      if (!(Number(deliveryFee) > 0)) {
        const quote = await computeDeliveryQuote(supabase, {
          origin_location: first.warehouse_name,
          destination_address: first.shipping_address
        });
        if (quote.ok) {
          deliveryFee = quote.estimatedFee;
          deliveryFeeIsEstimate = true;
        }
      }

      return JSON.stringify({
        eligible: true,
        orderId: first.order_id,
        customerName: first.customer_name,
        deliveryFee,
        deliveryFeeIsEstimate,
        candidateDates: data.map((row: { candidate_date: string }) => row.candidate_date)
      });
    }
    case 'get_delivery_schedule_status': {
      const orderNo = String(input.order_no ?? '').trim();
      if (!orderNo) return 'No order number provided.';
      const { data, error } = await supabase.rpc('public_get_delivery_schedule_status', { p_order_id: orderNo });
      if (error) return `Lookup failed: ${error.message}`;
      if (!data || data.length === 0 || !data[0].found) return 'No order found with that number.';
      return JSON.stringify(data[0]);
    }
    case 'schedule_delivery_date': {
      const orderNo = String(input.order_no ?? '').trim();
      const deliveryDate = String(input.delivery_date ?? '').trim();
      if (!orderNo || !deliveryDate) return 'Both an order number and a delivery date are required.';

      if (simulate) {
        return `SANDBOX MODE - no real delivery was booked. If this were live, Order ${orderNo} would be scheduled for delivery on ${deliveryDate}, and staff would be notified via Telegram.`;
      }

      const { data, error } = await supabase.rpc('public_schedule_online_order_delivery', {
        p_order_id: orderNo,
        p_delivery_date: deliveryDate
      });
      if (error) return `Could not schedule that date: ${error.message}`;

      // No staff reviews this before it happens (unlike the staff-only Delivery calendar booking
      // flow) - notify staff immediately, same _telegram_send_message escalate_to_staff already
      // uses, so an unusual self-booking doesn't go unnoticed until someone happens to open the
      // calendar page.
      await supabase.rpc('_telegram_send_message', {
        p_text: `Customer self-scheduled a delivery via the Messenger AI assistant: Order ${orderNo} for ${deliveryDate}.`
      });

      return JSON.stringify({ ok: true, ...(data?.[0] ?? {}) });
    }
    default:
      return `Unknown tool: ${name}`;
  }
}

export interface RunChatbotTurnParams {
  supabase: SupabaseClient;
  anthropic: Anthropic;
  model: string;
  psid: string;
  // See ExecuteToolParams.pageId - only create_order actually uses it. Optional/blank in the
  // sandbox, where create_order is always simulated regardless.
  pageId?: string;
  messages: Anthropic.MessageParam[];
  followUpSettings: Record<string, unknown> | null;
  aiSettings?: Record<string, unknown> | null;
  systemBlocks: unknown;
  simulate?: boolean;
  pageAccessToken?: string;
  graphVersion?: string;
}

// The actual Claude tool-use loop, shared verbatim by the real webhook and the sandbox - history
// loading/saving and any Facebook-specific side effects (sending the final reply, updating
// ChatbotConversations) stay in each caller, since those differ between the two.
export async function runChatbotTurn(params: RunChatbotTurnParams): Promise<string> {
  const { supabase, anthropic, model, psid, pageId, messages, followUpSettings, aiSettings, systemBlocks, simulate = false, pageAccessToken, graphVersion } = params;
  let finalText = "Sorry, I'm having trouble responding right now - a team member will follow up with you shortly.";

  for (let i = 0; i < MAX_TOOL_ITERATIONS; i++) {
    const response = await anthropic.messages.create({
      model,
      max_tokens: MAX_TOKENS,
      system: systemBlocks as never,
      thinking: { type: 'adaptive' },
      output_config: { effort: 'low' },
      tools: TOOLS,
      messages
    });

    if (response.stop_reason === 'pause_turn') {
      messages.push({ role: 'assistant', content: response.content });
      continue;
    }

    if (response.stop_reason !== 'tool_use') {
      // Duck-typed rather than annotated as Anthropic.TextBlock - avoids depending on an
      // unverified type name for what's a purely internal extraction.
      const textBlocks = response.content.filter((b) => b.type === 'text') as Array<{ text: string }>;
      finalText = textBlocks.map((b) => b.text).join('\n\n') || finalText;
      break;
    }

    messages.push({ role: 'assistant', content: response.content });

    const toolUseBlocks = response.content.filter((b): b is Anthropic.ToolUseBlock => b.type === 'tool_use');
    const toolResults: Anthropic.ToolResultBlockParam[] = [];
    for (const tool of toolUseBlocks) {
      const result = await executeTool({
        supabase,
        psid,
        pageId,
        name: tool.name,
        input: tool.input as Record<string, unknown>,
        followUpSettings,
        aiSettings,
        simulate,
        pageAccessToken,
        graphVersion
      });
      toolResults.push({ type: 'tool_result', tool_use_id: tool.id, content: result });
    }
    messages.push({ role: 'user', content: toolResults });
  }

  return finalText;
}
