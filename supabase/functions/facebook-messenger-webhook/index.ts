// AI Messenger chatbot webhook for the NEW, plain Facebook Page (no Pancake/CRM layer - a
// separate integration from docs/order-now.html's Pancake-backed Automated Orders flow). Receives
// Facebook's Messenger webhook events directly, answers with Claude (tool-use against the store's
// real product/order data), and replies via the Messenger Send API.
//
// Secrets (set via `supabase secrets set NAME=value --project-ref hymcmesqgpliyyeghpgq`):
//   FACEBOOK_PAGE_ACCESS_TOKEN   - Messenger > Settings > Access Tokens, for the NEW page
//   FACEBOOK_APP_SECRET          - App Settings > Basic - used ONLY to verify X-Hub-Signature-256,
//                                   never sent anywhere
//   FACEBOOK_VERIFY_TOKEN        - any random string you choose, used only for the GET handshake
//   ANTHROPIC_API_KEY            - Claude API key
//   CLAUDE_MODEL                 - optional, defaults to claude-sonnet-5 below - override to swap
//                                   models (e.g. claude-haiku-4-5) without a redeploy
//   FACEBOOK_GRAPH_API_VERSION   - optional, defaults to v21.0 below
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are auto-injected by Supabase for every Edge Function.
// Deploy: supabase functions deploy facebook-messenger-webhook --project-ref hymcmesqgpliyyeghpgq
//
// Data model: see sql/supabase_chatbot_conversations_tables.sql (ChatbotConversations/
// ChatbotMessages), sql/supabase_chatbot_store_info_table.sql (ChatbotStoreInfo), and
// sql/supabase_chatbot_search_items_rpc.sql (public_search_items). Order-status lookups reuse
// the existing public_get_automated_order_status RPC (sql/supabase_automated_order_async_pancake_sync.sql)
// as-is - this page's PSIDs have no relationship to that RPC's OrderNo values, so the bot always
// asks the customer for their order number rather than trying to look one up by PSID/phone.
//
// Proactive follow-ups: see sql/supabase_chatbot_followup_settings.sql (on/off + delay knobs,
// portal-editable from AI Bot Setup) and sql/supabase_chatbot_followups.sql (the ChatbotFollowUps
// queue + detection columns). This file only ever REACTS to an inbound Messenger message; actually
// sending a follow-up is supabase/functions/chatbot-followup-dispatcher's job, run on a pg_cron
// timer. This file's role in the feature is: (1) track LastCustomerMessageAtUtc/LastBotMessageAtUtc/
// AbandonedNudgeSentAtUtc/EscalatedAtUtc so the dispatcher can detect an abandoned or escalated
// conversation, and (2) the schedule_follow_up tool, letting the bot itself queue a follow-up the
// moment it promises a customer a callback.
//
// Always acks Facebook with 200 once the request's signature checks out, even if something later
// fails internally (logged via console.error) - a non-200 makes Facebook redeliver the same event,
// and a retry storm on a genuinely broken message is worse than silently dropping it. Dedup on
// Facebook's message id (ChatbotMessages.FacebookMessageId's unique index) covers the redelivery
// case for messages that DID succeed the first time.

import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2';
import Anthropic from 'npm:@anthropic-ai/sdk@0.124.0';

const DEFAULT_MODEL = 'claude-sonnet-5';
const DEFAULT_GRAPH_VERSION = 'v21.0';
const MAX_TOOL_ITERATIONS = 5;
const MAX_TOKENS = 2048;
const HISTORY_LIMIT = 20;
const RATE_LIMIT_WINDOW_MINUTES = 5;
const RATE_LIMIT_MAX_MESSAGES = 15;
// Small pause before sending the reply so the bot doesn't feel instant/robotic, and so replies
// aren't fired at Meta back-to-back-to-back during a burst of customer messages.
const REPLY_DELAY_MS = 2000;
// Both store branches (Amaya/GMA) are in the Philippines - hardcoded rather than a settings-page
// field since there's no multi-timezone need today; change this constant if that ever changes.
const STORE_TIMEZONE = 'Asia/Manila';

interface FacebookWebhookBody {
  entry?: Array<{
    messaging?: Array<{
      sender?: { id: string };
      recipient?: { id: string };
      message?: { mid: string; text?: string; is_echo?: boolean };
    }>;
  }>;
}

// ============================================================================
// BEGIN: ported verbatim from docs/WebAquariumCalculator/custom-aquarium-calculator.js
// (calculateCustomAquarium + everything it calls, minus the standalone Stand/Filtration/Sticker
// builders and sticker helpers - out of scope for compute_aquarium_quote). Source of truth is
// that file - if its pricing logic changes, re-sync this block so the bot's quotes keep matching
// the website's. Deliberately NOT "fixed" to also correct buildGlassPriceLookup's field-name
// mismatch (it reads row.uom/row.units, which public_get_glass_pricing() never returns, so it
// always falls through to the hardcoded DEFAULT_GLASS_PRICES below) - faithfully reproducing that
// quirk keeps bot quotes consistent with what customers see on order-now.html today.
// ============================================================================

const DEFAULT_GLASS_PRICES: Record<string, number> = { '3mm': 85, '6mm': 185, '10mm': 290, '12mm': 350 };
const TUBULAR_RETAIL_RATES: Record<string, number> = { '1x1': 46, '1.5x1.5': 52, '2x2': 95 };

function round2(value: number): number {
  return Math.round((Number(value) || 0) * 100) / 100;
}

function roundNearest10(value: number): number {
  return Math.round((Number(value) || 0) / 10) * 10;
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
  sumpHolder: boolean;
  sumpWidth: number;
  unit: string;
  heightInches: number;
  notice: TubularSafetyResult['notice'];
}

function calculateStand(
  lengthInches: number,
  widthInches: number,
  glassThickness: string,
  standOptions: StandOptions | undefined,
  defaultUnit: string,
  tubularPricingSetupRows: Array<Record<string, unknown>> | undefined
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

  return {
    enabled: true,
    price: computed.price,
    breakdown: computed.breakdown,
    totalFeetConsumed: computed.totalFeetConsumed,
    layers,
    tubular,
    stainless,
    cabinet,
    sumpHolder,
    sumpWidth: round2(sumpWidthInches),
    unit: standUnit,
    heightInches: round2(standHeightInches),
    notice: tubularSafety.notice
  };
}

function buildGlassPriceLookup(rows: Array<Record<string, unknown>> | null | undefined, preferredUom: string): Record<string, number> {
  const lookup: Record<string, number> = Object.assign({}, DEFAULT_GLASS_PRICES);
  const wantedUom = String(preferredUom || 'MM').trim().toLowerCase();
  const items = Array.isArray(rows) ? rows : [];

  for (const row of items) {
    const rowUom = String((row as any).uom ?? (row as any).UOM ?? '').trim().toLowerCase();
    if (rowUom !== wantedUom) {
      continue;
    }

    const units = String((row as any).units ?? (row as any).Units ?? '').trim();
    const price = Number((row as any).pricePerSqFt ?? (row as any).PricePerSqFt ?? 0);
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

function validateGlassSafety(
  lengthInches: number,
  widthInches: number,
  heightInches: number,
  glassThickness: string,
  isTempered: boolean,
  isRimless: boolean
): GlassSafetyResult {
  const glass = normalizeGlass(glassThickness);
  const gallons = cubicInchesToGallons(lengthInches * widthInches * heightInches);
  const glassMm = extractGlassMm(glass);

  if (glass === '3mm' && lengthInches > 24) {
    return { isSafe: false, message: 'Length exceeds 24 inches for 3mm glass. Auto-upgrading glass to 6mm.', autoChangeTo: '6mm' };
  }

  if ((widthInches >= 36 || heightInches >= 36) && !isTempered) {
    return { isSafe: false, message: 'Width or height is 36 inches or more. Tempered glass is mandatory for this custom aquarium.', autoChangeTo: null };
  }

  if (glass === '3mm') {
    if (gallons > 15 && (lengthInches > 24 || widthInches > 12 || heightInches > 12)) {
      return { isSafe: false, message: 'Tank exceeds safe limits for 3mm glass. Please select 10mm or 12mm glass.', autoChangeTo: null };
    }
  }

  if (lengthInches > 60 || widthInches > 20 || heightInches > 20) {
    if (glass === '3mm' || (glass === '6mm' && gallons > 50)) {
      return { isSafe: false, message: 'Tank dimensions exceed safe limits for selected glass. Please choose 10mm or 12mm glass.', autoChangeTo: null };
    }
  }

  if (glass === '10mm') {
    if (gallons > 180 || lengthInches > 72 || widthInches > 30 || heightInches > 30) {
      return { isSafe: false, message: 'Tank volume or dimensions require 12mm glass. Please select 12mm glass to calculate.', autoChangeTo: null };
    }
  }

  if (isRimless) {
    if (gallons >= 10 && gallons <= 15 && glassMm < 6) {
      return { isSafe: false, message: 'Rimless 10-15G tanks require minimum 6mm glass.', autoChangeTo: null };
    }
    if (gallons >= 30 && gallons <= 100 && glassMm < 10) {
      return { isSafe: false, message: 'Rimless 30-100G tanks require minimum 10mm glass.', autoChangeTo: null };
    }
  }

  return { isSafe: true, message: 'OK', autoChangeTo: null };
}

function getRequiredGlassFromMessage(message: string): string | null {
  const text = String(message || '').toLowerCase();
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
  stand?: StandOptions;
  filtrationSump?: { enabled?: boolean };
  length: number;
  width: number;
  height: number;
  glassPricingSetupRows?: Array<Record<string, unknown>>;
  glassPricingUom?: string;
  tubularPricingSetupRows?: Array<Record<string, unknown>>;
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
  const hasStand = Boolean(options.stand && options.stand.enabled);
  const hasFiltrationSump = Boolean((options.filtrationSump && options.filtrationSump.enabled) || optionType.toLowerCase() === 'complete setup');
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
      autoChangeTo: getRequiredGlassFromMessage(safety.message) || safety.autoChangeTo || null,
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
  const standCalculation = calculateStand(lengthInches, widthInches, glass, options.stand, unit, options.tubularPricingSetupRows);
  const components: Record<string, number> = {
    glass: 0,
    highStrip: 0,
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

  let calculatedPrice = glassAreaSqFt * finalPricePerSqFt;
  components.glass = round2(calculatedPrice);

  if (hasHighStrip) {
    const highStripLinearFeet = ((lengthInches + widthInches) * 2) / 12;
    components.highStrip = round2(highStripLinearFeet * 90);
    calculatedPrice += components.highStrip;
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

const TOOLS: Anthropic.Tool[] = [
  {
    name: 'search_items',
    description:
      'Search the store\'s product catalog by name, keyword, brand, or SKU. Use this whenever a customer asks if you carry something, or asks about the price/stock of a specific product.',
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
    name: 'list_items_in_category',
    description:
      'List active items in one specific category, with price and stock. Use after list_categories, or when the customer names a category directly (e.g. "what filters do you have").',
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
      'Look up the status of a previously placed order by its order number. Works for either a portal Automated Order (format AO-xxxxx, e.g. from a custom quote) or a regular Online Order placed through Pancake/checkout - just pass whatever number the customer gives you, this tries both. An Online Order result also includes a receiptUrl link to a printable/PDF-saveable receipt page, for when the customer specifically asks for a receipt rather than just a status update. Never call this without an order number - if the customer only says "my order", ask them for the order number first.',
    input_schema: {
      type: 'object',
      properties: {
        order_no: { type: 'string', description: 'The order number, e.g. AO-00001 or a Pancake Online Order ID.' }
      },
      required: ['order_no']
    }
  },
  {
    name: 'escalate_to_staff',
    description:
      'Notify store staff that this conversation needs a human follow-up. Use for refund requests, complaints, damaged/wrong items, price negotiation, or when the customer explicitly asks for a person.',
    input_schema: {
      type: 'object',
      properties: {
        reason: { type: 'string', description: 'Brief summary of why this needs staff attention.' }
      },
      required: ['reason']
    }
  },
  {
    name: 'compute_aquarium_quote',
    description:
      'Compute a real price quote for a custom aquarium tank. Ask for length/width/height and glass thickness at minimum; ask about a matching stand only if the customer mentions wanting one. This gives an ESTIMATE - always tell the customer staff will confirm the final price. Never state a price for a custom tank without calling this tool first.',
    input_schema: {
      type: 'object',
      properties: {
        length: { type: 'number', description: 'Tank length.' },
        width: { type: 'number', description: 'Tank width.' },
        height: { type: 'number', description: 'Tank height.' },
        unit: { type: 'string', enum: ['Inches', 'cm', 'mm', 'ft'], description: 'Defaults to Inches if not specified.' },
        glass_thickness: { type: 'string', enum: ['3mm', '6mm', '10mm', '12mm'], description: 'Defaults to 6mm if not specified.' },
        tempered_glass: { type: 'boolean' },
        low_iron: { type: 'boolean' },
        rimless: { type: 'boolean' },
        high_strip: { type: 'boolean', description: 'An extra glass strip along the top rim.' },
        add_stand: { type: 'boolean', description: 'Set true only if the customer wants a matching stand included.' },
        stand_layers: { type: 'integer', description: 'Number of stand shelves/layers, minimum 2. Only used when add_stand is true.' },
        stand_tubular: { type: 'string', enum: ['1x1', '1.5x1.5', '2x2'], description: 'Stand frame tubular size. Only used when add_stand is true.' },
        stand_stainless: { type: 'boolean', description: 'Stainless steel stand frame instead of regular. Only used when add_stand is true.' }
      },
      required: ['length', 'width', 'height']
    }
  },
  {
    name: 'compute_delivery_quote',
    description:
      'Estimate the delivery fee from a store branch to a customer address. Ask which branch (Amaya or GMA) if not already known, and get the full delivery address. This gives an ESTIMATE only - the final fee is confirmed by staff. Never state a delivery fee without calling this tool first.',
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
  }
];

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
}

async function hmacSha256Hex(key: string, message: string): Promise<string> {
  const encoder = new TextEncoder();
  const cryptoKey = await crypto.subtle.importKey('raw', encoder.encode(key), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const signatureBuffer = await crypto.subtle.sign('HMAC', cryptoKey, encoder.encode(message));
  return Array.from(new Uint8Array(signatureBuffer))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

// Facebook's signature is a fixed-length "sha256=<64 hex chars>" string in both the header and our
// computed value, so a length check before the constant-time loop leaks nothing an attacker doesn't
// already know from the wire format.
function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let mismatch = 0;
  for (let i = 0; i < a.length; i++) {
    mismatch |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return mismatch === 0;
}

function handleGet(req: Request): Response {
  const url = new URL(req.url);
  const mode = url.searchParams.get('hub.mode');
  const token = url.searchParams.get('hub.verify_token');
  const challenge = url.searchParams.get('hub.challenge');
  const verifyToken = Deno.env.get('FACEBOOK_VERIFY_TOKEN');

  if (mode === 'subscribe' && verifyToken && token === verifyToken) {
    // Meta expects the raw challenge value back as plain text, not JSON.
    return new Response(challenge ?? '', { status: 200 });
  }
  return new Response('Forbidden', { status: 403 });
}

// Deliberately its own uncached system block (see the call site) - it changes every request, so
// bundling it into the cached prompt-prefix block would defeat prompt caching for everything else.
function buildCurrentTimeLine(timeZone: string): string {
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

function buildSystemPrompt(
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
    'If a customer asks whether you are a bot, say plainly that you are an automated assistant, then keep helping.',
    '',
    'WHAT YOU CAN HELP WITH:',
    '- Whether a product is in stock and its price (use the search_items or list_items_in_category tools - never guess). When you tell a customer about a specific product, offer to send a photo of it ("want me to send you a photo?") - only call send_item_image after they say yes, using the item_code from that search result. Never send a photo unprompted, and never send more than one or two per exchange even if asked about several items at once - offer, then send only the one(s) they confirm.',
    '- What categories/kinds of products the store carries (use list_categories).',
    '- Store hours, delivery policy, payment methods, and pickup locations (see STORE INFO below).',
    '- The status of a previously placed order, ONLY when the customer gives you their order number. This could be a portal Automated Order (format like AO-00001) or a regular Online Order/Pancake order number - you don\'t need to know which, get_order_status checks both. If they ask about "my order" without a number, ask them for it first - never call get_order_status without one. For an Online Order result, give a full rundown: the items ordered with quantity, the total amount, the balance (if more than zero), the status (Confirmed/Printed/To Ship/Shipped/Cancelled), and which branch/warehouse it was ordered from; for an Automated Order result, share its Pancake sync status plainly (e.g. still being processed vs. confirmed). There is no way to send an actual receipt image/file - if the customer specifically asks for a receipt or proof of order (not just the status), share the receiptUrl link from an Online Order result instead and say it opens their receipt (printable/saveable as PDF from there). Don\'t share receiptUrl unless they actually ask for a receipt.',
    '- Custom aquarium and/or stand price quotes: ask for length/width/height (and glass thickness, if the aquarium itself is being quoted) before calling compute_aquarium_quote. Before calling the tool, restate back what you understood - dimensions, unit, and whether this is a stand only (customer already has the tank) or the aquarium plus a matching stand - and get the customer to confirm that\'s correct. Use exactly the numbers they confirmed; never guess, round, or adjust their dimensions yourself, and don\'t re-run the tool again later in the conversation unless a dimension or spec actually changes. If the customer only wants a stand for a tank they already own, only quote the stand price (components.stand / the stand section of the result) - don\'t mention or total in the aquarium glass price. When you do get a result, give a full itemized summary, not just a total: gallons, glass thickness actually used, whether tempered/rimless, the aquarium price, the stand price and its spec (layers/tubular/stainless) if a stand was included, and the grand total (or just the stand price and spec, for a stand-only quote). Always tell the customer this is an estimate and staff will confirm the final price. If the tool result includes a safetyNotice or standNotice, explain it plainly (e.g. "for that size we need to use 6mm glass instead of 3mm for safety") so the customer understands why the spec or price changed from what they asked. Share the drawing link(s) exactly as given (word for word, never alter or retype the URL): for an aquarium quote (with or without a stand), share aquariumDrawingUrl; for a stand-only quote (customer already owns the tank), share only standDrawingUrl - skip aquariumDrawingUrl since they don\'t need a picture of a tank they didn\'t ask about.',
    '- Delivery fee estimates: ask which branch (Amaya or GMA) and the full delivery address, then use compute_delivery_quote. Always tell the customer this is an estimate and staff will confirm the final fee.',
    '- Where the delivery driver currently is (TEST feature): if a customer asks where the driver is, call get_driver_location right away and share the liveTrackingUrl link directly in your reply (mention that the page updates live as the driver moves), plus how many minutes since the last GPS update. Unlike order status, do NOT ask for an order number first - this tool is not matched to any order/customer yet, it just reports whichever driver is currently tracking, for testing that GPS reporting works.',
    '- General conversation about aquariums, fish, and pets, related to what the store sells.',
    '',
    'AQUARIUM & STAND SAFETY RULES - understand these so you can explain and apply them confidently in conversation, not just react after the fact. compute_aquarium_quote always does the actual math and is the source of truth for exact numbers - never calculate or predict a safety change yourself, but you should recognize when one is likely so you can set expectations before quoting:',
    '- Glass gets thicker, or tempered, automatically as size/volume grows: 3mm glass only works up to 24 inches in length and small volumes; anything bigger needs 6mm, 10mm, or 12mm. Any tank with width or height of 36 inches or more always requires tempered glass. Very large tanks (roughly 180+ gallons, or beyond about 72x30x30 inches) require 12mm glass.',
    '- Rimless tanks (no top/bottom frame bracing) need extra glass thickness to stay structurally safe without that frame: minimum 6mm for a 10-15 gallon tank, minimum 10mm for a 30-100 gallon tank.',
    '- Stand frames get a thicker tubular size automatically as the load/span grows: 10mm+ glass always needs a 2x2 stand frame; a stand over 30 inches long needs at least 1 1/2 x 1 1/2 tubular; a stand 49+ inches long AND 18+ inches wide always needs 2x2, no exceptions.',
    '- These are structural safety requirements, not preferences - never agree to skip, downgrade, or "just risk it" even if the customer insists, says a smaller tank held up fine before, or asks you to quote the unsafe spec anyway. Politely hold the line, explain it protects them from a cracked tank or a collapsed stand, and note that the quote you give already reflects the safe spec.',
    '- If you can tell upfront from the dimensions the customer gave that a rule above will apply (e.g. they want a 40 inch wide tank in 3mm), mention it before or while quoting rather than only after compute_aquarium_quote returns a safetyNotice/standNotice - so it never feels like a surprise price change.',
    '- When a result DOES include a safetyNotice or standNotice, always explain it in your own plain, reassuring words (e.g. "since that\'s over 36 inches wide, we use tempered glass there for safety - already included in the price above") - never paste the raw notice text verbatim, and never let it read like an error message.',
    '',
    'WHAT IS OUT OF SCOPE:',
    '- Anything unrelated to the store (general trivia, coding help, medical/veterinary diagnosis). Politely decline and steer back to how you can help with the store.',
    '',
    'WHEN TO ESCALATE TO STAFF:',
    '- Refund requests, complaints, damaged/wrong items, price negotiation, or the customer explicitly asking for a human.',
    '- Call the escalate_to_staff tool, then let the customer know a team member will follow up with them in this same conversation.',
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
    '- Never invent stock, price, order, aquarium quote, or delivery fee information - always use the tools.',
    '- If a tool returns nothing, say so plainly rather than guessing.',
    '- Speak in plain product names only - never mention internal item codes, category codes, or cost/wholesale pricing.',
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
      '(Follow these alongside everything above - they never override the grounding rules or the escalation rules.)'
    );
  }

  return lines.join('\n');
}

async function computeAquariumQuote(supabase: SupabaseClient, input: Record<string, unknown>): Promise<Record<string, unknown>> {
  const [{ data: glassRows }, { data: tubularRows }] = await Promise.all([
    supabase.rpc('public_get_glass_pricing'),
    supabase.rpc('public_get_tubular_pricing')
  ]);

  const addStand = Boolean(input.add_stand);

  const result = calculateCustomAquarium({
    unit: (input.unit as string) || 'Inches',
    length: Number(input.length),
    width: Number(input.width),
    height: Number(input.height),
    glassThickness: (input.glass_thickness as string) || '6mm',
    temperedGlass: Boolean(input.tempered_glass),
    lowIron: Boolean(input.low_iron),
    rimless: Boolean(input.rimless),
    highStrip: Boolean(input.high_strip),
    option: 'Aquarium only',
    stand: addStand
      ? {
          enabled: true,
          layers: Number(input.stand_layers) || 2,
          tubular: (input.stand_tubular as string) || '1x1',
          stainless: Boolean(input.stand_stainless)
        }
      : { enabled: false },
    glassPricingSetupRows: glassRows ?? [],
    glassPricingUom: 'MM',
    tubularPricingSetupRows: tubularRows ?? []
  });

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
    if (stand) {
      aquariumParams.set('standEnabled', '1');
      aquariumParams.set('standLayers', String(stand.layers));
      aquariumParams.set('standTubular', String(stand.tubular));
      if (stand.stainless) aquariumParams.set('standStainless', '1');
    }
    result.aquariumDrawingUrl = `https://rspetstop.com/WebAquariumCalculator/index.html?${aquariumParams.toString()}`;
  }

  return result;
}

async function computeDeliveryQuote(supabase: SupabaseClient, input: Record<string, unknown>): Promise<Record<string, unknown>> {
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

// Backs the get_driver_location tool - a first pass at letting the chatbot answer "where is the
// driver?" using the live GPS feed from driver-app/ (see supabase_driver_locations_table.sql).
// Deliberately NOT tied to a specific order/customer yet (see that tool's description) - just
// reports whichever driver(s) are currently tracking, per direct request to test this capability
// before wiring it to real order/delivery-stop matching.
async function computeDriverLocation(supabase: SupabaseClient, input: Record<string, unknown>): Promise<Record<string, unknown>> {
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

async function executeTool(
  supabase: SupabaseClient,
  psid: string,
  name: string,
  input: Record<string, unknown>,
  followUpSettings: Record<string, unknown> | null
): Promise<string> {
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
        return JSON.stringify({ orderType: 'Automated Order', ...automatedData[0] });
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
        const { data: lineData, error: lineError } = await supabase.rpc('public_get_online_order_lines', { p_order_id: orderNo });
        if (lineError) return `Lookup failed: ${lineError.message}`;
        // No image/PDF rendering exists in this stack (see supabase_chatbot_online_order_receipt.sql
        // header) - the bot shares a link to a public, no-login receipt page instead, only when the
        // customer actually asks for a receipt/proof of order, not on every status check.
        const receiptUrl = `https://rspetstop.com/online-order-receipt.html?order=${encodeURIComponent(String(onlineData[0].order_id))}`;
        return JSON.stringify({ orderType: 'Online Order', ...onlineData[0], items: lineData ?? [], receiptUrl });
      }

      return 'No order found with that number.';
    }
    case 'escalate_to_staff': {
      const reason = String(input.reason ?? 'Customer requested human assistance.');
      await supabase
        .from('ChatbotConversations')
        .update({ Status: 'Escalated', EscalatedAtUtc: new Date().toISOString(), EscalationCheckinSentAtUtc: null })
        .eq('Psid', psid);
      await supabase.rpc('_telegram_send_message', { p_text: `Chatbot escalation (PSID ${psid}): ${reason}` });
      return 'Staff have been notified and will follow up with the customer directly in this conversation.';
    }
    case 'send_item_image': {
      const itemCode = String(input.item_code ?? '').trim();
      if (!itemCode) return 'No item code provided.';

      const { data: imagesRaw, error } = await supabase.rpc('public_get_item_image', { p_code: itemCode });
      if (error) return `Lookup failed: ${error.message}`;

      const imageUrl = imagesRaw ? String(imagesRaw).split(',')[0].trim() : '';
      if (!imageUrl) return 'No photo is on file for that item - let the customer know a photo isn\'t available yet.';

      const pageAccessToken = Deno.env.get('FACEBOOK_PAGE_ACCESS_TOKEN');
      const graphVersion = Deno.env.get('FACEBOOK_GRAPH_API_VERSION') || DEFAULT_GRAPH_VERSION;
      if (!pageAccessToken) return 'Photo sending is not configured right now.';

      const sent = await sendMessengerImage(psid, imageUrl, pageAccessToken, graphVersion);
      return sent ? 'Photo sent to the customer.' : 'Sending the photo failed - let the customer know and continue without it.';
    }
    case 'compute_aquarium_quote':
      return JSON.stringify(await computeAquariumQuote(supabase, input));
    case 'compute_delivery_quote':
      return JSON.stringify(await computeDeliveryQuote(supabase, input));
    case 'get_driver_location':
      return JSON.stringify(await computeDriverLocation(supabase, input));
    case 'schedule_follow_up': {
      if (!followUpSettings?.CommittedEnabled) {
        return 'Follow-up scheduling is turned off in the store settings right now - do not promise a callback. Let the customer know a team member will follow up if needed, or just continue helping them now.';
      }
      const hours = Math.min(168, Math.max(1, Number(input.hours_from_now) || 24));
      const reason = String(input.reason ?? 'Follow up with the customer as promised.').slice(0, 1000);
      const dueAtUtc = new Date(Date.now() + hours * 60 * 60 * 1000).toISOString();
      const { error } = await supabase
        .from('ChatbotFollowUps')
        .insert({ Psid: psid, FollowUpType: 'Committed', DueAtUtc: dueAtUtc, Reason: reason, Status: 'Pending' });
      if (error) return `Could not schedule the follow-up: ${error.message}`;
      return `Follow-up scheduled for about ${hours} hour(s) from now.`;
    }
    default:
      return `Unknown tool: ${name}`;
  }
}

async function sendMessengerReply(psid: string, text: string, pageAccessToken: string, graphVersion: string): Promise<void> {
  const url = `https://graph.facebook.com/${graphVersion}/me/messages?access_token=${pageAccessToken}`;
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    // messaging_type RESPONSE is correct here - this always replies within the standard 24h window
    // to a customer-initiated message, so no message tag is needed.
    body: JSON.stringify({ recipient: { id: psid }, message: { text }, messaging_type: 'RESPONSE' })
  });
  if (!res.ok) {
    console.error(`Messenger Send API failed (${res.status}): ${await res.text()}`);
  }
}

// Backs the send_item_image tool - sent as its own Messenger message (Facebook has no "text with
// inline image" concept), immediately when the tool runs rather than queued alongside the bot's
// text reply. Returns false on failure so executeTool can tell Claude the send didn't actually
// work, instead of the model wrongly assuring the customer a photo is on its way.
async function sendMessengerImage(psid: string, imageUrl: string, pageAccessToken: string, graphVersion: string): Promise<boolean> {
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

async function isRateLimited(supabase: SupabaseClient, psid: string): Promise<boolean> {
  const windowStart = new Date(Date.now() - RATE_LIMIT_WINDOW_MINUTES * 60 * 1000).toISOString();
  const { count } = await supabase
    .from('ChatbotMessages')
    .select('Id', { count: 'exact', head: true })
    .eq('Psid', psid)
    .eq('Role', 'user')
    .gte('CreatedAtUtc', windowStart);
  return (count ?? 0) >= RATE_LIMIT_MAX_MESSAGES;
}

async function processMessage(
  supabase: SupabaseClient,
  anthropic: Anthropic,
  model: string,
  pageAccessToken: string,
  graphVersion: string,
  pageId: string,
  psid: string,
  text: string,
  mid: string
): Promise<void> {
  // Insert-if-missing only - LastMessageAtUtc/Status are updated below, never overwritten here.
  await supabase.from('ChatbotConversations').upsert({ Psid: psid, PageId: pageId }, { onConflict: 'Psid', ignoreDuplicates: true });

  const { error: insertErr } = await supabase
    .from('ChatbotMessages')
    .insert({ Psid: psid, Role: 'user', Content: text, FacebookMessageId: mid });
  if (insertErr) {
    if (insertErr.code === '23505') return; // Facebook redelivered a message we already processed.
    console.error('Failed to record inbound chatbot message:', insertErr.message);
  }

  // A fresh inbound message means any prior idle stretch is over - clears AbandonedNudgeSentAtUtc
  // so chatbot-followup-dispatcher can detect the *next* idle stretch, if there is one.
  await supabase
    .from('ChatbotConversations')
    .update({ LastCustomerMessageAtUtc: new Date().toISOString(), AbandonedNudgeSentAtUtc: null })
    .eq('Psid', psid);

  // Staff-controlled pause (docs/ai-bot-messages.html, set via admin_set_chatbot_conversation_paused
  // - see supabase_chatbot_conversations_admin_inbox.sql) - independent of Status/Escalated, which
  // never silences the bot on its own per direct confirmation. The message above is still recorded
  // and LastCustomerMessageAtUtc still updates, so a paused conversation stays visible/current in
  // the inbox - only the auto-reply itself is skipped, so staff can answer manually on Messenger.
  const { data: pauseCheck } = await supabase.from('ChatbotConversations').select('IsPaused').eq('Psid', psid).maybeSingle();
  if (pauseCheck?.IsPaused) return;

  if (await isRateLimited(supabase, psid)) {
    await sendMessengerReply(psid, "You're sending messages a bit fast - give me a moment to catch up!", pageAccessToken, graphVersion);
    return;
  }

  const { data: historyRows } = await supabase
    .from('ChatbotMessages')
    .select('Role, Content')
    .eq('Psid', psid)
    .order('CreatedAtUtc', { ascending: false })
    .limit(HISTORY_LIMIT);

  // 'staff' rows (a human's manual reply from docs/gma-conversations.html - see
  // supabase_chatbot_staff_reply.sql) map to 'assistant' here - Claude's Messages API only accepts
  // 'user'/'assistant' roles, and a staff reply plays the same conversational turn as a bot reply
  // from the model's perspective. The DB keeps the real 'staff' value (for the inbox UI's own
  // labeling/coloring) - only this Claude-facing mapping collapses the two.
  const messages: Anthropic.MessageParam[] = (historyRows ?? [])
    .reverse()
    .map((row: { Role: string; Content: string }) => ({ role: row.Role === 'user' ? 'user' : 'assistant', content: row.Content }));

  const [{ data: storeInfo }, { data: companyInfo }, { data: aiSettings }, { data: followUpSettings }] = await Promise.all([
    supabase.from('ChatbotStoreInfo').select('*').eq('Id', 1).maybeSingle(),
    supabase.from('CompanyInfo').select('*').eq('Id', 1).maybeSingle(),
    supabase.from('ChatbotAiSettings').select('*').eq('Id', 1).maybeSingle(),
    supabase.from('ChatbotFollowUpSettings').select('*').eq('Id', 1).maybeSingle()
  ]);

  // Not type-annotated as Anthropic.TextBlockParam[] - structural typing against
  // MessageCreateParams['system'] is enough, and avoids depending on an unverified type name.
  // Two blocks: the large static persona/rules/store-info text is cached (changes only when
  // settings are edited), while the current date/time is appended uncached after it since it's
  // different on every request - keeping it out of the cached block preserves the cache hit rate
  // for everything else.
  const systemBlocks = [
    { type: 'text' as const, text: buildSystemPrompt(storeInfo, companyInfo, aiSettings, followUpSettings), cache_control: { type: 'ephemeral' as const } },
    { type: 'text' as const, text: buildCurrentTimeLine(STORE_TIMEZONE) }
  ];

  let finalText = "Sorry, I'm having trouble responding right now - a team member will follow up with you shortly.";

  // AiSettings.AiModel (portal-editable, see ai-bot-setup.html) overrides the env/default model
  // when set, so the store owner can switch models without a code deploy.
  const effectiveModel = (aiSettings?.AiModel as string | undefined)?.trim() || model;

  for (let i = 0; i < MAX_TOOL_ITERATIONS; i++) {
    const response = await anthropic.messages.create({
      model: effectiveModel,
      max_tokens: MAX_TOKENS,
      system: systemBlocks,
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
      const result = await executeTool(supabase, psid, tool.name, tool.input as Record<string, unknown>, followUpSettings);
      toolResults.push({ type: 'tool_result', tool_use_id: tool.id, content: result });
    }
    messages.push({ role: 'user', content: toolResults });
  }

  await supabase.from('ChatbotMessages').insert({ Psid: psid, Role: 'assistant', Content: finalText });
  await supabase
    .from('ChatbotConversations')
    .update({ LastMessageAtUtc: new Date().toISOString(), LastBotMessageAtUtc: new Date().toISOString() })
    .eq('Psid', psid);

  await new Promise((resolve) => setTimeout(resolve, REPLY_DELAY_MS));
  await sendMessengerReply(psid, finalText, pageAccessToken, graphVersion);
}

async function handlePost(req: Request): Promise<Response> {
  const appSecret = Deno.env.get('FACEBOOK_APP_SECRET');
  const pageAccessToken = Deno.env.get('FACEBOOK_PAGE_ACCESS_TOKEN');
  const anthropicApiKey = Deno.env.get('ANTHROPIC_API_KEY');
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const model = Deno.env.get('CLAUDE_MODEL') || DEFAULT_MODEL;
  const graphVersion = Deno.env.get('FACEBOOK_GRAPH_API_VERSION') || DEFAULT_GRAPH_VERSION;

  if (!appSecret || !pageAccessToken || !anthropicApiKey || !supabaseUrl || !serviceRoleKey) {
    console.error('facebook-messenger-webhook is missing one or more required secrets.');
    // Still ack Facebook - a misconfigured server is nothing a retry will fix.
    return jsonResponse({ received: true });
  }

  // Must read the body as text (for signature verification) BEFORE any JSON parsing.
  const rawBody = await req.text();
  const signatureHeader = req.headers.get('x-hub-signature-256') || '';
  const expectedSignature = 'sha256=' + (await hmacSha256Hex(appSecret, rawBody));
  if (!constantTimeEqual(signatureHeader, expectedSignature)) {
    return new Response('Forbidden', { status: 403 });
  }

  let body: FacebookWebhookBody;
  try {
    body = JSON.parse(rawBody);
  } catch {
    return jsonResponse({ received: true });
  }

  try {
    const supabase = createClient(supabaseUrl, serviceRoleKey);
    const anthropic = new Anthropic({ apiKey: anthropicApiKey });

    for (const entry of body.entry ?? []) {
      for (const evt of entry.messaging ?? []) {
        if (evt.message?.is_echo) continue; // the page's own message, echoed back - skip to avoid a reply loop
        const text = evt.message?.text;
        const psid = evt.sender?.id;
        const pageId = evt.recipient?.id;
        const mid = evt.message?.mid;
        if (!text || !psid || !pageId || !mid) continue; // read receipts, postbacks, attachments - out of v1 scope

        try {
          await processMessage(supabase, anthropic, model, pageAccessToken, graphVersion, pageId, psid, text, mid);
        } catch (err) {
          console.error('Error processing Messenger event:', err instanceof Error ? err.message : err);
        }
      }
    }
  } catch (err) {
    console.error('Unhandled error in facebook-messenger-webhook:', err instanceof Error ? err.message : err);
  }

  return jsonResponse({ received: true });
}

Deno.serve(async (req) => {
  if (req.method === 'GET') return handleGet(req);
  if (req.method === 'POST') return await handlePost(req);
  return jsonResponse({ error: 'Use GET (webhook verification) or POST (webhook events).' }, 405);
});
