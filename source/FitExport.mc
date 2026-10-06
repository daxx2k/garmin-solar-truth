using Toybox.Activity;
using Toybox.ActivityRecording;
using Toybox.Application as App;
using Toybox.FitContributor as Fit;
using Toybox.Lang;
using Toybox.System;
using Toybox.Time;
using Toybox.Timer;
using Toybox.WatchUi;

//! What a run is dumping. DAYS is the routine export; SAMPLES is the bulky one
//! and is a separate armed action so a routine export stays short.
enum {
    FX_DAYS = 0,
    FX_SAMPLES = 1
}

//! Run state. Only IDLE accepts a new start(); DONE/FAIL/CANCEL hold a result
//! panel open until the user dismisses it.
enum {
    FX_IDLE = 0,
    FX_RUN = 1,
    FX_DONE = 2,
    FX_FAIL = 3,
    FX_CANCEL = 4
}

//! USB-readable export of everything the app keeps in Application.Storage.
//!
//! Storage is encrypted on disk and System.println() never reaches CIQ_LOG.TXT
//! on this device, so the only file a watch-app can put on the mass-storage
//! volume is a recorded activity: ActivityRecording opens a session,
//! FitContributor attaches developer fields to it, and the saved FIT lands in
//! GARMIN/Activity/ where MTP can fetch it. Needs no phone and no network.
//!
//! Cadence is the whole design constraint. The SDK states record data "is
//! written once per second or when new data is available (Smart Recording),
//! but is never written faster than once per second", and Field.setData()
//! overwrites a value that has not been flushed yet. Rows are therefore paced
//! at TICK_MS and carry an explicit 1-based row index (st_idx) so the decoder
//! can drop duplicates the engine wrote twice and spot rows it never wrote.
//!
//! Every row is emitted twice, into a record message and into a lap message
//! closed by addLap() on the same tick. Records are the documented path but
//! their emission for a sensorless generic activity cannot be confirmed
//! without running it; laps are written at the marker. The decoder takes
//! whichever stream came out complete, so one mechanism failing costs nothing.
//!
//! The one-off values (calibration accumulators, derived constant, counters)
//! ride on the session message, which is always written at save() — so even a
//! FIT with no usable rows still carries the calibration state.
class FitExport {

    //! Row pacing. The engine never writes records faster than 1 Hz, so a
    //! sub-second tick would silently drop rows; 1.2 s clears the boundary
    //! without stretching the session much.
    const TICK_MS = 1200;
    //! Ticks to keep recording after the last row so the engine flushes it
    //! before stop() closes the file.
    const DRAIN_TICKS = 2;
    //! Samples packed into one record via array-valued developer fields. At
    //! 4 + 2 + 1 + 1 bytes a sample this is 224 bytes plus the index, inside
    //! the documented 256-byte-per-message budget for apps. 288 samples then
    //! need 11 rows instead of 288.
    const SAMPLE_PACK = 28;
    //! Sentinels the decoder discards: a row the engine wrote before the first
    //! real one, a padded tail slot, a battery reading that was null.
    const IDX_NONE = 0;
    const B_NONE = 65535;
    //! Developer fields the device will hold open at once. This is a firmware
    //! constant covering the entire activity profile, not a per-app allowance:
    //! every Connect IQ app contributing to the same activity draws from the
    //! same pool, and overrunning it surfaces inside createField as a System
    //! Error, which is fatal — a try/catch around the call cannot see it. The
    //! schema is therefore measured against this before a session is opened, so
    //! a definition that cannot fit is refused instead of attempted.
    const FIELD_BUDGET = 16;

    var _state = FX_IDLE;
    var _mode = FX_DAYS;
    var _err = null;
    //! Whether this run was started by opening the overlay rather than by a
    //! button. Carried into the persistent outcome so a later reading can tell
    //! which trigger produced the file.
    var _auto = false;
    //! Rows still to read out of Storage, and how far through them we are.
    var _rows = null;
    var _total = 0;
    var _sent = 0;
    var _recs = 0;
    var _pack = 1;
    var _drain = 0;
    var _saved = false;
    var _session = null;
    var _timer = null;
    //! Developer fields created so far this run, against FIELD_BUDGET.
    var _nFields = 0;
    //! Row fields, parallel record/lap sets holding the same columns.
    var _fRecIdx = null;
    var _fLapIdx = null;
    var _rec = null;
    var _lap = null;

    function initialize() {
    }

    function getState() {
        return _state;
    }

    function isBusy() {
        return _state == FX_RUN;
    }

    //! True while a result panel is owed to the user (finished, failed, or
    //! cancelled but not yet acknowledged).
    function hasResult() {
        return _state == FX_DONE || _state == FX_FAIL || _state == FX_CANCEL;
    }

    function dismiss() {
        if (hasResult()) {
            _state = FX_IDLE;
            _rows = null;
        }
    }

    function modeName(mode) {
        return mode == FX_SAMPLES ? "samples" : "days";
    }

    //! What the current run is dumping — the panel must report the mode the
    //! session was opened with, not whatever the selector points at now.
    function runningMode() {
        return _mode;
    }

    //! Whether the current run started itself when the overlay opened, so the
    //! panel can say so instead of leaving the user wondering what he pressed.
    function wasAuto() {
        return _auto;
    }

    //! Rows a mode would export right now, for the pre-arm label.
    function pendingRows(mode) {
        if (mode == FX_SAMPLES) {
            return SolarLogger.getCount();
        }
        var d = SolarEstimates.getDayHistory();
        return d == null ? 0 : d.size();
    }

    //! Wall-clock length of the run, rounded up — shown before and during it so
    //! a fallback to unpacked samples announces its five minutes up front.
    function estSeconds() {
        var chunks = _pack > 0 ? (_total + _pack - 1) / _pack : _total;
        return ((chunks + 1 + DRAIN_TICKS) * TICK_MS) / 1000;
    }

    function progress() {
        return _sent;
    }

    function total() {
        return _total;
    }

    function packSize() {
        return _pack;
    }

    function records() {
        return _recs;
    }

    function fieldBudget() {
        return FIELD_BUDGET;
    }

    function savedOk() {
        return _saved;
    }

    function error() {
        return _err;
    }

    //! Which stored outcome the current mode belongs to.
    function outcomeWhat() {
        return _mode == FX_SAMPLES ? DebugOutcome.W_SAMPLES : DebugOutcome.W_DAYS;
    }

    //! Open a session, define the fields for `mode`, and start pacing rows.
    //! `ver` is the caller's build string, carried into the file so a decoded
    //! dump can be tied to the code that produced it. `auto` marks a run the
    //! overlay started by itself.
    function start(mode, ver, auto) {
        if (_state == FX_RUN) {
            return;
        }
        _mode = mode;
        _auto = (auto == true);
        _err = null;
        _sent = 0;
        _recs = 0;
        _saved = false;
        _pack = 1;
        _drain = DRAIN_TICKS;
        _session = null;
        _nFields = 0;
        // Written before any guard below can return, so the stored outcome
        // distinguishes a run that got here and died from one that was never
        // reached at all. Every exit path from here overwrites it.
        DebugOutcome.note(DebugOutcome.K_STARTED, outcomeWhat(), _auto, 0, null);

        if (!(Toybox has :ActivityRecording) || !(Toybox has :FitContributor)
            || !(ActivityRecording has :createSession)) {
            fail("noapi");
            return;
        }
        // Checked before anything is opened, because the only way to survive
        // the shared field cap is not to reach it: the overrun happens inside
        // createField as a System Error and takes the app with it.
        if (plannedFields(mode) > FIELD_BUDGET) {
            fail("toomany");
            return;
        }
        // A session started by the watch's own activity app would be handed
        // back to us by createSession(); hijacking it would corrupt the user's
        // recording, so refuse while the native timer is anything but off.
        if ((Toybox has :Activity) && (Activity has :getActivityInfo)) {
            var info = Activity.getActivityInfo();
            if (info != null && info.timerState != null
                && info.timerState != Activity.TIMER_STATE_OFF) {
                fail("busy");
                return;
            }
        }

        _rows = (mode == FX_SAMPLES) ? SolarLogger.getRawSamples() : SolarEstimates.getDayHistory();
        _total = _rows == null ? 0 : _rows.size();
        if (_total <= 0) {
            fail("nodata");
            return;
        }

        try {
            _session = ActivityRecording.createSession({
                :name => "SolarTruth",
                :sport => Activity.SPORT_GENERIC,
                :subSport => Activity.SUB_SPORT_GENERIC
            });
        } catch (ex) {
            fail("nosess");
            return;
        }
        if (_session == null) {
            fail("nosess");
            return;
        }
        // Everything past this point invokes a method on the session, and a
        // method the firmware does not provide on an object that does exist is
        // a System Error, not an exception — so the whole set is checked once,
        // here, rather than discovered by calling it. createField is called out
        // separately because losing only that one still means no export.
        if (!(_session has :createField)) {
            discardSession();
            fail("nofield");
            return;
        }
        if (!(_session has :isRecording) || !(_session has :start)
            || !(_session has :stop) || !(_session has :save)
            || !(_session has :discard)) {
            discardSession();
            fail("nosess");
            return;
        }
        // createSession() returns an already-open session rather than a fresh
        // one. A live session here is a leak from a previous run whose fields
        // we no longer hold, so close it out and make the user press again.
        if (_session.isRecording()) {
            closeSession(true);
            fail("stale");
            return;
        }

        if (!defineFields(ver)) {
            discardSession();
            fail("fields");
            return;
        }

        var ok = false;
        try {
            ok = _session.start();
        } catch (ex) {
            ok = false;
        }
        if (ok == false) {
            discardSession();
            fail("start");
            return;
        }

        // Any record the engine writes before the first paced row carries the
        // reserved index, so the decoder drops it instead of aliasing row 1.
        setNum(_fRecIdx, IDX_NONE);
        setNum(_fLapIdx, IDX_NONE);
        writeSessionFields(ver);

        _state = FX_RUN;
        if (_timer == null) {
            _timer = new Timer.Timer();
        }
        _timer.start(method(:onTick), TICK_MS, true);
        DebugLog.line("fitexp start mode=" + modeName(_mode)
            + " rows=" + _total + " pack=" + _pack + " est=" + estSeconds() + "s");
        WatchUi.requestUpdate();
    }

    function onTick() {
        if (_state != FX_RUN) {
            return;
        }
        if (_sent >= _total) {
            _drain -= 1;
            if (_drain <= 0) {
                finish();
            }
            return;
        }
        if (_mode == FX_SAMPLES) {
            emitSamples();
        } else {
            emitDay();
        }
        WatchUi.requestUpdate();
    }

    //! One stored day per row: nine columns, no packing needed for 31 of them.
    function emitDay() {
        var d = _rows[_sent];
        _sent += 1;
        _recs += 1;
        var idx = _sent;
        setNum(_fRecIdx, idx);
        setNum(_fLapIdx, idx);
        var key = SolarEstimates.dayIdKey(d[:day]);
        var vals = [
            key == null ? 0 : key,
            fnum(d[:exposure]),
            fnum(d[:estPct]),
            fnum(d[:usbMin]),
            fnum(d[:sunHours]),
            fnum(d[:peak]),
            fnum(d[:avg]),
            inum(d[:firstSun]),
            inum(d[:lastSun])
        ];
        for (var i = 0; i < vals.size(); i++) {
            setNum(_rec[i], vals[i]);
            setNum(_lap[i], vals[i]);
        }
        addLap();
    }

    //! Up to _pack samples per row. The tail is padded to a full array so the
    //! field always receives exactly the element count it was declared with.
    function emitSamples() {
        var n = _pack;
        if (_sent + n > _total) {
            n = _total - _sent;
        }
        var t = new [_pack];
        var b = new [_pack];
        var c = new [_pack];
        var si = new [_pack];
        for (var i = 0; i < _pack; i++) {
            if (i < n) {
                var row = _rows[_sent + i];
                if (SolarLogger.isRow(row)) {
                    t[i] = inum(row[SolarLogger.R_T]);
                    b[i] = centi(row[SolarLogger.R_B]);
                    c[i] = (row[SolarLogger.R_C] == true) ? 1 : 0;
                    si[i] = clampSi(row[SolarLogger.R_SI]);
                    continue;
                }
            }
            t[i] = 0;
            b[i] = B_NONE;
            c[i] = 0;
            si[i] = -1;
        }
        _sent += n;
        _recs += 1;
        var idx = _recs;
        setNum(_fRecIdx, idx);
        setNum(_fLapIdx, idx);
        var cols = [t, b, c, si];
        for (var k = 0; k < cols.size(); k++) {
            var v = (_pack == 1) ? cols[k][0] : cols[k];
            setNum(_rec[k], v);
            setNum(_lap[k], v);
        }
        addLap();
    }

    //! Stop and save. save() is where a full filesystem shows up, so its result
    //! decides whether the panel claims success.
    function finish() {
        stopTimer();
        setNum(sessionField(:sent), _sent);
        _saved = closeSession(true);
        _state = _saved ? FX_DONE : FX_FAIL;
        if (!_saved) {
            _err = "save";
        }
        if (_saved) {
            DebugOutcome.note(DebugOutcome.K_OK, outcomeWhat(), _auto, _sent, null);
            if (_auto) {
                DebugOutcome.markAutoSaved();
            }
        } else {
            DebugOutcome.note(DebugOutcome.K_FAIL, outcomeWhat(), _auto, _sent, "save");
        }
        DebugLog.line("fitexp done mode=" + modeName(_mode)
            + " rows=" + _sent + "/" + _total + " recs=" + _recs
            + " saved=" + DebugLog.bool(_saved));
        WatchUi.requestUpdate();
    }

    //! BACK during a run. Partial data is still worth having, so anything
    //! already emitted is saved rather than thrown away.
    function cancel() {
        if (_state != FX_RUN) {
            return;
        }
        stopTimer();
        _saved = closeSession(_recs > 0);
        _state = FX_CANCEL;
        _err = "user";
        DebugOutcome.note(DebugOutcome.K_STOPPED, outcomeWhat(), _auto, _sent, "user");
        DebugLog.line("fitexp cancel rows=" + _sent + "/" + _total
            + " saved=" + DebugLog.bool(_saved));
        WatchUi.requestUpdate();
    }

    //! Last line of defence: the app is going away, so the session must not.
    //! A session left open would keep the watch in a recording state after the
    //! app is gone, which is far worse than losing the export.
    function finalizeOnExit() {
        stopTimer();
        if (_session != null) {
            _saved = closeSession(_recs > 0);
            _state = FX_CANCEL;
            _err = "exit";
            DebugOutcome.note(DebugOutcome.K_EXIT, outcomeWhat(), _auto, _sent, "exit");
            DebugLog.line("fitexp exit rows=" + _sent + "/" + _total
                + " saved=" + DebugLog.bool(_saved));
        }
    }

    //! Stop the recording and either keep it or throw it away. Returns true
    //! only when a file was actually written.
    function closeSession(keep) {
        var ok = false;
        if (_session == null) {
            return false;
        }
        try {
            if ((_session has :isRecording) && (_session has :stop)
                && _session.isRecording()) {
                _session.stop();
            }
            if (keep && (_session has :save)) {
                ok = _session.save();
                if (ok == null) {
                    ok = true;   // older signatures return nothing on success
                }
            } else if (_session has :discard) {
                _session.discard();
            }
        } catch (ex) {
            ok = false;
        }
        _session = null;
        clearFields();
        return ok;
    }

    function discardSession() {
        if (_session == null) {
            return;
        }
        try {
            if (_session has :discard) {
                _session.discard();
            }
        } catch (ex) {
        }
        _session = null;
        clearFields();
    }

    function clearFields() {
        _fRecIdx = null;
        _fLapIdx = null;
        _rec = null;
        _lap = null;
        _sess = null;
    }

    function stopTimer() {
        if (_timer != null) {
            _timer.stop();
        }
    }

    function fail(token) {
        stopTimer();
        _err = token;
        _state = FX_FAIL;
        _rows = null;
        DebugOutcome.note(DebugOutcome.K_FAIL, outcomeWhat(), _auto, _sent, token);
        DebugLog.line("fitexp fail " + token);
        WatchUi.requestUpdate();
    }

    // ---- field definitions -------------------------------------------------

    //! Session-scope columns. Strings are legal here and illegal in a record,
    //! which is why embFix and the calibration block live on the session
    //! message rather than alongside the rows.
    var _sess = null;

    function sessionField(key) {
        if (_sess == null) {
            return null;
        }
        return _sess.get(key);
    }

    //! Developer fields `mode` would have to hold open, worst case. SAMPLES
    //! counts both column sets: a device that refuses array-valued fields has
    //! already created the packed ones by the time the fallback is built, and
    //! the refused definitions stay allocated.
    function plannedFields(mode) {
        var n = sessionSpec().size() + 2;   // + the record and lap row indices
        if (mode == FX_SAMPLES) {
            return n + (sampleColSpec().size() * 4);
        }
        return n + (dayColSpec().size() * 2);
    }

    //! Session-scope column descriptors: key, name, id, type, count, units.
    //! Separate from defineFields so plannedFields can size the schema without
    //! a second list to keep in step with it.
    function sessionSpec() {
        return [
            [:ver,   "st_ver",     1,  Fit.DATA_TYPE_STRING, 24, null],
            [:mode,  "st_mode",    2,  Fit.DATA_TYPE_STRING, 10, null],
            [:emb,   "st_emb",     3,  Fit.DATA_TYPE_STRING, 12, null],
            [:ksrc,  "st_ksrc",    4,  Fit.DATA_TYPE_STRING, 8,  null],
            [:block, "st_block",   5,  Fit.DATA_TYPE_STRING, 16, null],
            [:rows,  "st_rows",    6,  Fit.DATA_TYPE_UINT16, 0,  "n"],
            [:sent,  "st_sent",    7,  Fit.DATA_TYPE_UINT16, 0,  "n"],
            [:pack,  "st_pack",    8,  Fit.DATA_TYPE_UINT8,  0,  "n"],
            [:now,   "st_now",     9,  Fit.DATA_TYPE_UINT32, 0,  "s"],
            [:tzoff, "st_tzoff",   10, Fit.DATA_TYPE_SINT32, 0,  "s"],
            [:nsamp, "st_nsamp",   11, Fit.DATA_TYPE_UINT16, 0,  "n"],
            [:ndays, "st_ndays",   12, Fit.DATA_TYPE_UINT8,  0,  "n"],
            [:lastT, "st_c_lastt", 13, Fit.DATA_TYPE_UINT32, 0,  "s"],
            [:darkH, "st_c_darkh", 14, Fit.DATA_TYPE_FLOAT,  0,  "h"],
            [:darkD, "st_c_darkd", 15, Fit.DATA_TYPE_FLOAT,  0,  "%"],
            [:sunH,  "st_c_sunh",  16, Fit.DATA_TYPE_FLOAT,  0,  "h"],
            [:sunD,  "st_c_sund",  17, Fit.DATA_TYPE_FLOAT,  0,  "%"],
            [:expo,  "st_c_expo",  18, Fit.DATA_TYPE_FLOAT,  0,  "ih"],
            [:dRate, "st_c_drate", 19, Fit.DATA_TYPE_FLOAT,  0,  "%/h"],
            [:sRate, "st_c_srate", 20, Fit.DATA_TYPE_FLOAT,  0,  "%/h"],
            [:saved, "st_c_saved", 21, Fit.DATA_TYPE_FLOAT,  0,  "%"],
            [:kMeas, "st_k_meas",  22, Fit.DATA_TYPE_FLOAT,  0,  "%/ih"],
            [:kDef,  "st_k_def",   23, Fit.DATA_TYPE_FLOAT,  0,  "%/ih"],
            [:kEff,  "st_k_eff",   24, Fit.DATA_TYPE_FLOAT,  0,  "%/ih"],
            [:trust, "st_trust",   25, Fit.DATA_TYPE_UINT8,  0,  null]
        ];
    }

    //! Build every developer field the chosen mode needs. Returns false if any
    //! required one could not be created, so the caller can abort before the
    //! session ever starts recording.
    function defineFields(ver) {
        _sess = {};
        var s = sessionSpec();
        for (var i = 0; i < s.size(); i++) {
            var f = mkField(s[i][1], s[i][2], s[i][3], Fit.MESG_TYPE_SESSION, s[i][4], s[i][5]);
            if (f == null) {
                return false;
            }
            _sess.put(s[i][0], f);
        }

        _fRecIdx = mkField("st_idx", 30, Fit.DATA_TYPE_UINT16, Fit.MESG_TYPE_RECORD, 0, "n");
        _fLapIdx = mkField("st_idx", 31, Fit.DATA_TYPE_UINT16, Fit.MESG_TYPE_LAP, 0, "n");
        if (_fRecIdx == null || _fLapIdx == null) {
            return false;
        }

        if (_mode == FX_SAMPLES) {
            return defineSampleFields();
        }
        return defineDayFields();
    }

    function dayColSpec() {
        return [
            ["st_d_key",   Fit.DATA_TYPE_UINT32, null],
            ["st_d_expo",  Fit.DATA_TYPE_FLOAT,  "ih"],
            ["st_d_pct",   Fit.DATA_TYPE_FLOAT,  "%"],
            ["st_d_usb",   Fit.DATA_TYPE_FLOAT,  "min"],
            ["st_d_sun",   Fit.DATA_TYPE_FLOAT,  "h"],
            ["st_d_peak",  Fit.DATA_TYPE_FLOAT,  "%"],
            ["st_d_avg",   Fit.DATA_TYPE_FLOAT,  "%"],
            ["st_d_first", Fit.DATA_TYPE_UINT32, "s"],
            ["st_d_last",  Fit.DATA_TYPE_UINT32, "s"]
        ];
    }

    function defineDayFields() {
        var cols = dayColSpec();
        _rec = [];
        _lap = [];
        for (var i = 0; i < cols.size(); i++) {
            var r = mkField(cols[i][0], 40 + i, cols[i][1], Fit.MESG_TYPE_RECORD, 0, cols[i][2]);
            var l = mkField(cols[i][0], 80 + i, cols[i][1], Fit.MESG_TYPE_LAP, 0, cols[i][2]);
            if (r == null || l == null) {
                return false;
            }
            _rec.add(r);
            _lap.add(l);
        }
        _pack = 1;
        return true;
    }

    //! Array-valued fields are the difference between a 17-second export and a
    //! six-minute one, but nothing in the docs promises a device accepts them,
    //! so they are probed with a dummy write before the session starts. On
    //! refusal the whole mode drops to one sample per row using a second set of
    //! field numbers, leaving the rejected definitions unused but harmless.
    function defineSampleFields() {
        _pack = SAMPLE_PACK;
        if (!buildSampleCols(60, 90, SAMPLE_PACK) || !probePacked(SAMPLE_PACK)) {
            _pack = 1;
            if (!buildSampleCols(64, 94, 1)) {
                return false;
            }
        }
        return true;
    }

    function sampleColSpec() {
        return [
            ["st_s_t",  Fit.DATA_TYPE_UINT32, "s"],
            ["st_s_b",  Fit.DATA_TYPE_UINT16, "c%"],
            ["st_s_c",  Fit.DATA_TYPE_UINT8,  null],
            ["st_s_si", Fit.DATA_TYPE_SINT8,  "%"]
        ];
    }

    function buildSampleCols(recBase, lapBase, count) {
        var cols = sampleColSpec();
        _rec = [];
        _lap = [];
        for (var i = 0; i < cols.size(); i++) {
            var r = mkField(cols[i][0], recBase + i, cols[i][1], Fit.MESG_TYPE_RECORD, count, cols[i][2]);
            var l = mkField(cols[i][0], lapBase + i, cols[i][1], Fit.MESG_TYPE_LAP, count, cols[i][2]);
            if (r == null || l == null) {
                return false;
            }
            _rec.add(r);
            _lap.add(l);
        }
        return true;
    }

    //! Dummy array write, before start(), so a device that rejects arrays does
    //! so while nothing is being recorded.
    function probePacked(count) {
        var zeros = new [count];
        for (var i = 0; i < count; i++) {
            zeros[i] = 0;
        }
        try {
            for (var k = 0; k < _rec.size(); k++) {
                if (!(_rec[k] has :setData) || !(_lap[k] has :setData)) {
                    return false;
                }
                _rec[k].setData(zeros);
                _lap[k].setData(zeros);
            }
        } catch (ex) {
            return false;
        }
        return true;
    }

    //! createField throws rather than returns null when a definition will not
    //! fit the message budget, so both outcomes collapse to null here.
    //!
    //! The two checks in front of the call are the ones that matter: a session
    //! without createField, and a definition past FIELD_BUDGET, both end in a
    //! System Error the catch below would never see. Refusing them is the only
    //! way to report them.
    function mkField(name, id, type, mesg, count, units) {
        if (_session == null || !(_session has :createField)) {
            return null;
        }
        if (_nFields >= FIELD_BUDGET) {
            return null;
        }
        var opts = { :mesgType => mesg };
        if (count > 0) {
            opts.put(:count, count);
        }
        if (units != null) {
            opts.put(:units, units);
        }
        var f = null;
        try {
            f = _session.createField(name, id, type, opts);
        } catch (ex) {
            return null;
        }
        if (f != null) {
            _nFields += 1;
        }
        return f;
    }

    // ---- value writing -----------------------------------------------------

    //! Fill the one-off block. Called once, just after start(); the engine
    //! writes it out with the session message at save().
    function writeSessionFields(ver) {
        var cal = SolarEstimates.computeCalibration();
        var tot = SolarEstimates.getCalibTotals();
        var days = SolarEstimates.getDayHistory();
        var clock = System.getClockTime();

        setStr(sessionField(:ver), ver, 23);
        setStr(sessionField(:mode), modeName(_mode), 9);
        setStr(sessionField(:emb), SolarEstimates.repairStatus(), 11);
        setStr(sessionField(:ksrc), (cal != null && cal[:trusted] == true) ? "meas" : "def", 7);
        setStr(sessionField(:block), (cal == null || cal[:block] == null) ? "-" : cal[:block], 15);
        setNum(sessionField(:rows), _total);
        setNum(sessionField(:sent), 0);
        setNum(sessionField(:pack), _pack);
        setNum(sessionField(:now), Time.now().value());
        setNum(sessionField(:tzoff), clock == null ? 0 : clock.timeZoneOffset);
        setNum(sessionField(:nsamp), SolarLogger.getCount());
        setNum(sessionField(:ndays), days == null ? 0 : days.size());

        setNum(sessionField(:lastT), inum(tot[0]));
        setNum(sessionField(:darkH), fnum(tot[1]));
        setNum(sessionField(:darkD), fnum(tot[2]));
        setNum(sessionField(:sunH), fnum(tot[3]));
        setNum(sessionField(:sunD), fnum(tot[4]));
        setNum(sessionField(:expo), fnum(tot[5]));

        if (cal != null) {
            setNum(sessionField(:dRate), fnum(cal[:darkRate]));
            setNum(sessionField(:sRate), fnum(cal[:sunRate]));
            setNum(sessionField(:saved), fnum(cal[:savedPct]));
            setNum(sessionField(:kMeas), cal[:pctPerIntensityH] == null ? -1.0 : fnum(cal[:pctPerIntensityH]));
            setNum(sessionField(:kDef), fnum(cal[:current]));
            setNum(sessionField(:trust), cal[:trusted] == true ? 1 : 0);
        }
        setNum(sessionField(:kEff), fnum(SolarEstimates.effectivePctPerIntensityH()));
    }

    function addLap() {
        if (_session == null || !(_session has :addLap)) {
            return;
        }
        try {
            _session.addLap();
        } catch (ex) {
        }
    }

    function setNum(field, value) {
        if (field == null || value == null || !(field has :setData)) {
            return;
        }
        try {
            field.setData(value);
        } catch (ex) {
        }
    }

    //! Strings are truncated to fit the declared :count (which counts bytes
    //! including the terminator) rather than risking a rejected write that
    //! would leave the column empty.
    function setStr(field, value, max) {
        if (field == null || !(field has :setData)) {
            return;
        }
        var s = value == null ? "-" : value.toString();
        if (s.length() > max) {
            s = s.substring(0, max);
        }
        try {
            field.setData(s);
        } catch (ex) {
        }
    }

    //! -1.0 marks "not recorded" for columns whose real values are never
    //! negative, so a null never becomes an indistinguishable zero.
    function fnum(v) {
        if (v == null) {
            return -1.0;
        }
        return v.toFloat();
    }

    function inum(v) {
        if (v == null) {
            return 0;
        }
        return v.toNumber();
    }

    //! Battery percent to hundredths: the raw value is fractional and that
    //! precision is what the calibration ratio is built from.
    function centi(v) {
        if (v == null) {
            return B_NONE;
        }
        var n = (v.toFloat() * 100.0 + 0.5).toNumber();
        if (n < 0) {
            return 0;
        }
        if (n >= B_NONE) {
            return B_NONE - 1;
        }
        return n;
    }

    function clampSi(v) {
        if (v == null) {
            return -1;
        }
        var n = v.toNumber();
        if (n < 0) {
            return -1;
        }
        if (n > 127) {
            return 127;
        }
        return n;
    }
}
