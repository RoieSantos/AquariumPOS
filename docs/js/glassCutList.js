// Glass cut-list / nesting generator for custom aquariums.
//
// Replaces the hand-drawn cut sheet the production team draws for every 10mm/12mm order (the
// same orders the "10mm glass" / "12mm glass" badge already flags - see glassBadgeHtml() in
// onlineOrders.js and detectGlassThickness() in onlineOrderLines.js). Given the tank's outside
// dimensions and glass thickness this derives the five panels, nests them onto stock sheets as
// GUILLOTINE strips, and renders a printable diagram matching the hand-drawn convention
// (full-width horizontal strips, leftover marked "Retaso").
//
// Pure client-side maths - nothing here touches Supabase. It is deliberately kept free of DOM
// lookups so glass-cut-list.html, and later the Online Order Lines drill-down, can both call it.
(function (global) {
  'use strict';

  var MM_PER_INCH = 25.4;

  // Glass is cut by score-and-snap, not a saw, so there is no kerf to allow for the way there
  // would be with wood. A trim allowance is still exposed because stock sheets often arrive with
  // a chipped factory edge that gets trimmed off before nesting starts.
  var DEFAULT_TRIM_ALLOWANCE_INCHES = 0;

  // The shop rounds every cut to the nearest 1/4" because that is the finest graduation that can
  // actually be read off the cutting table's rule. Panels are rounded, never the stock sheet.
  var DEFAULT_ROUNDING_DENOMINATOR = 4;

  function toNumber(value) {
    var n = Number(value);
    return isFinite(n) ? n : 0;
  }

  function glassThicknessInches(glass) {
    // Accepts '10mm', '12 mm', 10, '10' - the same loose input the calculator's extractGlassMm()
    // tolerates, since these values arrive from free-text Pancake line names.
    var match = String(glass || '').match(/(\d+(?:\.\d+)?)/);
    var mm = match ? Number(match[1]) : toNumber(glass);
    return mm / MM_PER_INCH;
  }

  var UNIT_TO_INCHES = {
    'in': 1, 'inch': 1, 'inches': 1,
    'cm': 1 / 2.54,
    'ft': 12,
    'mm': 1 / MM_PER_INCH
  };

  function unitToInches(value, unit) {
    var factor = UNIT_TO_INCHES[String(unit || 'in').trim().toLowerCase()];
    return toNumber(value) * (factor || 1);
  }

  // Pulls tank dimensions + glass thickness back out of a custom aquarium order line's Note text.
  // Confirmed against a real order's Note field: "60L X 22W X 22H inches . 12MM BLACK SEALANT
  // ( paki clean po ng paglagay ng sealant) WITH RIM" - each dimension carries its own L/W/H
  // suffix rather than a plain "L x W x H" run, and the glass thickness sits on its own after the
  // dimensions rather than next to the word "glass". A plain "72 x 24 x 18 Inches" run (the shape
  // buildCustomAquariumSpecText() in docs/js/orderNow.js writes) is tried as a fallback in case a
  // line was ever entered without the L/W/H suffixes. Lets the Glass Cut List page
  // (docs/glass-cut-list.html) pull an order's real dimensions instead of someone retyping them
  // by hand off the order screen. Returns null when neither shape matches.
  function parseAquariumLineSpec(text) {
    var source = String(text || '');

    var suffixMatch = source.match(/([\d.]+)\s*L\s*[Xx]\s*([\d.]+)\s*W\s*[Xx]\s*([\d.]+)\s*H\b\s*(inches?|in\.?|cm|ft|mm)?/i);
    var plainMatch = !suffixMatch && source.match(/([\d.]+)\s*x\s*([\d.]+)\s*x\s*([\d.]+)\s*(inches?|in|cm|ft|mm)\b/i);
    var dimsMatch = suffixMatch || plainMatch;
    if (!dimsMatch) return null;

    var unit = dimsMatch[4] || 'in';

    // The glass thickness sits AFTER the dimensions in the confirmed format ("... inches . 12MM
    // ..."), so it's searched there first - that keeps a "mm" unit on the dimensions themselves
    // (an edge case the fallback format allows) from ever being mistaken for the glass thickness.
    var afterDims = source.slice(dimsMatch.index + dimsMatch[0].length);
    var glassMatch = afterDims.match(/([\d.]+)\s*mm\b/i) || source.match(/([\d.]+)\s*mm\b/i);

    return {
      length: unitToInches(dimsMatch[1], unit),
      width: unitToInches(dimsMatch[2], unit),
      height: unitToInches(dimsMatch[3], unit),
      unit: unit,
      glass: glassMatch ? (glassMatch[1] + 'mm') : null
    };
  }

  function roundToFraction(value, denominator) {
    var d = denominator || DEFAULT_ROUNDING_DENOMINATOR;
    return Math.round(value * d) / d;
  }

  // Renders 23.25 as "23 1/4" so the printed sheet reads the way the hand-drawn one does. The
  // cutting table is marked in inches and fractions; decimals get misread.
  function formatInches(value) {
    var denominator = 16;
    var total = Math.round(toNumber(value) * denominator);
    var whole = Math.floor(total / denominator);
    var numerator = total - (whole * denominator);

    if (numerator === 0) return String(whole);

    while (numerator % 2 === 0 && denominator % 2 === 0) {
      numerator /= 2;
      denominator /= 2;
    }

    return (whole > 0 ? whole + ' ' : '') + numerator + '/' + denominator;
  }

  // Derives the five glass panels of a standard rectangular tank from its OUTSIDE dimensions.
  //
  // The joinery rule (confirmed against the shop's hand-drawn sheet for a 72 x 24 x 18 tank on
  // 10mm): the bottom is the full L x W footprint, the front and back run the full length and
  // land on top of the bottom, and the two side panels tuck BETWEEN front and back - so only the
  // sides lose material, 2 x the glass thickness off the tank's width. Nothing is deducted from
  // the height because the quoted height is the wall height, with the bottom sitting under it.
  function derivePanels(options) {
    var opts = options || {};
    var length = toNumber(opts.length);
    var width = toNumber(opts.width);
    var height = toNumber(opts.height);
    var t = glassThicknessInches(opts.glass);
    var denominator = opts.roundingDenominator || DEFAULT_ROUNDING_DENOMINATOR;
    var trim = toNumber(opts.trimAllowance || DEFAULT_TRIM_ALLOWANCE_INCHES);

    if (length <= 0 || width <= 0 || height <= 0) {
      return [];
    }

    function panel(name, w, h, qty, note) {
      return {
        name: name,
        width: roundToFraction(w + trim, denominator),
        height: roundToFraction(h + trim, denominator),
        qty: qty,
        note: note || ''
      };
    }

    return [
      panel('Bottom', length, width, 1, 'Full footprint - L x W'),
      panel('Front', length, height, 1, 'Sits on the bottom - L x H'),
      panel('Back', length, height, 1, 'Sits on the bottom - L x H'),
      panel('Left', width - (2 * t), height, 1, 'Tucks between front and back - (W - 2 x glass) x H'),
      panel('Right', width - (2 * t), height, 1, 'Tucks between front and back - (W - 2 x glass) x H')
    ];
  }

  // Expands the qty on each derived panel into one entry per physical piece, because the nester
  // places pieces, not line items.
  function explodePanels(panels) {
    var pieces = [];
    (panels || []).forEach(function (p, index) {
      var qty = Math.max(1, Math.round(toNumber(p.qty) || 1));
      for (var i = 0; i < qty; i += 1) {
        pieces.push({
          name: p.name,
          label: qty > 1 ? p.name + ' ' + (i + 1) + '/' + qty : p.name,
          width: toNumber(p.width),
          height: toNumber(p.height),
          note: p.note || '',
          sourceIndex: index
        });
      }
    });
    return pieces;
  }

  // Shelf (strip) packing, which is the only kind of layout a glass cutter can actually execute:
  // every cut must run edge to edge. So the sheet is divided into full-width horizontal strips,
  // and each strip is filled left to right with pieces of that strip's height. Whatever is left
  // at the right-hand end of a strip - and the unused band below the last strip - is the retaso.
  //
  // Pieces are placed tallest-first so the tall panels claim their own strips before the short
  // ones start sharing, which is what keeps the offcuts in a few big usable rectangles instead of
  // many thin unusable ones.
  function nestPanels(pieces, sheetWidth, sheetHeight, options) {
    var opts = options || {};
    var allowRotation = opts.allowRotation !== false;
    var sw = toNumber(sheetWidth);
    var sh = toNumber(sheetHeight);

    var queue = (pieces || []).map(function (p) {
      var piece = {
        name: p.name,
        label: p.label || p.name,
        width: toNumber(p.width),
        height: toNumber(p.height),
        note: p.note || '',
        rotated: false
      };

      // A piece wider than the sheet can only be placed on its side. Rotating here rather than at
      // placement time keeps the tallest-first sort honest.
      if (allowRotation && piece.width > sw && piece.height <= sw) {
        return {
          name: piece.name,
          label: piece.label,
          width: piece.height,
          height: piece.width,
          note: piece.note,
          rotated: true
        };
      }
      return piece;
    });

    var oversized = queue.filter(function (p) { return p.width > sw || p.height > sh; });
    queue = queue.filter(function (p) { return p.width <= sw && p.height <= sh; });

    queue.sort(function (a, b) {
      if (b.height !== a.height) return b.height - a.height;
      return b.width - a.width;
    });

    var sheets = [];

    queue.forEach(function (piece) {
      var placed = false;

      for (var s = 0; s < sheets.length && !placed; s += 1) {
        var sheet = sheets[s];

        // Try an existing strip first: the piece must be no taller than the strip and must fit in
        // what is left of its width.
        for (var i = 0; i < sheet.strips.length && !placed; i += 1) {
          var strip = sheet.strips[i];
          if (piece.height <= strip.height + 1e-9 && piece.width <= strip.remainingWidth + 1e-9) {
            piece.x = strip.usedWidth;
            piece.y = strip.y;
            strip.pieces.push(piece);
            strip.usedWidth += piece.width;
            strip.remainingWidth -= piece.width;
            placed = true;
          }
        }

        // Otherwise open a new strip below the last one, if the sheet has the height left.
        if (!placed && piece.height <= sh - sheet.usedHeight + 1e-9) {
          var fresh = {
            y: sheet.usedHeight,
            height: piece.height,
            usedWidth: piece.width,
            remainingWidth: sw - piece.width,
            pieces: []
          };
          piece.x = 0;
          piece.y = fresh.y;
          fresh.pieces.push(piece);
          sheet.strips.push(fresh);
          sheet.usedHeight += piece.height;
          placed = true;
        }
      }

      if (!placed) {
        var blank = { width: sw, height: sh, strips: [], usedHeight: 0 };
        var first = {
          y: 0,
          height: piece.height,
          usedWidth: piece.width,
          remainingWidth: sw - piece.width,
          pieces: []
        };
        piece.x = 0;
        piece.y = 0;
        first.pieces.push(piece);
        blank.strips.push(first);
        blank.usedHeight = piece.height;
        sheets.push(blank);
      }
    });

    // Retaso: the tail of each strip plus the unused band under the last strip. Both are real,
    // reusable rectangles the shop keeps - so they are reported as offcuts, not as waste.
    sheets.forEach(function (sheet) {
      sheet.offcuts = [];
      sheet.strips.forEach(function (strip) {
        if (strip.remainingWidth > 1e-6) {
          sheet.offcuts.push({
            x: strip.usedWidth,
            y: strip.y,
            width: strip.remainingWidth,
            height: strip.height
          });
        }
      });
      if (sheet.height - sheet.usedHeight > 1e-6) {
        sheet.offcuts.push({
          x: 0,
          y: sheet.usedHeight,
          width: sheet.width,
          height: sheet.height - sheet.usedHeight
        });
      }

      // Collapse the per-strip tails into whole rectangles before anything reports or draws them,
      // so a stack of aligned tails is kept as one large piece of retaso instead of being cut up.
      sheet.offcuts = mergeOffcuts(sheet.offcuts);

      var sheetArea = sheet.width * sheet.height;
      var usedArea = 0;
      sheet.strips.forEach(function (strip) {
        strip.pieces.forEach(function (p) { usedArea += p.width * p.height; });
      });
      sheet.usedArea = usedArea;
      sheet.yieldPercent = sheetArea > 0 ? (usedArea / sheetArea) * 100 : 0;
    });

    return { sheets: sheets, oversized: oversized };
  }

  function nearlyEqual(a, b) {
    return Math.abs(a - b) < 1e-6;
  }

  // Merges touching offcuts back into the largest rectangles they actually form.
  //
  // Shelf packing produces one offcut per strip, so three strips that each use the same width
  // leave three separate tails - e.g. three 12 x 24 pieces stacked at the same x, which are
  // really ONE 12 x 72 piece. Reporting them separately implies cutting straight through a
  // perfectly good offcut and turning one large reusable sheet into several small ones.
  //
  // The merge is physically honest: the cut order simply changes. Instead of cutting every strip
  // line edge to edge first, the cutter drops the vertical cut down the full height of the
  // merged tail first, then makes the strip cuts only inside the narrower region beside it. Both
  // orders are valid guillotine sequences; only this one keeps the retaso whole.
  function mergeOffcuts(offcuts) {
    var list = (offcuts || []).slice();
    var didMerge = true;

    while (didMerge) {
      didMerge = false;

      outer:
      for (var i = 0; i < list.length; i += 1) {
        for (var j = i + 1; j < list.length; j += 1) {
          var a = list[i];
          var b = list[j];
          var combined = null;

          // Stacked: same left edge and width, one ending exactly where the other begins.
          if (nearlyEqual(a.x, b.x) && nearlyEqual(a.width, b.width) &&
              (nearlyEqual(a.y + a.height, b.y) || nearlyEqual(b.y + b.height, a.y))) {
            combined = {
              x: a.x,
              y: Math.min(a.y, b.y),
              width: a.width,
              height: a.height + b.height
            };
          }

          // Side by side: same top edge and height, touching horizontally.
          if (!combined && nearlyEqual(a.y, b.y) && nearlyEqual(a.height, b.height) &&
              (nearlyEqual(a.x + a.width, b.x) || nearlyEqual(b.x + b.width, a.x))) {
            combined = {
              x: Math.min(a.x, b.x),
              y: a.y,
              width: a.width + b.width,
              height: a.height
            };
          }

          if (combined) {
            list.splice(j, 1);
            list.splice(i, 1, combined);
            didMerge = true;
            break outer;
          }
        }
      }
    }

    // Biggest first - that is the order the shop cares about when deciding what is worth keeping.
    list.sort(function (p, q) { return (q.width * q.height) - (p.width * p.height); });
    return list;
  }

  // Works out where a strip's horizontal cut line may actually be drawn.
  //
  // The line must NOT run edge to edge when a merged offcut straddles it - that is exactly the
  // overcut this avoids. So the full width is returned minus the span of any offcut whose
  // interior contains this y. Pieces never straddle a strip boundary, so only offcuts can block.
  function horizontalCutSegments(sheet, y) {
    var blocked = (sheet.offcuts || [])
      .filter(function (o) { return o.y < y - 1e-6 && (o.y + o.height) > y + 1e-6; })
      .map(function (o) { return [o.x, o.x + o.width]; })
      .sort(function (a, b) { return a[0] - b[0]; });

    var segments = [];
    var cursor = 0;

    blocked.forEach(function (range) {
      if (range[0] > cursor + 1e-6) segments.push([cursor, range[0]]);
      cursor = Math.max(cursor, range[1]);
    });

    if (cursor < sheet.width - 1e-6) segments.push([cursor, sheet.width]);
    return segments;
  }

  // One-call convenience wrapper: tank dimensions in, nested sheets out.
  function buildCutList(options) {
    var opts = options || {};
    var panels = derivePanels(opts);
    var nested = nestPanels(
      explodePanels(panels),
      opts.sheetWidth,
      opts.sheetHeight,
      { allowRotation: opts.allowRotation }
    );

    return {
      panels: panels,
      sheets: nested.sheets,
      oversized: nested.oversized
    };
  }

  function escapeXml(value) {
    return String(value == null ? '' : value)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  // Renders one nested sheet the way the shop draws it by hand: the sheet outline, each strip
  // separated by a full-width cut line, every piece labelled with its own width x height, and the
  // retaso shaded. Returns an SVG string so the caller can drop it straight into the page, print
  // it, or upload it as an order-line attachment.
  function renderSheetSvg(sheet, options) {
    var opts = options || {};
    var pad = 54;
    var scale = toNumber(opts.scale) || 7;
    var w = sheet.width * scale;
    var h = sheet.height * scale;
    var svgW = w + (pad * 2);
    var svgH = h + (pad * 2) + 26;

    var parts = [];
    parts.push('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ' + svgW + ' ' + svgH + '" width="' + svgW + '" height="' + svgH + '" font-family="system-ui, sans-serif">');
    parts.push('<rect x="0" y="0" width="' + svgW + '" height="' + svgH + '" fill="#ffffff"/>');

    // Retaso first, so the piece outlines drawn afterwards sit on top of the shading.
    (sheet.offcuts || []).forEach(function (o) {
      var ox = pad + (o.x * scale);
      var oy = pad + (o.y * scale);
      var ow = o.width * scale;
      var oh = o.height * scale;
      parts.push('<rect x="' + ox + '" y="' + oy + '" width="' + ow + '" height="' + oh + '" fill="#f1f5f9" stroke="#cbd5e1" stroke-width="1" stroke-dasharray="5 4"/>');
      if (ow > 46 && oh > 24) {
        parts.push('<text x="' + (ox + (ow / 2)) + '" y="' + (oy + (oh / 2) - 3) + '" text-anchor="middle" font-size="13" fill="#64748b">Retaso</text>');
        parts.push('<text x="' + (ox + (ow / 2)) + '" y="' + (oy + (oh / 2) + 13) + '" text-anchor="middle" font-size="11" fill="#94a3b8">' + escapeXml(formatInches(o.width)) + ' x ' + escapeXml(formatInches(o.height)) + '</text>');
      }
    });

    (sheet.strips || []).forEach(function (strip) {
      strip.pieces.forEach(function (p) {
        var px = pad + (p.x * scale);
        var py = pad + (p.y * scale);
        var pw = p.width * scale;
        var ph = p.height * scale;
        parts.push('<rect x="' + px + '" y="' + py + '" width="' + pw + '" height="' + ph + '" fill="#ffffff" stroke="#1d4f91" stroke-width="2"/>');
        parts.push('<text x="' + (px + (pw / 2)) + '" y="' + (py + (ph / 2) - 4) + '" text-anchor="middle" font-size="15" font-weight="600" fill="#0f172a">' + escapeXml(formatInches(p.width)) + ' x ' + escapeXml(formatInches(p.height)) + '</text>');
        parts.push('<text x="' + (px + (pw / 2)) + '" y="' + (py + (ph / 2) + 14) + '" text-anchor="middle" font-size="12" fill="#475569">' + escapeXml(p.label) + (p.rotated ? ' (rotated)' : '') + '</text>');
      });

      // The cut that separates this strip from the next. Drawn ONLY across the spans that are
      // genuinely cut - it stops short of any retaso that runs past this line, since carrying it
      // edge to edge would slice a large offcut into small ones for no reason.
      var boundary = strip.y + strip.height;
      var lineY = pad + (boundary * scale);
      horizontalCutSegments(sheet, boundary).forEach(function (seg) {
        parts.push('<line x1="' + (pad + (seg[0] * scale)) + '" y1="' + lineY + '" x2="' + (pad + (seg[1] * scale)) + '" y2="' + lineY + '" stroke="#1d4f91" stroke-width="2"/>');
      });
    });

    parts.push('<rect x="' + pad + '" y="' + pad + '" width="' + w + '" height="' + h + '" fill="none" stroke="#0f172a" stroke-width="2.5"/>');

    // Overall sheet dimensions, written outside the outline the way they are on the hand drawing.
    parts.push('<text x="' + (pad + (w / 2)) + '" y="' + (pad - 18) + '" text-anchor="middle" font-size="17" font-weight="700" fill="#0f172a">' + escapeXml(formatInches(sheet.width)) + '"</text>');
    parts.push('<text x="' + (pad - 20) + '" y="' + (pad + (h / 2)) + '" text-anchor="middle" font-size="17" font-weight="700" fill="#0f172a" transform="rotate(-90 ' + (pad - 20) + ' ' + (pad + (h / 2)) + ')">' + escapeXml(formatInches(sheet.height)) + '"</text>');

    var caption = (opts.caption || '') + '  -  yield ' + sheet.yieldPercent.toFixed(1) + '%';
    parts.push('<text x="' + pad + '" y="' + (pad + h + 32) + '" font-size="13" fill="#475569">' + escapeXml(caption) + '</text>');
    parts.push('</svg>');

    return parts.join('');
  }

  global.GlassCutList = {
    derivePanels: derivePanels,
    explodePanels: explodePanels,
    nestPanels: nestPanels,
    mergeOffcuts: mergeOffcuts,
    horizontalCutSegments: horizontalCutSegments,
    buildCutList: buildCutList,
    renderSheetSvg: renderSheetSvg,
    formatInches: formatInches,
    glassThicknessInches: glassThicknessInches,
    unitToInches: unitToInches,
    parseAquariumLineSpec: parseAquariumLineSpec
  };
})(typeof window !== 'undefined' ? window : globalThis);
