// Repair Calculator page logic - a pricing calculator (not a job tracker), per direct scope
// decision "A repair pricing calculator... like Custom Stand/Aquarium Calculator". Two repair
// types:
//   - Panel Replacement: per "just let the user input the actual aquarium dimension then we can
//     work from that dimension" - staff enter the aquarium's overall Length/Width/Height ONCE,
//     then just check off which panel(s) are damaged (Bottom/Front/Back/Left/Right); each
//     checked panel's own area is derived from those three numbers using the SAME convention
//     getGlassAreaSqFt (custom-aquarium-calculator.js) already uses for a full build - Bottom =
//     Length x Width, Front/Back = Length x Height, Left/Right = Width x Height - rather than
//     asking staff to re-measure/re-enter each panel's size separately. Each panel's area x the
//     live glass rate (public_get_glass_pricing, via CustomAquariumCalculator.
//     buildGlassPriceLookup - the shared engine, not a re-implementation) + a labor markup % from
//     RepairPricingSetup, summed across every checked panel into one total.
//   - Resealing / Leak Repair: a flat fee from that same settings table (size doesn't change the
//     price), but per "let the user fill in the dimension of the tank to reseal" it still uses the
//     same shared Length/Width/Height fields as Panel Replacement - purely for the record/spec
//     text (shows the tank's size and estimated gallons alongside the flat fee), not to compute it.
// Client-side pricing only - nothing here is saved to the database, matching the other calculators
// (Custom Stand, Aquarium Calculator, Stickers). Alice (the AI bot) does NOT know about this
// feature yet - out of scope per direct instruction to build the system feature first, and teach
// her about it as a separate follow-up.

const PANEL_LOCATIONS = ['Bottom', 'Front', 'Back', 'Left', 'Right'];

let repairType = 'panel';
let repairGlassLookup = null; // built once from live GlassPricingSetup rows, null while still loading
let repairPricingSetup = { panelReplacementMarkupPercent: 20, resealingFlatFee: 500 }; // defaults until loaded

function repairFormatCurrency(value) {
  return '₱' + (Number(value) || 0).toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

async function repairLoadPricingSetup() {
  const errorEl = document.getElementById('repairError');
  errorEl.classList.add('hidden');

  try {
    const [{ data: glassRows }, { data: setupRows }] = await Promise.all([
      supabaseClient.rpc('public_get_glass_pricing'),
      supabaseClient.rpc('public_get_repair_pricing_setup')
    ]);

    repairGlassLookup = window.CustomAquariumCalculator.buildGlassPriceLookup(glassRows || [], 'MM');

    const setup = Array.isArray(setupRows) ? setupRows[0] : setupRows;
    if (setup) {
      repairPricingSetup = {
        panelReplacementMarkupPercent: Number(setup.panel_replacement_markup_percent) || 20,
        resealingFlatFee: Number(setup.resealing_flat_fee) || 500
      };
    }
  } catch (err) {
    errorEl.textContent = 'Could not load live pricing - using defaults. ' + (err instanceof Error ? err.message : '');
    errorEl.classList.remove('hidden');
    repairGlassLookup = window.CustomAquariumCalculator.buildGlassPriceLookup([], 'MM');
  }
  document.getElementById('repairMarkupNote').textContent = `Includes a ${repairPricingSetup.panelReplacementMarkupPercent}% labor markup (configurable in Pricing Setup).`;
  repairRecalculate();
}

function repairSetType(type) {
  repairType = type;
  document.getElementById('repairTabPanel').classList.toggle('active', type === 'panel');
  document.getElementById('repairTabReseal').classList.toggle('active', type === 'reseal');
  document.getElementById('repairPanelFields').classList.toggle('hidden', type !== 'panel');
  document.getElementById('repairResealFields').classList.toggle('hidden', type !== 'reseal');
  document.getElementById('repairGlassThicknessRow').classList.toggle('hidden', type !== 'panel');
  repairRecalculate();
}

// (L x W x H) / 231 - same cubic-inches-to-gallons formula as custom-aquarium-calculator.js.
function repairEstimateGallons(aquarium) {
  return (aquarium.length * aquarium.width * aquarium.height) / 231;
}

function repairRenderSummary(rows, total) {
  const container = document.getElementById('repairSummaryRows');
  container.innerHTML = rows.map((r) => `
    <div class="repair-summary-row"><span>${r.label}</span><span>${r.value}</span></div>
  `).join('') + `
    <div class="repair-summary-row repair-summary-total"><span>Total</span><span id="repairSummaryTotalValue">${repairFormatCurrency(total)}</span></div>
  `;
}

function repairCheckedPanels() {
  return PANEL_LOCATIONS.filter((panel) => document.querySelector(`.repair-panel-checkbox[data-panel="${panel}"]`).checked);
}

function repairAquariumDims() {
  const length = Math.max(0, Number(document.getElementById('repairAquariumLength').value) || 0);
  const width = Math.max(0, Number(document.getElementById('repairAquariumWidth').value) || 0);
  const height = Math.max(0, Number(document.getElementById('repairAquariumHeight').value) || 0);
  return { length, width, height };
}

// Same convention as getGlassAreaSqFt (custom-aquarium-calculator.js): Bottom = Length x Width,
// Front/Back = Length x Height, Left/Right = Width x Height.
function repairPanelDims(panel, aquarium) {
  if (panel === 'Bottom') return { width: aquarium.length, height: aquarium.width };
  if (panel === 'Front' || panel === 'Back') return { width: aquarium.length, height: aquarium.height };
  return { width: aquarium.width, height: aquarium.height }; // Left / Right
}

function repairRecalculate() {
  if (!repairGlassLookup) return; // still loading initial pricing

  if (repairType === 'panel') {
    const thickness = document.getElementById('repairGlassThickness').value;
    const glassRate = repairGlassLookup[thickness] || 0;
    const markupPercent = repairPricingSetup.panelReplacementMarkupPercent;
    const checkedPanels = repairCheckedPanels();

    if (checkedPanels.length === 0) {
      repairRenderSummary([{ label: 'No panel selected', value: 'Check at least one panel above' }], 0);
      return;
    }

    const aquarium = repairAquariumDims();
    let total = 0;
    const rows = [];

    checkedPanels.forEach((panel) => {
      const { width, height } = repairPanelDims(panel, aquarium);
      const areaSqFt = (width * height) / 144;
      const glassCost = areaSqFt * glassRate;
      const markup = glassCost * (markupPercent / 100);
      const price = glassCost + markup;
      total += price;

      rows.push({ label: `${panel}: ${width}" x ${height}" (${areaSqFt.toFixed(2)} sqft)`, value: repairFormatCurrency(price) });
    });

    repairRenderSummary(rows, total);
  } else {
    const aquarium = repairAquariumDims();
    const hasDims = aquarium.length > 0 && aquarium.width > 0 && aquarium.height > 0;
    const total = repairPricingSetup.resealingFlatFee;
    const tankLabel = hasDims
      ? `${aquarium.length}" x ${aquarium.width}" x ${aquarium.height}" (~${Math.round(repairEstimateGallons(aquarium))} gal)`
      : 'Flat fee';

    repairRenderSummary([
      { label: 'Resealing / Leak Repair', value: tankLabel }
    ], total);
  }
}

function repairBuildSpecText() {
  if (repairType === 'panel') {
    const thickness = document.getElementById('repairGlassThickness').value;
    const checkedPanels = repairCheckedPanels();
    if (checkedPanels.length === 0) return 'Repair - Panel Replacement: no panel selected';

    const aquarium = repairAquariumDims();
    const parts = checkedPanels.map((panel) => {
      const { width, height } = repairPanelDims(panel, aquarium);
      return `${panel} ${width}"x${height}"`;
    });
    return `Repair - Panel Replacement (${aquarium.length}"x${aquarium.width}"x${aquarium.height}", ${thickness}): ${parts.join(', ')}`;
  }
  const aquarium = repairAquariumDims();
  const hasDims = aquarium.length > 0 && aquarium.width > 0 && aquarium.height > 0;
  const tankPart = hasDims ? ` (${aquarium.length}"x${aquarium.width}"x${aquarium.height}", ~${Math.round(repairEstimateGallons(aquarium))} gal)` : '';
  const notes = document.getElementById('repairResealNotes').value.trim();
  return `Repair - Resealing/Leak Repair${tankPart}${notes ? ' - ' + notes : ''}`;
}

async function repairCopySummary() {
  const totalEl = document.getElementById('repairSummaryTotalValue');
  const text = `${repairBuildSpecText()}\nTotal: ${totalEl ? totalEl.textContent : ''}`;
  try {
    await navigator.clipboard.writeText(text);
    alert('Copied to clipboard.');
  } catch {
    prompt('Copy this text:', text);
  }
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  renderTopNav('Repair Calculator');

  document.getElementById('repairTabPanel').addEventListener('click', () => repairSetType('panel'));
  document.getElementById('repairTabReseal').addEventListener('click', () => repairSetType('reseal'));
  document.getElementById('repairCopyBtn').addEventListener('click', repairCopySummary);

  document.getElementById('repairGlassThickness').addEventListener('change', repairRecalculate);
  ['repairAquariumLength', 'repairAquariumWidth', 'repairAquariumHeight'].forEach((id) => {
    document.getElementById(id).addEventListener('input', repairRecalculate);
  });

  PANEL_LOCATIONS.forEach((panel) => {
    document.querySelector(`.repair-panel-checkbox[data-panel="${panel}"]`).addEventListener('change', repairRecalculate);
  });

  document.getElementById('repairResealNotes').addEventListener('input', repairRecalculate);

  await repairLoadPricingSetup();
})();
