using Toybox.Application as App;
using Toybox.Background;
using Toybox.Lang;
using Toybox.System;
using Toybox.Time;

//! Sample + Storage ring buffer shared by UI and background.
//! A live sample is a dict: :t timestamp (epoch s), :b battery %,
//! :c charging (USB), :si solarIntensity. Persisted rows are the compact
//! primitive array [t, b, c, si] — index them with the R_* constants.
//! Entire module is (:background) so Storage helpers compile into the background process.
(:background)
module SolarLogger {

    const STORAGE_KEY = "samples";
    const MAX_SAMPLES = 288;          // ~24 h at 5 min
    const INTERVAL_SEC = 5 * 60;      // TemporalEvent minimum is 5 minutes
    const SOLAR_MIN = 1;              // intensity at which the panel counts as lit

    //! Column indices of a persisted row [t, b, c, si].
    const R_T = 0;
    const R_B = 1;
    const R_C = 2;
    const R_SI = 3;

    //! True when the sample shows real solar exposure (panel seeing light).
    //! A classifier for readers of the buffer, NOT a filter on what goes into
    //! it: null/0 rows (night, indoors, sleeve over the watch) are logged too,
    //! because the no-sun drain is the calibration baseline (appendSample).
    function hasSolar(row) {
        if (row == null) {
            return false;
        }
        var si = row[:si];
        return (si != null) && (si >= SOLAR_MIN);
    }

    function sampleNow() {
        var s = System.getSystemStats();
        var solar = null;
        if (s has :solarIntensity) {
            solar = s.solarIntensity;
        }
        var batt = null;
        if (s has :battery) {
            batt = s.battery;
        }
        var charging = false;
        if (s has :charging) {
            charging = s.charging ? true : false;
        }
        return {
            :t => Time.now().value(),
            :b => batt,
            :c => charging,
            :si => solar
        };
    }

    //! Storage cannot serialize Symbol-keyed Dictionaries, so rows are persisted
    //! as compact primitive arrays [t, b, c, si]. This rehydrates ONE row for the
    //! few callers that want a sample by name; bulk readers walk getRawSamples()
    //! in place instead (see the note there).
    function storeToRow(a) {
        if (a == null) {
            return null;
        }
        if (a instanceof Lang.Array) {
            return {
                :t => a[R_T],
                :b => a[R_B],
                :c => a[R_C],
                :si => a[R_SI]
            };
        }
        return a;
    }

    //! The persisted buffer as stored: rows stay compact primitive arrays, so
    //! reading it costs nothing beyond the deserialized array itself.
    //!
    //! Rehydrating instead would allocate one Symbol-keyed Dictionary per row —
    //! up to MAX_SAMPLES of them alive at the same time as the raw arrays they
    //! were built from — which neither the background process nor the glance
    //! (a far smaller budget than the app, and a blank glance is the only
    //! symptom of overrunning it) can absorb. Readers therefore walk the rows
    //! in place with the R_* indices, guarding each row with isRow().
    //!
    //! The returned array may be the Storage value itself — read only.
    //! Holes are dropped, so size() matches getCount().
    function getRawSamples() {
        var arr = App.Storage.getValue(STORAGE_KEY);
        if (arr == null || !(arr instanceof Lang.Array)) {
            return [];
        }
        for (var i = 0; i < arr.size(); i++) {
            if (arr[i] == null) {
                return withoutHoles(arr);
            }
        }
        return arr;
    }

    //! Copy of a buffer with the null entries removed. appendSample() never
    //! writes one, so this stays a cold path — it exists so a hole can never
    //! reach a reader or change the sample count a reader reports.
    function withoutHoles(arr) {
        var out = [];
        for (var i = 0; i < arr.size(); i++) {
            if (arr[i] != null) {
                out.add(arr[i]);
            }
        }
        return out;
    }

    //! True when an entry is a well-formed persisted row, i.e. safe to index
    //! with the R_* constants. Anything else is skipped by its reader, exactly
    //! as a row with a null timestamp always was.
    function isRow(row) {
        return (row instanceof Lang.Array) && (row.size() > R_SI);
    }

    //! Row count without materialising anything. onTemporalEvent() only wants
    //! the size, and the background budget has no room for more.
    //! Counts exactly what getRawSamples() keeps: nulls dropped, nothing else.
    function getCount() {
        var arr = App.Storage.getValue(STORAGE_KEY);
        if (arr == null || !(arr instanceof Lang.Array)) {
            return 0;
        }
        var n = 0;
        for (var i = 0; i < arr.size(); i++) {
            if (arr[i] != null) {
                n += 1;
            }
        }
        return n;
    }

    //! Newest sample as a dict, for the callers that read one row by name.
    //! Only that row is rehydrated — the rest of the buffer is never touched.
    function getLastSample() {
        var arr = App.Storage.getValue(STORAGE_KEY);
        if (arr == null || !(arr instanceof Lang.Array)) {
            return null;
        }
        for (var i = arr.size() - 1; i >= 0; i--) {
            if (arr[i] != null) {
                return storeToRow(arr[i]);
            }
        }
        return null;
    }

    //! Oldest sample as a dict — walks from the front without materialising the
    //! full buffer. Used by the days-only dump summary.
    function getFirstSample() {
        var arr = App.Storage.getValue(STORAGE_KEY);
        if (arr == null || !(arr instanceof Lang.Array)) {
            return null;
        }
        for (var i = 0; i < arr.size(); i++) {
            if (arr[i] != null) {
                return storeToRow(arr[i]);
            }
        }
        return null;
    }

    //! Always rebuild the array — Storage values are not reliably mutable.
    //! Persist compact primitive arrays [t, b, c, si] (Symbol-keyed dicts are
    //! not serializable by Application.Storage).
    function appendSample() {
        var row = sampleNow();
        // Every sample is persisted, including zero-sun ones: the no-sun battery
        // drain is the baseline the solar benefit is measured against. Zero-sun
        // rows never reach the displayed metrics — exposure/sunHours/peak/avg all
        // ignore si == 0 by construction — so the history stays clean either way.
        var prev = App.Storage.getValue(STORAGE_KEY);
        var next = [];
        if (prev != null && prev instanceof Lang.Array) {
            var start = 0;
            if (prev.size() >= MAX_SAMPLES) {
                start = prev.size() - MAX_SAMPLES + 1;
            }
            for (var i = start; i < prev.size(); i++) {
                next.add(prev[i]);
            }
        }
        next.add([row[:t], row[:b], row[:c], row[:si]]);
        App.Storage.setValue(STORAGE_KEY, next);
        return row;
    }

    //! Register a 5-minute temporal event if none is pending.
    function ensureScheduled() {
        if (!(Toybox has :Background)) {
            return;
        }
        if (!(System has :ServiceDelegate)) {
            return;
        }
        if (Background.getTemporalEventRegisteredTime() != null) {
            return;
        }
        Background.registerForTemporalEvent(new Time.Duration(INTERVAL_SEC));
    }

    //! Re-arm after a temporal fire (registration is consumed when the event runs).
    function scheduleNext() {
        if (!(Toybox has :Background)) {
            return;
        }
        Background.registerForTemporalEvent(new Time.Duration(INTERVAL_SEC));
    }
}

//! Background temporal sampler (≥5 min).
(:background)
class SolarLoggerService extends System.ServiceDelegate {

    function initialize() {
        ServiceDelegate.initialize();
    }

    function onTemporalEvent() {
        var row = SolarLogger.appendSample();
        // Feature A: greppable background diagnostic. appendSample() persists
        // every row, so what is worth logging is whether this one saw sun, not
        // whether it was kept. DebugLog is (:background) and touches no UI code,
        // so this is safe here.
        var sun = SolarLogger.hasSolar(row);
        var si = (row == null) ? null : row[:si];
        var b = (row == null) ? null : row[:b];
        DebugLog.line("bgsample t=" + DebugLog.nowHms()
            + " si=" + DebugLog.num(si)
            + " b=" + DebugLog.num(b)
            + " sun=" + DebugLog.bool(sun)
            + " count=" + SolarLogger.getCount());
        // Seal / refresh HISTORY day rollups while samples still exist — the
        // UI must not be the only writer or missed days vanish with the ring.
        SolarDayRollup.syncFromSamples();
        SolarLogger.scheduleNext();
        Background.exit(null);
    }
}
