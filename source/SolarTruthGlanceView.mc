using Toybox.Graphics as Gfx;
using Toybox.Lang;
using Toybox.WatchUi;

//! Glance-carousel preview for Solar Truth (swipe up/down from the watch face).
//! Runs in the restricted glance scope, so this file is self-contained: it draws
//! only a compact 2–3 line summary and mirrors the app's TODAY fallback ladder
//! (live today → last recorded day → first-run invite). It pulls figures from
//! SolarEstimates (annotated (:glance)) but never touches the full 3-card View.
//! Duration strings come from RuntimeFormat (:glance); pct/date stay local.
(:glance)
class SolarTruthGlanceView extends WatchUi.GlanceView {

    const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    const ELLIPSIS = "…";

    function initialize() {
        GlanceView.initialize();
    }

    function onUpdate(dc) {
        var w = dc.getWidth();
        var h = dc.getHeight();

        dc.setColor(Gfx.COLOR_BLACK, Gfx.COLOR_BLACK);
        dc.clear();

        // One computeToday() call — glances are memory/CPU constrained.
        var est = SolarEstimates.computeToday();

        var runtimeStr;
        var pctStr;
        var note = null;   // dim "as of <Mon DD>" when falling back to a past day

        if (est != null && est[:ready] != false) {
            runtimeStr = formatRuntimeMins(est[:runtimeMin]);
            pctStr = formatPctClear(est[:estPct]);
        } else {
            var last = SolarEstimates.getLastDay();
            if (last == null) {
                drawSingle(dc, h, "Ready for sun");
                return;
            }
            var pct = last[:estPct];
            runtimeStr = formatRuntimeMins(SolarEstimates.estimateRuntimeMinutes(pct));
            pctStr = formatPctClear(pct);
            note = "as of " + monthDay(last[:day]);
        }

        var smallFont = Gfx.FONT_XTINY;
        var heroStr = "Extra runtime " + runtimeStr;
        var battStr = "Battery " + pctStr;
        // A good day now reads "~10 h 55 m", which is far wider than the "~23 min"
        // these lines were laid out around, so the hero drops a size before it
        // would overrun and both lines are ellipsised as a last resort.
        var heroFont = fitFont(dc, heroStr, w, Gfx.FONT_TINY, smallFont);

        var heroH = dc.getFontHeight(heroFont);
        var smallH = dc.getFontHeight(smallFont);
        var gap = 1;
        var noteH = note == null ? 0 : (smallH + gap);
        var blockH = noteH + heroH + gap + smallH;
        var y = (h - blockH) / 2;
        if (y < 0) {
            y = 0;
        }

        if (note != null) {
            dc.setColor(Gfx.COLOR_DK_GRAY, Gfx.COLOR_TRANSPARENT);
            dc.drawText(0, y, smallFont, note, Gfx.TEXT_JUSTIFY_LEFT);
            y += smallH + gap;
        }
        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
        dc.drawText(0, y, heroFont, truncateToWidth(dc, heroStr, heroFont, w), Gfx.TEXT_JUSTIFY_LEFT);
        y += heroH + gap;
        dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
        dc.drawText(0, y, smallFont, truncateToWidth(dc, battStr, smallFont, w), Gfx.TEXT_JUSTIFY_LEFT);
    }

    //! `font` when the text fits maxW at that size, else `smaller`. One step
    //! only: the glance has just these two sizes and the smaller one is the
    //! size the secondary line already uses.
    function fitFont(dc, text, maxW, font, smaller) {
        if (dc.getTextWidthInPixels(text, font) <= maxW) {
            return font;
        }
        return smaller;
    }

    //! Clip to maxW with the project's ellipsis (standalone copy of the View
    //! helper — the glance must not pull in UI code).
    function truncateToWidth(dc, text, font, maxW) {
        if (text == null) {
            return "";
        }
        if (dc.getTextWidthInPixels(text, font) <= maxW) {
            return text;
        }
        var ellW = dc.getTextWidthInPixels(ELLIPSIS, font);
        if (ellW >= maxW) {
            return ELLIPSIS;
        }
        var lo = 0;
        var hi = text.length();
        var best = 0;
        while (lo <= hi) {
            var mid = (lo + hi) / 2;
            if (dc.getTextWidthInPixels(text.substring(0, mid) + ELLIPSIS, font) <= maxW) {
                best = mid;
                lo = mid + 1;
            } else {
                hi = mid - 1;
            }
        }
        if (best <= 0) {
            return ELLIPSIS;
        }
        return text.substring(0, best) + ELLIPSIS;
    }

    //! First-run / no-data state: a single vertically centered line.
    function drawSingle(dc, h, text) {
        var f = Gfx.FONT_TINY;
        var fh = dc.getFontHeight(f);
        var y = (h - fh) / 2;
        if (y < 0) {
            y = 0;
        }
        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
        dc.drawText(0, y, f, text, Gfx.TEXT_JUSTIFY_LEFT);
    }

    function formatRuntimeMins(mins) {
        return RuntimeFormat.formatRuntimeMins(mins);
    }

    //! Percent → "+1.8%" (always signed; the sun never removes battery).
    function formatPctClear(pct) {
        if (pct == null) {
            return "—";
        }
        var sign = pct >= 0 ? "+" : "";
        return sign + pct.format("%.1f") + "%";
    }

    //! "2000-01-01" → "Jan 1" (compact date for the "as of" note).
    function monthDay(dayId) {
        if (dayId == null) {
            return "";
        }
        var s = dayId.toString();
        if (s.length() < 10) {
            return s;
        }
        var mo = s.substring(5, 7).toNumber();
        var d = s.substring(8, 10).toNumber();
        if (mo == null || d == null || mo < 1 || mo > 12) {
            return s;
        }
        return MONTHS[mo - 1] + " " + d.toString();
    }
}
