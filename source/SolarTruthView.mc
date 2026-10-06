using Toybox.Graphics as Gfx;
using Toybox.Math;
using Toybox.System;
using Toybox.Time;
using Toybox.Time.Gregorian;
using Toybox.Timer;
using Toybox.WatchUi;

//! Three cards (English, clear labels): TODAY → DETAILS → HISTORY
//! No hourly chart (Garmin's native Solar glance already shows that) —
//! the HISTORY card shows multi-day bars, which Garmin does not surface on-watch.
//! Round MIP safe insets — no text in the bottom bezel band.
class SolarTruthView extends WatchUi.View {

    //! 0 TODAY, 1 DETAILS, 2 HISTORY
    var _page = 0;
    const PAGE_COUNT = 3;
    //! Hidden debug overlay (Feature B). Toggled by MENU, independent of _page;
    //! when true onUpdate draws the overlay INSTEAD of the normal card.
    var _debug = false;
    //! The overlay is two screens, not one scrolling wall: it opens on the
    //! actions screen, which fits without scrolling, and MENU reaches the dense
    //! diagnostics dump. Mixing both into one list buried the controls under
    //! twenty rows of numbers.
    const DBG_ACTIONS = 0;
    const DBG_DIAG = 1;
    var _dbgScreen = DBG_ACTIONS;
    //! Diagnostics scroll position (first visible line) and its clamp, set by
    //! the last draw so scrollDebug() can't run past the content.
    var _debugScroll = 0;
    var _debugMaxScroll = 0;
    //! Actions screen items, selected with UP/DOWN and run with START. Only the
    //! wipe keeps a confirmation: it destroys totals that take days to
    //! accumulate, whereas both backups are idempotent, so a second press there
    //! would only stand between the user and the thing he came for.
    //! The selection always reopens on the harmless backup, never on the wipe.
    const ACT_BACKUP = 0;
    const ACT_SAMPLES = 1;
    const ACT_WIPE = 2;
    const ACT_DIAG = 3;
    const ACT_COUNT = 4;
    var _act = ACT_BACKUP;
    var _armed = false;
    //! Automatic backup on overlay entry: what happened this time round, for
    //! the actions screen. In memory only — a skip must never overwrite the
    //! stored outcome, which may be the evidence of an earlier failure.
    const AUTO_NONE = 0;
    const AUTO_STARTED = 1;
    const AUTO_SOON = 2;
    const AUTO_NODATA = 3;
    const AUTO_BUSY = 4;
    const AUTO_PENDING = 5;
    const AUTO_DONE = 6;
    var _autoNote = AUTO_NONE;
    var _autoWaitS = 0;
    //! The export must not run inside the key handler that opened the overlay.
    //! Doing so put every failure on the export path — including a System Error,
    //! which no try/catch can intercept — in front of the overlay's first paint,
    //! so a fatal one replaced the whole panel with the Connect IQ error icon
    //! and the user never saw the status the panel exists to show. Opening now
    //! only records that a run is due; onUpdate arms the timer below once the
    //! panel is actually on the glass, and the run starts from there.
    var _autoPending = false;
    var _autoTimer = null;
    const AUTO_DEFER_MS = 300;
    //! Defer onShow snapshot logging so the first paint is not blocked by
    //! getDayHistory()/computeCalibration — CIQ_LOG showed watchdog trips here.
    const SNAP_DEFER_MS = 250;
    var _snapTimer = null;
    var _snapTag = null;
    var _snapEst = null;
    var _workStage = -2;
    var _cachedToday = null;
    var _cachedHistory = [];
    var _dataReady = false;
    var _lastRefresh = 0;
    var _visible = false;

    function cachedLastDay() {
        var n = _cachedHistory.size();
        return n == 0 ? null : _cachedHistory[n - 1];
    }

    function requestRefresh() {
        if (_visible && _workStage == -2) {
            _workStage = 1;
            armWork();
        }
    }

    function armWork() {
        if (_snapTimer == null) { _snapTimer = new Timer.Timer(); }
        _snapTimer.start(method(:onDeferredSnapshot), 150, false);
    }
    //! Minimum gap between automatic backups. The log file is finite and the
    //! oldest lines are what rotation drops first, so repeated overlay entries
    //! must not push a good dump out with copies of itself. Only a run that
    //! actually wrote re-arms the gap, and the manual item overrides it.
    const AUTO_GAP_S = 20 * 60;
    //! Full dump state machine. Every tick emits a bounded number of log lines,
    //! then yields to avoid watchdog timeouts in one callback.
    const DUMP_IDLE = 0;
    const DUMP_RUN = 1;
    const DUMP_DONE = 2;
    const DUMP_STAGE_CAL = 0;
    const DUMP_STAGE_DAYS = 1;
    const DUMP_STAGE_SUM = 2;
    const DUMP_STAGE_RAWHDR = 3;
    const DUMP_STAGE_RAWROWS = 4;
    const DUMP_STAGE_RAWEND = 5;
    const DUMP_STAGE_END = 6;
    //! Chunked dump pacing: smaller batches and a longer gap between ticks so
    //! a full raw buffer (auto backup is days-only; raw is manual) cannot
    //! overrun the watchdog on a cold evening open after day rollover.
    const DUMP_TICK_MS = 80;
    const DUMP_LINES_PER_TICK = 10;
    var _dumpTimer = null;
    var _dumpState = DUMP_IDLE;
    var _dumpStage = DUMP_STAGE_CAL;
    var _dumpAuto = false;
    var _dumpIncludeRaw = false;
    var _dumpDays = null;
    var _dumpDayCount = 0;
    var _dumpDayIdx = 0;
    var _dumpSamples = null;
    var _dumpSampleCount = 0;
    var _dumpRawStartIdx = 0;
    var _dumpRawIdx = 0;
    var _dumpRawEmitted = 0;
    var _dumpTickNo = 0;
    //! Which input layers delivered a SELECT, and the last raw key code seen.
    //! Shown on the diagnostics screen: this is the evidence for whether a
    //! START press reaches the app at all, which we could not observe before.
    var _behSelects = 0;
    var _behMenus = 0;
    var _keySelects = 0;
    var _lastKey = null;
    //! A press that arrives on both the raw-key and the behaviour path must act
    //! once. Only a duplicate from the *other* source inside this window is
    //! dropped, so two real presses are never merged.
    const SEL_DUP_MS = 250;
    const SEL_SRC_KEY = 0;
    const SEL_SRC_BEH = 1;
    var _selSrc = -1;
    var _selMs = 0;
    //! FIT export state machine (see FitExport). Owned here because the debug
    //! overlay is its only trigger and its only progress display.
    var _export = null;
    //! HISTORY period: 0 = last day, 1 = last week, 2 = last month.
    var _histPeriod = 1;
    const HIST_DAYS = [1, 7, 30];
    const HIST_TABS = ["Day", "Week", "Month"];
    var _timer = null;
    const REFRESH_MS = 3000;
    //! Ceiling on the per-sample dump, sized above SolarLogger.MAX_SAMPLES (288)
    //! so a complete buffer is never truncated in practice — the cap only exists
    //! so a buffer that somehow grew cannot write an unbounded file. At ~46
    //! chars per row a full 288-row dump is ~13 KB. Truncation, if it ever
    //! happens, is announced in the output rather than left to be inferred from
    //! a short row count.
    //!
    //! The heavy dump stays off the onShow path: it runs from the overlay's
    //! deferred backup (after the panel is on the glass) and from the explicit
    //! "Raw samples" action, so neither the cards nor the overlay's first paint
    //! ever wait on it.
    const RAW_DUMP_MAX = 400;
    const MARGIN_PCT = 14;
    const BOTTOM_PCT = 15;
    const TOP_PCT = 9;
    const ELLIPSIS = "…";
    const VERSION = "v9.2";
    const BUILD = "20261006-release";
    const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

    function initialize() {
        View.initialize();
    }

    function onShow() {
        _visible = true;
        SolarLogger.ensureScheduled();
        _dataReady = false;
        _workStage = 0;
        armWork();
        if (_timer == null) { _timer = new Timer.Timer(); }
        _timer.start(method(:onTimerFire), REFRESH_MS, true);
        WatchUi.requestUpdate();
    }

    //! Also the app-exit hook for the exporter: onHide fires whenever this view
    //! leaves the screen, which for a single-view app means the app is going
    //! away. A recording session must never outlive it.
    function onHide() {
        _visible = false;
        _workStage = -2;
        if (_timer != null) {
            _timer.stop();
        }
        if (_dumpState == DUMP_RUN) {
            DebugOutcome.note(DebugOutcome.K_EXIT, DebugOutcome.W_DAYS, _dumpAuto, _dumpDayIdx, null);
            _dumpState = DUMP_IDLE;
            _autoNote = AUTO_NONE;
        }
        stopAutoTimer();
        stopDumpTimer();
        stopSnapTimer();
        _autoPending = false;
        finalizeExportOnExit();
    }

    function stopSnapTimer() {
        if (_snapTimer != null) {
            _snapTimer.stop();
        }
    }

    // Each callback performs one bounded task and yields before the next.
    function onDeferredSnapshot() {
        if (_workStage == -2) { return; }
        if (_workStage == -1) { SolarLogger.appendSample(); }
        else if (_workStage == 0) { SolarEstimates.repairEmbeddedDay(); }
        else if (_workStage == 1) { SolarDayRollup.syncFromSamples(); }
        else if (_workStage == 2) { SolarEstimates.updateCalibration(); }
        else if (_workStage == 3) { _cachedToday = SolarEstimates.computeToday(); }
        else if (_workStage == 4) { SolarEstimates.updateDayTotals(_cachedToday); }
        else if (_workStage == 5) { SolarEstimates.backfillDayDetails(); }
        else if (_workStage == 6) { _cachedHistory = SolarEstimates.getDayHistory(); }
        else {
            _dataReady = true;
            _lastRefresh = Time.now().value();
            _workStage = -2;
            DebugLog.line("ready build=" + BUILD + " days=" + _cachedHistory.size());
            WatchUi.requestUpdate();
            return;
        }
        // Manual sampling skips the one-time repair stage.
        _workStage = _workStage == -1 ? 1 : _workStage + 1;
        armWork();
    }

    function finalizeExportOnExit() {
        if (_export != null) {
            _export.finalizeOnExit();
        }
    }

    function exporter() {
        if (_export == null) {
            _export = new FitExport();
        }
        return _export;
    }

    function onTimerFire() {
        if (Time.now().value() - _lastRefresh >= 60) { requestRefresh(); }
        WatchUi.requestUpdate();
    }

    function forceSampleAndRefresh() {
        if (_workStage != -2) { return; }
        _workStage = -1;
        armWork();
    }

    //! Feature B: flip the hidden debug overlay and repaint. Opening it queues
    //! the daily backup rather than running it — see _autoPending and
    //! armAutoBackup. Nothing here touches the exporter, so the only work
    //! between the key press and the first paint is this bookkeeping.
    function toggleDebug() {
        _debug = !_debug;
        _debugScroll = 0;   // always reopen at the top
        _dbgScreen = DBG_ACTIONS;
        _act = ACT_BACKUP;
        _armed = false;
        _autoNote = _debug ? AUTO_PENDING : AUTO_NONE;
        _autoWaitS = 0;
        stopAutoTimer();
        _autoPending = _debug;
        WatchUi.requestUpdate();
    }

    //! Hand the queued backup to a one-shot timer. Called from onUpdate with the
    //! panel already drawn, so the export — and anything fatal on its path —
    //! can only run with the overlay in front of the user.
    function armAutoBackup() {
        if (!_autoPending) {
            return;
        }
        _autoPending = false;
        if (_autoTimer == null) {
            _autoTimer = new Timer.Timer();
        }
        _autoTimer.start(method(:onAutoBackupDue), AUTO_DEFER_MS, false);
    }

    function stopAutoTimer() {
        if (_autoTimer != null) {
            _autoTimer.stop();
        }
    }

    function stopDumpTimer() {
        if (_dumpTimer != null) {
            _dumpTimer.stop();
        }
    }

    //! The deferred trigger. A user who has already left the overlay is not
    //! waiting for a backup, so the run is dropped rather than started behind
    //! a card he navigated back to.
    function onAutoBackupDue() {
        if (!_debug) {
            _autoNote = AUTO_NONE;
            return;
        }
        startAutoBackup();
        WatchUi.requestUpdate();
    }

    //! The automatic backup, driven by opening the overlay rather than by a
    //! button. That is deliberate: it is the one trigger that cannot depend on
    //! a SELECT arriving, and the routine backup is the reason the overlay gets
    //! opened at all.
    //!
    //! Both skips are silent as far as Storage is concerned — a skip that
    //! overwrote the stored outcome would destroy the record of an earlier
    //! failure, which is the only evidence we get.
    function startAutoBackup() {
        var wait = DebugOutcome.secondsUntilAuto(AUTO_GAP_S);
        if (wait > 0) {
            _autoWaitS = wait;
            _autoNote = AUTO_SOON;
            return;
        }
        // Routine auto backup: day rollups only. Raw samples are the separate
        // manual action — including them here was timing out the watchdog when
        // the overlay opened late in the day with a full sample ring.
        if (!writeTextBackup(true, false)) {
            _autoNote = AUTO_NODATA;
        }
    }

    //! Write the whole stored history to the app's log file and record the
    //! outcome. This replaced the FIT export as the backup: developer fields are
    //! capped at 16 per activity profile by device firmware — a limit shared
    //! with every other Connect IQ app contributing to the activity, and one
    //! whose overrun is an unrecoverable System Error — while this schema needs
    //! 45. Text has no such ceiling, needs no session, and cannot take the app
    //! down. Returns false when there is nothing worth writing.
    //!
    //! The write itself is unverifiable from here: println only lands on disk if
    //! GARMIN/APPS/LOGS/<prg>.TXT already exists, and the app cannot see whether
    //! it does. So the recorded outcome means "the app emitted this", which is
    //! as much as it can honestly claim.
    function writeTextBackup(auto, includeRaw) {
        var days = _cachedHistory;
        var nDays = days == null ? 0 : days.size();
        if (nDays <= 0) {
            return false;
        }
        if (_dumpState == DUMP_RUN) {
            _autoNote = AUTO_BUSY;
            return true;
        }
        DebugOutcome.note(DebugOutcome.K_STARTED, DebugOutcome.W_DAYS, auto, 0, null);
        _autoNote = AUTO_STARTED;
        startDumpPipeline(auto, includeRaw, days);
        return true;
    }

    function startDumpPipeline(auto, includeRaw, days) {
        _dumpAuto = auto;
        _dumpIncludeRaw = includeRaw == true;
        _dumpDays = days;
        _dumpDayCount = days == null ? 0 : days.size();
        _dumpDayIdx = 0;
        _dumpSamples = null;
        _dumpSampleCount = SolarLogger.getCount();
        _dumpRawStartIdx = 0;
        if (_dumpIncludeRaw && _dumpSampleCount > RAW_DUMP_MAX) {
            _dumpRawStartIdx = _dumpSampleCount - RAW_DUMP_MAX;
        }
        _dumpRawIdx = _dumpRawStartIdx;
        _dumpRawEmitted = 0;
        _dumpTickNo = 0;
        _dumpStage = DUMP_STAGE_CAL;
        _dumpState = DUMP_RUN;

        DebugLog.line("dump start days=" + _dumpDayCount
            + " samples=" + _dumpSampleCount
            + " raw=" + DebugLog.bool(_dumpIncludeRaw));
        DebugLog.line("DUMP begin days=" + _dumpDayCount + " samples=" + _dumpSampleCount
            + " raw=" + DebugLog.bool(_dumpIncludeRaw));

        if (_dumpTimer == null) {
            _dumpTimer = new Timer.Timer();
        }
        _dumpTimer.start(method(:onDumpTick), DUMP_TICK_MS, false);
    }

    function scheduleDumpTick() {
        if (_dumpState != DUMP_RUN) {
            return;
        }
        if (_dumpTimer == null) {
            _dumpTimer = new Timer.Timer();
        }
        _dumpTimer.start(method(:onDumpTick), DUMP_TICK_MS, false);
    }

    function onDumpTick() {
        if (_dumpState != DUMP_RUN) {
            return;
        }
        _autoNote = AUTO_BUSY;
        _dumpTickNo += 1;
        var budget = DUMP_LINES_PER_TICK;
        while (budget > 0 && _dumpState == DUMP_RUN) {
            if (_dumpStage == DUMP_STAGE_CAL) {
                logCalibration();
                budget -= 2;
                _dumpStage = DUMP_STAGE_DAYS;
                continue;
            }
            if (_dumpStage == DUMP_STAGE_DAYS) {
                if (_dumpDayIdx >= _dumpDayCount) {
                    _dumpStage = DUMP_STAGE_SUM;
                    continue;
                }
                var d = _dumpDays[_dumpDayIdx];
                DebugLog.line("day i=" + _dumpDayIdx
                    + " id=" + DebugLog.str(d[:day])
                    + " expo=" + DebugLog.num(d[:exposure])
                    + " est%=" + DebugLog.num(d[:estPct])
                    + " sto%=" + DebugLog.num(d[:estPctStored])
                    + " sun=" + DebugLog.num(d[:sunHours])
                    + " peak=" + DebugLog.num(d[:peak])
                    + " avg=" + DebugLog.num(d[:avg])
                    + " first=" + DebugLog.hms(d[:firstSun])
                    + " last=" + DebugLog.hms(d[:lastSun]));
                _dumpDayIdx += 1;
                budget -= 1;
                continue;
            }
            if (_dumpStage == DUMP_STAGE_SUM) {
                logSamplesSummary(_dumpSamples, _dumpSampleCount);
                budget -= 1;
                _dumpStage = _dumpIncludeRaw ? DUMP_STAGE_RAWHDR : DUMP_STAGE_END;
                continue;
            }
            if (_dumpStage == DUMP_STAGE_RAWHDR) {
                if (_dumpIncludeRaw && _dumpSamples == null) {
                    _dumpSamples = SolarLogger.getRawSamples();
                    _dumpSampleCount = _dumpSamples == null ? 0 : _dumpSamples.size();
                    if (_dumpSampleCount > RAW_DUMP_MAX) {
                        _dumpRawStartIdx = _dumpSampleCount - RAW_DUMP_MAX;
                    }
                    _dumpRawIdx = _dumpRawStartIdx;
                }
                DebugLog.line("rawhdr v=1 n=" + _dumpSampleCount + " fields=i,t,b,c,si");
                budget -= 1;
                if (_dumpRawStartIdx > 0 && budget > 0) {
                    DebugLog.line("rawtrunc omitted=" + _dumpRawStartIdx + " oldestKept=" + _dumpRawStartIdx);
                    budget -= 1;
                }
                if (_dumpSampleCount <= 0) {
                    _dumpStage = DUMP_STAGE_RAWEND;
                } else {
                    _dumpStage = DUMP_STAGE_RAWROWS;
                }
                continue;
            }
            if (_dumpStage == DUMP_STAGE_RAWROWS) {
                if (_dumpRawIdx >= _dumpSampleCount) {
                    _dumpStage = DUMP_STAGE_RAWEND;
                    continue;
                }
                var s = _dumpSamples[_dumpRawIdx];
                if (SolarLogger.isRow(s)) {
                    DebugLog.line("raw i=" + _dumpRawIdx
                        + " t=" + DebugLog.num(s[SolarLogger.R_T])
                        + " b=" + DebugLog.num(s[SolarLogger.R_B])
                        + " c=" + ((s[SolarLogger.R_C] == true) ? "1" : "0")
                        + " si=" + DebugLog.num(s[SolarLogger.R_SI]));
                    _dumpRawEmitted += 1;
                    budget -= 1;
                }
                _dumpRawIdx += 1;
                continue;
            }
            if (_dumpStage == DUMP_STAGE_RAWEND) {
                DebugLog.line("rawend n=" + _dumpRawEmitted + " of=" + _dumpSampleCount);
                budget -= 1;
                _dumpStage = DUMP_STAGE_END;
                continue;
            }
            if (_dumpStage == DUMP_STAGE_END) {
                finishDumpPipeline();
                break;
            }
        }
        if (_dumpState == DUMP_RUN) {
            var rawDone = _dumpRawIdx - _dumpRawStartIdx;
            if (rawDone < 0) {
                rawDone = 0;
            }
            DebugLog.line("dump chunk tick=" + _dumpTickNo
                + " day=" + _dumpDayIdx + "/" + _dumpDayCount
                + " raw=" + rawDone + "/" + (_dumpSampleCount - _dumpRawStartIdx));
            scheduleDumpTick();
        }
        WatchUi.requestUpdate();
    }

    function finishDumpPipeline() {
        DebugLog.line("DUMP end");
        DebugLog.line("dump end ticks=" + _dumpTickNo
            + " days=" + _dumpDayCount
            + " rawRows=" + _dumpRawEmitted);
        DebugOutcome.note(DebugOutcome.K_OK, DebugOutcome.W_DAYS, _dumpAuto, _dumpDayCount, null);
        DebugOutcome.markAutoSaved();
        _autoNote = AUTO_DONE;
        _dumpState = DUMP_DONE;
        stopDumpTimer();
    }

    //! True while the chunked log dump is queued or emitting lines. The stored
    //! K_STARTED row means "crashed last time" only when this is false.
    function backupInProgress() {
        return _autoNote == AUTO_STARTED
            || _autoNote == AUTO_BUSY
            || _dumpState == DUMP_RUN;
    }

    //! MENU inside the overlay: swap the actions screen for the diagnostics
    //! dump and back. Deliberately still available while a backup records, so
    //! someone who came to read the calibration numbers does not have to wait
    //! for a recording to finish.
    function toggleDebugScreen() {
        _dbgScreen = (_dbgScreen == DBG_ACTIONS) ? DBG_DIAG : DBG_ACTIONS;
        _debugScroll = 0;
        _armed = false;
        WatchUi.requestUpdate();
    }

    //! BACK inside the overlay, nearest thing first: leave the diagnostics
    //! screen, then cancel a running backup, then dismiss a result, then
    //! disarm. Returns false only when there was nothing left to undo, letting
    //! the delegate close the overlay.
    function onDebugBack() {
        var fx = exporter();
        if (_dbgScreen != DBG_ACTIONS) {
            _dbgScreen = DBG_ACTIONS;
            _debugScroll = 0;
            WatchUi.requestUpdate();
            return true;
        }
        if (fx.isBusy()) {
            // One press is enough to get out of a recording he did not ask
            // for: cancel() keeps whatever was already written and the outcome
            // is in Storage, so a result panel has nothing left to add.
            fx.cancel();
            fx.dismiss();
            WatchUi.requestUpdate();
            return true;
        }
        if (fx.hasResult()) {
            fx.dismiss();
            WatchUi.requestUpdate();
            return true;
        }
        if (_armed) {
            _armed = false;
            WatchUi.requestUpdate();
            return true;
        }
        return false;
    }

    function isDebug() {
        return _debug;
    }

    function behaviorSelects() {
        return _behSelects;
    }

    function behaviorMenus() {
        return _behMenus;
    }

    function noteKey(key) {
        _lastKey = key;
    }

    function noteMenu() {
        _behMenus += 1;
    }

    function onSelectFromKey() {
        _keySelects += 1;
        dispatchSelect(SEL_SRC_KEY);
    }

    function onSelectFromBehavior() {
        _behSelects += 1;
        dispatchSelect(SEL_SRC_BEH);
    }

    //! Drop only a duplicate of the same press arriving on the other input
    //! path; anything else is a genuine press. Matters most for the wipe, the
    //! one action where acting twice on one press would be destructive.
    function dispatchSelect(src) {
        var now = System.getTimer();
        if (_selSrc != -1 && _selSrc != src && (now - _selMs) < SEL_DUP_MS) {
            _selMs = now;
            return;
        }
        _selSrc = src;
        _selMs = now;
        onSelectPressed();
    }

    //! UP/DOWN inside the overlay. On the actions screen they move the
    //! selection — nothing there scrolls, and these two behaviours demonstrably
    //! arrive on this device, which is what the selector needs. On the
    //! diagnostics screen they scroll, clamped by the last draw's line count so
    //! we can't scroll into blank space.
    function scrollDebug(dir) {
        if (_dbgScreen == DBG_ACTIONS) {
            var fx = exporter();
            if (fx.isBusy() || fx.hasResult()) {
                return;   // the panel owns the screen; the selector is hidden
            }
            _act = (_act + dir + ACT_COUNT) % ACT_COUNT;
            _armed = false;
            WatchUi.requestUpdate();
            return;
        }
        _debugScroll += dir;
        if (_debugScroll > _debugMaxScroll) {
            _debugScroll = _debugMaxScroll;
        }
        if (_debugScroll < 0) {
            _debugScroll = 0;
        }
        WatchUi.requestUpdate();
    }

    //! Feature A: emit one compact STDBG line describing the app's core state.
    //! `est` is a prior computeToday() result (reused to avoid recompute), or
    //! null to let this method recompute. Everything is null-guarded.
    function logSnapshot(tag, est) {
        var e = est == null ? _cachedToday : est;
        var samples = SolarLogger.getCount();
        var last = SolarLogger.getLastSample();
        var lastStr;
        if (last == null) {
            lastStr = "none";
        } else {
            lastStr = DebugLog.hms(last[:t]) + " si=" + DebugLog.num(last[:si]) + " b=" + DebugLog.num(last[:b]);
        }
        var days = _cachedHistory;
        var nDays = days == null ? 0 : days.size();
        var todayStr;
        if (e == null) {
            todayStr = "null";
        } else {
            // src tells the two estimate paths apart: "heuristic" is
            // exposure × %/intensity·h, "observed" is battery that actually
            // rose in the sun off the charger. obs/usb are the raw gains behind
            // that choice, so a headline number can be attributed at a glance.
            todayStr = "ready=" + DebugLog.bool(e[:ready])
                + " expo=" + DebugLog.num(e[:exposure])
                + " est%=" + DebugLog.num(e[:estPct])
                + " src=" + DebugLog.str(e[:estPctSource])
                + " obs=" + DebugLog.num(e[:solarPctObs])
                + " usbm=" + DebugLog.num(e[:usbMinutes])
                + " usb%=" + DebugLog.num(e[:usbPctGain])
                + " sun=" + DebugLog.num(e[:sunHours])
                + " peak=" + DebugLog.num(e[:peak])
                + " avg=" + DebugLog.num(e[:avg]);
        }
        DebugLog.line(tag
            + " t=" + DebugLog.nowHms()
            + " samples=" + samples
            + " last=[" + lastStr + "]"
            + " days=" + nDays
            + " today[" + todayStr + "]"
            + " emb[day=" + TodaySolarData.DAY
            + " today=" + DebugLog.bool(TodaySolarData.isForToday())
            + " n=" + TodaySolarData.COUNT + "]");

        // Feature A / bug evidence: dump the last stored day rollup so per-day
        // stored values (esp. sunHours) are visible in the log going forward.
        var ld = cachedLastDay();
        if (ld != null) {
            DebugLog.line("lastday day=" + DebugLog.str(ld[:day])
                + " est%=" + DebugLog.num(ld[:estPct])
                + " sun=" + DebugLog.num(ld[:sunHours])
                + " peak=" + DebugLog.num(ld[:peak])
                + " avg=" + DebugLog.num(ld[:avg]));
        }
    }

    //! USB-readable full dump: emit the COMPLETE stored history to the CIQ log
    //! in a machine-parseable form — one `STDBG day` line per stored day
    //! (oldest→newest, already bounded to 31 by the rollup) plus a samples
    //! summary, wrapped in DUMP begin/end markers. When `includeRaw` is true it
    //! ALSO appends the packed raw sample buffer from the chunked pipeline. Order is
    //! begin → day lines → samples summary → raw lines → end, so the aggregates
    //! survive even if the raw tail gets truncated by log rotation. All values
    //! go through DebugLog helpers, so nulls are safe.
    function logFullDump(includeRaw) {
        var days = _cachedHistory;
        var nDays = days == null ? 0 : days.size();
        if (nDays <= 0) {
            return;
        }
        DebugOutcome.note(DebugOutcome.K_STARTED, DebugOutcome.W_DAYS, false, 0, null);
        _autoNote = AUTO_STARTED;
        startDumpPipeline(false, includeRaw, days);
    }

    //! The calibration state behind every estimate, as raw accumulators plus the
    //! verdict they produce. Without this the log showed a percentage with no way
    //! to tell whether it came from the measured constant, the default, or the
    //! observed-gain branch — which is exactly the question a wrong headline
    //! number raises. Two lines: what has been accumulated, then what it means.
    //!
    //!   STDBG cal lastT=<epoch> darkH=.. darkD=.. sunH=.. sunD=.. expo=..
    //!   STDBG calk drk%/h=.. sun%/h=.. saved=.. K=.. use=<meas|def> need=<gate>
    //!
    //! darkD/sunD are accumulated battery DROP in percent (positive while
    //! discharging), so a negative one means the pack gained in that regime —
    //! the signature of charger energy having leaked into the totals.
    function logCalibration() {
        var tot = SolarEstimates.getCalibTotals();
        DebugLog.line("cal lastT=" + DebugLog.num(tot[0])
            + " darkH=" + DebugLog.num(tot[1])
            + " darkD=" + DebugLog.num(tot[2])
            + " sunH=" + DebugLog.num(tot[3])
            + " sunD=" + DebugLog.num(tot[4])
            + " expo=" + DebugLog.num(tot[5]));
        var cal = SolarEstimates.computeCalibration();
        if (cal == null) {
            return;
        }
        DebugLog.line("calk drk%/h=" + DebugLog.num(cal[:darkRate])
            + " sun%/h=" + DebugLog.num(cal[:sunRate])
            + " saved=" + DebugLog.num(cal[:savedPct])
            + " K=" + formatK(cal[:pctPerIntensityH])
            + " use=" + (cal[:trusted] == true ? "meas" : "def")
            + " eff=" + formatK(SolarEstimates.effectivePctPerIntensityH())
            + " need=" + DebugLog.str(cal[:block]));
    }

    //! Complete per-sample dump: one line per stored sample, every field the
    //! sampler records, nothing aggregated away. The charger flag and the -1
    //! intensity sentinel are the evidence for how much of the buffer is
    //! charging contamination, so both are per row rather than summarised.
    //!
    //!   STDBG rawhdr v=1 n=<stored> fields=i,t,b,c,si
    //!   STDBG raw i=0 t=1000000000 b=100.00 c=0 si=-1
    //!   STDBG rawend n=<emitted> of=<stored>
    //!
    //! Fixed field order and short key=value tokens, so a parser can split on
    //! spaces and take the tail of each token: i is the buffer index oldest→
    //! newest, t epoch seconds, b battery percent (2 dp), c the charger as 1/0,
    //! si the RAW intensity including -1 for "sensor said nothing". "-" is the
    //! only other value any field can take, and means the sampler stored null.
    //! The footer count is what lets the PC side prove nothing was lost.
    function logSamplesSummary(samples, nSamples) {
        if (nSamples > 0) {
            var firstT = null;
            if (samples != null && samples.size() > 0) {
                var first = samples[0];
                firstT = SolarLogger.isRow(first) ? first[SolarLogger.R_T] : null;
            } else {
                var firstS = SolarLogger.getFirstSample();
                firstT = firstS == null ? null : firstS[:t];
            }
            var lastS = SolarLogger.getLastSample();
            var lastT = lastS == null ? null : lastS[:t];
            var lastSi = lastS == null ? null : lastS[:si];
            var lastB = lastS == null ? null : lastS[:b];
            DebugLog.line("samples n=" + nSamples
                + " first=" + DebugLog.hms(firstT)
                + " last=" + DebugLog.hms(lastT)
                + " lastSi=" + DebugLog.num(lastSi)
                + " lastB=" + DebugLog.num(lastB));
            return;
        }
        DebugLog.line("samples n=0");
    }

    //! START/SELECT: in the debug overlay drive the armed action, on
    //! HISTORY cycle the period, elsewhere take a manual sample.
    function onSelectPressed() {
        if (_debug) {
            runSelectedAction();
            return;
        }
        if (_page == 2) {
            _histPeriod = (_histPeriod + 1) % HIST_DAYS.size();
            WatchUi.requestUpdate();
        } else {
            forceSampleAndRefresh();
        }
    }

    //! START inside the overlay: run whatever the actions screen has selected.
    //! While a backup owns the screen START only acknowledges its result — a
    //! press meant for the panel must not fall through to what is behind it.
    function runSelectedAction() {
        var fx = exporter();
        if (fx.isBusy()) {
            return;
        }
        if (fx.hasResult()) {
            fx.dismiss();
            WatchUi.requestUpdate();
            return;
        }
        if (_dbgScreen != DBG_ACTIONS) {
            return;   // the dump has nothing to press
        }
        if (_act == ACT_DIAG) {
            _dbgScreen = DBG_DIAG;
            _debugScroll = 0;
            WatchUi.requestUpdate();
            return;
        }
        if (_act == ACT_WIPE) {
            if (!_armed) {
                _armed = true;
                WatchUi.requestUpdate();
                return;
            }
            _armed = false;
            SolarEstimates.resetCalibration();
            DebugOutcome.noteWiped();
            WatchUi.requestUpdate();
            return;
        }
        _armed = false;
        // Manual override of the rate limit: the automatic run is skipped when
        // a recent one saved, and this is how he forces one anyway.
        if (!writeTextBackup(false, _act == ACT_SAMPLES)) {
            _autoNote = AUTO_NODATA;
        }
        WatchUi.requestUpdate();
    }

    //! Actions screen labels, in words rather than tokens, with the row count
    //! each backup would write.
    function actionLabel(act, days, samples) {
        if (act == ACT_SAMPLES) {
            return "Raw samples " + samples.toString();
        }
        if (act == ACT_WIPE) {
            return "Wipe calibration";
        }
        if (act == ACT_DIAG) {
            return "Diagnostics";
        }
        return "Backup now " + days.toString() + "d";
    }

    function nextPage() {
        _page = (_page + 1) % PAGE_COUNT;
    }

    function previousPage() {
        _page = (_page - 1 + PAGE_COUNT) % PAGE_COUNT;
    }

    function onUpdate(dc) {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var marginX = (w * MARGIN_PCT) / 100;
        if (marginX < 12) {
            marginX = 12;
        }
        var safeW = w - (2 * marginX);
        var cx = w / 2;
        var topPad = (h * TOP_PCT) / 100;
        var bottomPad = (h * BOTTOM_PCT) / 100;
        var contentBottom = h - bottomPad;

        dc.setColor(Gfx.COLOR_BLACK, Gfx.COLOR_BLACK);
        dc.clear();

        if (!_dataReady) {
            dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_BLACK);
            var loadingText = "Loading solar data...";
            var loadingFont = Gfx.FONT_SMALL;
            if (dc.getTextWidthInPixels(loadingText, loadingFont) > w * 0.8) {
                loadingFont = Gfx.FONT_TINY;
            }
            var loadingY = (h - dc.getFontHeight(loadingFont)) / 2;
            dc.drawText(cx, loadingY, loadingFont, loadingText, Gfx.TEXT_JUSTIFY_CENTER);
            return;
        }

        // Feature B: hidden debug overlay drawn INSTEAD of the normal cards.
        // Independent of _page and does not change PAGE_COUNT / the dots.
        if (_debug) {
            var fx = exporter();
            if (_dbgScreen == DBG_DIAG) {
                drawDebugPage(dc);
            } else if (fx.isBusy() || fx.hasResult()) {
                drawExportPanel(dc);
            } else {
                drawActionsPage(dc);
            }
            // Last thing before returning: the panel is composed, so a queued
            // backup may now be armed. Anything fatal it goes on to do happens
            // behind a screen the user can already read.
            armAutoBackup();
            return;
        }

        if (_page == 0) {
            drawTodayPage(dc, cx, marginX, safeW, topPad, contentBottom, _cachedToday);
        } else if (_page == 1) {
            drawDetailsPage(dc, cx, marginX, safeW, topPad, contentBottom, _cachedToday);
        } else {
            drawHistoryPage(dc, cx, marginX, safeW, topPad, contentBottom, _cachedHistory);
        }

        drawPageDots(dc, h, cx, bottomPad);
    }

    //! The screen the overlay opens on. Eight short rows: what the last backup
    //! did, when, and a list of four items with one of them highlighted. It has
    //! to be readable without scrolling and without decoding tokens — the dense
    //! numbers live one MENU press away instead.
    function drawActionsPage(dc) {
        var font = Gfx.FONT_XTINY;
        var lh = dc.getFontHeight(font) - 3;
        if (lh < 12) {
            lh = 12;
        }
        var fx = exporter();
        var days = fx.pendingRows(FX_DAYS);
        var samples = fx.pendingRows(FX_SAMPLES);

        var lines = [];
        var colors = [];
        if (_armed) {
            addRow(lines, colors, "CONFIRM WIPE", Gfx.COLOR_RED);
            addRow(lines, colors, "erases the totals", Gfx.COLOR_WHITE);
            addRow(lines, colors, "BACK cancels", Gfx.COLOR_LT_GRAY);
        } else {
            addRow(lines, colors, headlineLine(), headlineColor());
            addRow(lines, colors, detailLine(), Gfx.COLOR_WHITE);
            addRow(lines, colors, whenLine(), Gfx.COLOR_LT_GRAY);
        }
        for (var i = 0; i < ACT_COUNT; i++) {
            var sel = (i == _act);
            addRow(lines, colors,
                (sel ? "> " : "  ") + actionLabel(i, days, samples),
                sel ? Gfx.COLOR_WHITE : Gfx.COLOR_DK_GRAY);
        }
        addRow(lines, colors, "BACK = exit", Gfx.COLOR_LT_GRAY);

        drawRows(dc, font, lh, lines, colors, 0);
        drawBottomHint(dc, _armed ? "START = WIPE" : "START = run");
    }

    function addRow(lines, colors, text, color) {
        lines.add(text);
        colors.add(color);
    }

    //! Top row. Live run state comes from _autoNote / _dumpState; the stored
    //! row is only shown once nothing is running. K_STARTED in Storage means
    //! "crashed last launch", not "running now" — showing it mid-run was the
    //! false BACKUP CRASHED bug.
    function headlineLine() {
        if (_autoNote == AUTO_PENDING) {
            return "STARTING BACKUP";
        }
        if (backupInProgress()) {
            return "BACKUP IN PROGRESS";
        }
        if (_autoNote == AUTO_DONE) {
            return DebugOutcome.headline();
        }
        return DebugOutcome.headline();
    }

    //! Green when the last thing that happened worked, red when it did not:
    //! the answer to "did it work" should not need reading.
    function headlineColor() {
        if (_autoNote == AUTO_PENDING || backupInProgress()) {
            return Gfx.COLOR_YELLOW;
        }
        var r = DebugOutcome.last();
        if (r == null) {
            return Gfx.COLOR_LT_GRAY;
        }
        var kind = r[DebugOutcome.L_KIND];
        if (kind == DebugOutcome.K_OK) {
            return Gfx.COLOR_GREEN;
        }
        if (kind == DebugOutcome.K_FAIL || kind == DebugOutcome.K_STARTED) {
            return Gfx.COLOR_RED;
        }
        return Gfx.COLOR_YELLOW;
    }

    //! Second row: what was saved, or why this entry did not start one.
    function detailLine() {
        if (_autoNote == AUTO_PENDING) {
            return "getting ready…";
        }
        if (backupInProgress()) {
            return dumpProgressLine();
        }
        if (_autoNote == AUTO_NODATA) {
            return "no days to save yet";
        }
        return DebugOutcome.detail();
    }

    //! Third row: when the stored outcome happened, and — when the rate limit
    //! held this entry back — how long until the next automatic run. A skip has
    //! to read as "you already have one", never as a failure.
    function whenLine() {
        var pre = DebugOutcome.wasAuto() ? "auto " : "";
        if (_autoNote == AUTO_PENDING) {
            return "last " + DebugOutcome.whenText();
        }
        if (backupInProgress()) {
            return "working… " + _dumpTickNo + " ticks";
        }
        if (_autoNote == AUTO_SOON) {
            var mins = (_autoWaitS + 59) / 60;
            return pre + DebugOutcome.timeText() + " · next " + mins.toString() + "m";
        }
        return pre + DebugOutcome.whenText();
    }

    function dumpProgressLine() {
        var dayPart = _dumpDayIdx.toString() + "/" + _dumpDayCount.toString() + "d";
        if (!_dumpIncludeRaw) {
            return "dump " + dayPart;
        }
        var rawTotal = _dumpSampleCount - _dumpRawStartIdx;
        if (rawTotal < 0) {
            rawTotal = 0;
        }
        var rawDone = _dumpRawIdx - _dumpRawStartIdx;
        if (rawDone < 0) {
            rawDone = 0;
        }
        return "dump " + dayPart + " raw " + rawDone + "/" + rawTotal;
    }

    //! Centred single line in the band below the rows, shared with the
    //! diagnostics range indicator.
    function drawBottomHint(dc, text) {
        var h = dc.getHeight();
        var hintH = dc.getFontHeight(Gfx.FONT_XTINY);
        dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
        dc.drawText(dc.getWidth() / 2, h - 4 - hintH, Gfx.FONT_XTINY, text,
            Gfx.TEXT_JUSTIFY_CENTER);
    }

    //! Feature B: compact raw-internals dump, reached with MENU from the
    //! actions screen. Small font, left-aligned, tight line height — a debug
    //! view, so edge clipping on the round display is acceptable.
    function drawDebugPage(dc) {
        var font = Gfx.FONT_XTINY;
        var lh = dc.getFontHeight(font) - 3;
        if (lh < 12) {
            lh = 12;
        }
        var samples = SolarLogger.getCount();
        var last = SolarLogger.getLastSample();
        var e = _cachedToday;
        var days = _cachedHistory;
        var nDays = days == null ? 0 : days.size();
        var ld = cachedLastDay();

        var lines = [];
        lines.add("Solar Truth " + VERSION);
        lines.add("Build " + BUILD);
        // Input evidence leads, because it is the open question: whether a
        // START press reaches the app at all. beh counts SELECT behaviours,
        // key counts presses the raw-key fallback had to route itself, and k is
        // the raw code of the last key seen at all.
        lines.add("IN beh=" + _behSelects + " key=" + _keySelects
            + " menu=" + _behMenus + " k=" + DebugLog.str(_lastKey));
        lines.add("LAST " + DebugOutcome.tokenLine());
        lines.add(" at " + DebugOutcome.whenText());
        // Developer fields each mode wants against what the device will hold
        // open at once. A "need" above the cap is why an export refuses to run.
        var fxq = exporter();
        lines.add("FIT cap=" + fxq.fieldBudget()
            + " d=" + fxq.plannedFields(FX_DAYS)
            + " s=" + fxq.plannedFields(FX_SAMPLES));
        lines.add("DEBUG  samples=" + samples);
        if (last == null) {
            lines.add(" last: none");
        } else {
            lines.add(" last " + DebugLog.hms(last[:t])
                + " si=" + DebugLog.num(last[:si])
                + " b=" + DebugLog.num(last[:b])
                + " c=" + DebugLog.bool(last[:c]));
        }
        lines.add("days=" + nDays);
        // Per-day list (most recent ~6) so every stored day — incl. Jul 24 —
        // is readable on-watch without a cable. Newest last.
        var startDay = nDays > 6 ? nDays - 6 : 0;
        for (var di = startDay; di < nDays; di++) {
            var dRow = days[di];
            lines.add(" " + DebugLog.str(dRow[:day])
                + " sun=" + DebugLog.num(dRow[:sunHours])
                + " e%=" + DebugLog.num(dRow[:estPct]));
        }
        if (e != null) {
            lines.add("today r=" + DebugLog.bool(e[:ready])
                + " sc=" + DebugLog.str(e[:sampleCount])
                + " expo=" + DebugLog.num(e[:exposure]));
            lines.add(" est%=" + DebugLog.num(e[:estPct])
                + "(" + DebugLog.str(e[:estPctSource]) + ")"
                + " run=" + DebugLog.num(e[:runtimeMin]));
            lines.add(" sun=" + DebugLog.num(e[:sunHours])
                + " peak=" + DebugLog.num(e[:peak])
                + " avg=" + DebugLog.num(e[:avg]));
            lines.add(" emb=" + DebugLog.str(e[:embeddedCount])
                + " sto=" + DebugLog.str(e[:storageCount]));
        }
        if (ld != null) {
            var dd = SolarEstimates.computeDayDetail(ld[:day]);
            if (dd != null) {
                lines.add("det r=" + DebugLog.bool(dd[:ready])
                    + " peak=" + DebugLog.num(dd[:peak])
                    + " avg=" + DebugLog.num(dd[:avg])
                    + " sun=" + DebugLog.num(dd[:sunHours]));
            }
        }
        lines.add("emb DAY=" + TodaySolarData.DAY
            + " tdy=" + DebugLog.bool(TodaySolarData.isForToday())
            + " n=" + TodaySolarData.COUNT);
        lines.add(" fix=" + SolarEstimates.repairStatus());

        // Measured drain-with-sun vs drain-in-dark → real %/intensity·h.
        var cal = SolarEstimates.computeCalibration();
        if (cal != null) {
            lines.add("CAL dark=" + DebugLog.num(cal[:darkHours]) + "h@"
                + DebugLog.num(cal[:darkRate]) + "%/h"
                + " sun=" + DebugLog.num(cal[:sunHours]) + "h@"
                + DebugLog.num(cal[:sunRate]) + "%/h");
            if (cal[:ready] == true) {
                lines.add(" saved=" + DebugLog.num(cal[:savedPct]) + "%"
                    + " expo=" + DebugLog.num(cal[:exposure]));
                lines.add(" K=" + formatK(cal[:pctPerIntensityH])
                    + " def=" + formatK(cal[:current]));
            } else {
                lines.add(" K: need dark+sun data");
            }
            // Which constant the estimates are actually running on, and — when
            // still on the default — the first gate that is not met yet.
            if (cal[:trusted] == true) {
                lines.add(" USE=meas " + formatK(cal[:pctPerIntensityH]));
            } else {
                lines.add(" USE=def " + formatK(cal[:current])
                    + " need " + DebugLog.str(cal[:block]));
            }
        }
        lines.add("UP/DOWN scroll · BACK back");

        drawDebugList(dc, font, lh, lines);
    }

    //! Full-screen backup status, in the words the user used. It replaces the
    //! actions screen rather than appending to it so progress and outcome cannot
    //! be scrolled out of sight, which is the whole point of showing them.
    function drawExportPanel(dc) {
        var fx = exporter();
        var font = Gfx.FONT_XTINY;
        var lh = dc.getFontHeight(font) - 3;
        if (lh < 12) {
            lh = 12;
        }
        var raw = fx.runningMode() == FX_SAMPLES;
        var unit = raw ? " samples" : " days";
        var lines = [];
        var st = fx.getState();
        if (st == FX_RUN) {
            lines.add("BACKING UP");
            lines.add(fx.wasAuto() ? "started by itself" : "you started this");
            lines.add(fx.progress().toString() + " of " + fx.total().toString() + unit);
            lines.add("about " + fx.estSeconds().toString() + "s in all");
            lines.add("keep the app open");
            lines.add("BACK = stop");
        } else if (st == FX_DONE) {
            lines.add(raw ? "SAMPLES SAVED" : "BACKUP COMPLETE");
            lines.add(fx.progress().toString() + unit + " saved");
            lines.add("in your activities");
            lines.add("at " + DebugOutcome.timeText());
            lines.add("BACK = close");
        } else if (st == FX_CANCEL) {
            lines.add("BACKUP STOPPED");
            lines.add(DebugOutcome.reasonWords(fx.error()));
            lines.add(fx.progress().toString() + " of " + fx.total().toString() + unit);
            lines.add(fx.savedOk() ? "the part done was kept" : "nothing was saved");
            lines.add("BACK = close");
        } else {
            lines.add("BACKUP FAILED");
            lines.add(DebugOutcome.reasonWords(fx.error()));
            lines.add("nothing was saved");
            lines.add("code " + DebugLog.str(fx.error()));
            lines.add("BACK = close");
        }
        drawRows(dc, font, lh, lines, null, 0);
    }

    //! Rows a full-height band holds. Shared with drawRows() so the scroll
    //! clamp is derived from the same number the renderer uses.
    function visibleRows(dc, lh) {
        var h = dc.getHeight();
        // The range indicator owns a band at the bottom; reserve it
        // unconditionally so the row count — and therefore the scroll clamp —
        // stays stable across screens that do not draw one.
        var hintH = dc.getFontHeight(Gfx.FONT_XTINY);
        var rows = ((h - 4 - hintH) - 4) / lh;
        // A row sitting against the top or bottom of the circle is only a few
        // characters wide, so its line comes out truncated to nothing useful.
        // Give up two rows and centre the band: every visible row then gets a
        // width worth reading, instead of two unreadable ones.
        if (rows > 2) {
            rows -= 2;
        }
        if (rows < 1) {
            rows = 1;
        }
        return rows;
    }

    //! The dense dump plus its position indicator.
    function drawDebugList(dc, font, lh, lines) {
        var rows = visibleRows(dc, lh);
        var total = lines.size();
        var maxScroll = total - rows;
        if (maxScroll < 0) {
            maxScroll = 0;
        }
        _debugMaxScroll = maxScroll;
        if (_debugScroll > maxScroll) {
            _debugScroll = maxScroll;
        }
        if (_debugScroll < 0) {
            _debugScroll = 0;
        }
        var shown = drawRows(dc, font, lh, lines, null, _debugScroll);
        if (maxScroll > 0) {
            // The visible range, not just its first row. Printing the first
            // index alone made a list whose last row was already on screen look
            // eight rows short of the end, so the scroll appeared stuck.
            var first = (_debugScroll + 1).toString();
            var last = (_debugScroll + shown).toString();
            var tag = first + "-" + last + " of " + total.toString();
            drawBottomHint(dc, _debugScroll >= maxScroll ? tag + " END" : tag + " ▼");
        }
    }

    //! Render lines into the round screen: each row is inset to the chord width
    //! at its own y (so nothing spills past the curve), starting at `scroll`.
    //! `colors` may be null for an all-white block. Returns how many rows were
    //! drawn — the range indicator needs the real count, not an assumed one.
    function drawRows(dc, font, lh, lines, colors, scroll) {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;
        var cy = h / 2;
        var r = (w < h ? w : h) / 2;
        var pad = 3;

        var rows = visibleRows(dc, lh);
        var total = lines.size();
        // A block shorter than the band gets a band its own size. The first and
        // last rows of a full-height band sit where the circle is only a few
        // characters wide, so spending rows on nothing costs readable width on
        // the rows that do carry text.
        if (rows > total) {
            rows = total;
        }
        if (rows < 1) {
            rows = 1;
        }
        var band = rows * lh;
        var top = cy - (band / 2);
        if (top < 4) {
            top = 4;
        }

        var shown = 0;
        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_BLACK);
        var y = top;
        for (var i = 0; i < rows; i++) {
            var idx = scroll + i;
            if (idx >= total) {
                break;
            }
            // Usable half-width of the circle for this row. Measured at whichever
            // edge of the glyph box is farther from the center — that is the
            // narrowest point the text has to fit through, so the top and bottom
            // rows don't poke out at their outer corners.
            var dyTop = y - cy;
            if (dyTop < 0) {
                dyTop = -dyTop;
            }
            var dyBot = (y + lh) - cy;
            if (dyBot < 0) {
                dyBot = -dyBot;
            }
            var dy = dyTop > dyBot ? dyTop : dyBot;
            var half = 0;
            if (dy < r) {
                half = Math.sqrt((r * r) - (dy * dy)).toNumber() - pad;
            }
            if (half > 4) {
                var maxW = half * 2;
                var text = truncateToWidth(dc, lines[idx], font, maxW);
                if (colors != null) {
                    dc.setColor(colors[idx], Gfx.COLOR_BLACK);
                }
                dc.drawText(cx - half, y, font, text, Gfx.TEXT_JUSTIFY_LEFT);
            }
            shown += 1;
            y += lh;
        }
        return shown;
    }

    //! Card 1 — what the sun did for you today (main reason to open the app).
    //! Vertical start so a block of height blockH sits centered in [topPad, contentBottom].
    function centeredStartY(topPad, contentBottom, blockH) {
        var availH = contentBottom - topPad;
        var y = topPad + ((availH - blockH) / 2);
        if (y < topPad) {
            y = topPad;
        }
        return y;
    }

    //! First-run screen (no data anywhere yet) — inviting, not a "please wait".
    function drawIntro(dc, cx, safeW, contentBottom, hy) {
        var f1 = Gfx.FONT_SMALL;
        var small = Gfx.FONT_XTINY;
        var lh = dc.getFontHeight(small);
        var bh = dc.getFontHeight(f1) + 2 + (lh + 1) * 2;
        var y = centeredStartY(hy, contentBottom, bh);
        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
        y = drawFitted(dc, contentBottom, cx, y, f1, "Ready for sun", safeW, true);
        y += 2;
        dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
        y = drawFitted(dc, contentBottom, cx, y, small, "Wear it outside — your", safeW, true);
        drawFitted(dc, contentBottom, cx, y, small, "solar gains show up here", safeW, true);
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

    function drawTodayPage(dc, cx, marginX, safeW, topPad, contentBottom, est) {
        var labelFont = Gfx.FONT_XTINY;
        var lh = dc.getFontHeight(labelFont);

        // Header pinned to the top so the title lines up across all cards.
        var hy = drawHeader(dc, cx, marginX, safeW, topPad, contentBottom, "TODAY");

        // Pick the data to show: live today, else the last recorded day, else intro.
        var pct;
        var heroStr;
        var note = null;   // dim "as of <date>" when falling back to a past day
        if (est != null && est[:ready] != false) {
            pct = est[:estPct];
            heroStr = formatRuntimeClear(est);
        } else {
            var last = cachedLastDay();
            if (last == null) {
                drawIntro(dc, cx, safeW, contentBottom, hy);
                return;
            }
            pct = last[:estPct];
            heroStr = formatRuntimeMins(SolarEstimates.estimateRuntimeMinutes(pct));
            note = "as of " + monthDay(last[:day]);
        }

        // Hero = the payoff: extra runtime the sun bought you.
        var vf = pickValueFont(dc, safeW, heroStr);
        var vfH = dc.getFontHeight(vf);
        var tRows = [
            ["Battery gained", formatPctClear(pct)]
        ];
        var tf = pickInlineFont(dc, safeW, tRows);
        var rowH = dc.getFontHeight(tf);

        // Body (everything below the header) centered in the remaining space.
        var noteH = note == null ? 0 : (lh + 1);
        var bodyH = noteH + (lh + 1 + vfH + 1 + 2) + 2 + (rowH + 3) + (lh + 1);
        var y = centeredStartY(hy, contentBottom, bodyH);

        if (note != null) {
            dc.setColor(Gfx.COLOR_DK_GRAY, Gfx.COLOR_TRANSPARENT);
            y = drawFitted(dc, contentBottom, cx, y, labelFont, note, safeW, true);
        }

        // Hero metric: the headline number, centered.
        y = drawMetricRow(dc, contentBottom, cx, y, labelFont, "Extra runtime", heroStr, safeW);
        y += 2;
        // Secondary metric: compact single line (label left, value right).
        y = drawInlineRow(dc, contentBottom, cx, safeW, y, tRows[0][0], tRows[0][1], tf);

        if (y + lh + 2 <= contentBottom) {
            dc.setColor(Gfx.COLOR_DK_GRAY, Gfx.COLOR_TRANSPARENT);
            drawFitted(dc, contentBottom, cx, y, labelFont, "≈ estimate", safeW, true);
        }
    }

    const INLINE_GAP = 12;

    //! Largest font (TINY→XTINY) at which EVERY row's label+value fits on one line.
    //! Keeps all rows of a card the same size for a clean, consistent look.
    function pickInlineFont(dc, safeW, rows) {
        var fonts = [Gfx.FONT_TINY, Gfx.FONT_XTINY];
        for (var i = 0; i < fonts.size(); i++) {
            var f = fonts[i];
            var ok = true;
            for (var j = 0; j < rows.size(); j++) {
                var lw = dc.getTextWidthInPixels(rows[j][0], f);
                var vw = dc.getTextWidthInPixels(rows[j][1], f);
                if (lw + vw + INLINE_GAP > safeW) {
                    ok = false;
                    break;
                }
            }
            if (ok) {
                return f;
            }
        }
        return Gfx.FONT_XTINY;
    }

    //! One compact line: label left, value right, in the given (shared) font.
    //! Truncates ONLY the label so the value (the number) is always shown in full.
    function drawInlineRow(dc, contentBottom, cx, safeW, y, label, value, font) {
        var fh = dc.getFontHeight(font);
        if (y + fh > contentBottom) {
            return y;
        }
        var left = cx - (safeW / 2);
        var right = cx + (safeW / 2);
        var valW = dc.getTextWidthInPixels(value, font);
        var labelMax = safeW - valW - INLINE_GAP;
        var shownLabel = truncateToWidth(dc, label, font, labelMax);
        dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
        dc.drawText(left, y, font, shownLabel, Gfx.TEXT_JUSTIFY_LEFT);
        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
        dc.drawText(right, y, font, value, Gfx.TEXT_JUSTIFY_RIGHT);
        return y + fh + 3;
    }

    //! Card 2 — readable stats (peak / average / sun time / window).
    //! Mirrors TODAY: live today, else the last recorded day, else first-run intro.
    function drawDetailsPage(dc, cx, marginX, safeW, topPad, contentBottom, est) {
        var labelFont = Gfx.FONT_XTINY;
        var lh = dc.getFontHeight(labelFont);

        // Header pinned to the top so the title lines up across all cards.
        var hy = drawHeader(dc, cx, marginX, safeW, topPad, contentBottom, "DETAILS");

        // Pick the data to show: live today, else the last recorded day, else intro.
        var peak;
        var avg;
        var sun;
        var fSun;
        var lSun;
        var note = null;   // dim "as of <date>" when falling back to a past day
        if (est != null && est[:ready] != false) {
            peak = est[:peak];
            avg = est[:avg];
            sun = est[:sunHours];
            fSun = est[:firstSun];
            lSun = est[:lastSun];
        } else {
            var last = cachedLastDay();
            if (last == null) {
                drawIntro(dc, cx, safeW, contentBottom, hy);
                return;
            }
            // The stored rollup is that day's own record and stays put; the
            // ~24 h sample buffer no longer covers it, so reconstructing would
            // report less sun with every day that passes. Raw samples are only
            // for days saved before the detail fields existed.
            if (last[:peak] != null) {
                peak = last[:peak];
                avg = last[:avg];
                sun = last[:sunHours];
                fSun = last[:firstSun];
                lSun = last[:lastSun];
            } else {
                var dd = SolarEstimates.computeDayDetail(last[:day]);
                if (dd == null || dd[:ready] == false) {
                    // Nothing meaningful to show for that day → welcoming intro.
                    drawIntro(dc, cx, safeW, contentBottom, hy);
                    return;
                }
                peak = dd[:peak];
                avg = dd[:avg];
                sun = dd[:sunHours];
                fSun = dd[:firstSun];
                lSun = dd[:lastSun];
            }
            note = "as of " + monthDay(last[:day]);
        }

        var dRows = [
            ["Strongest sun", peak == null ? "—" : peak.format("%.0f") + "%"],
            ["Average sun", avg == null ? "—" : avg.format("%.0f") + "%"],
            ["Time with sun", sun == null ? "—" : sun.format("%.1f") + " h"],
            ["Sun window", (fSun == null || lSun == null) ? "—" : formatEpoch(fSun) + "-" + formatEpoch(lSun)]
        ];
        var df = pickInlineFont(dc, safeW, dRows);
        var rowH = dc.getFontHeight(df);

        // Body centered below the header (+ optional "as of" line).
        var noteH = note == null ? 0 : (lh + 1);
        var bodyH = noteH + 2 + (dRows.size() * (rowH + 3));
        var y = centeredStartY(hy, contentBottom, bodyH);

        if (note != null) {
            dc.setColor(Gfx.COLOR_DK_GRAY, Gfx.COLOR_TRANSPARENT);
            y = drawFitted(dc, contentBottom, cx, y, labelFont, note, safeW, true);
        }
        y += 2;
        for (var di = 0; di < dRows.size(); di++) {
            y = drawInlineRow(dc, contentBottom, cx, safeW, y, dRows[di][0], dRows[di][1], df);
        }
    }

    function drawHeader(dc, cx, marginX, safeW, y, contentBottom, title) {
        var labelFont = Gfx.FONT_XTINY;
        dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
        y = drawFitted(dc, contentBottom, cx, y, labelFont, title, safeW, true);
        dc.setColor(Gfx.COLOR_DK_GRAY, Gfx.COLOR_TRANSPARENT);
        dc.drawLine(marginX, y, marginX + safeW, y);
        return y + 4;
    }

    //! Card 3 — HISTORY: text summary over all logged days (no chart).
    //! Cumulative Battery gained (%) · Extra runtime · Time with sun.
    function drawHistoryPage(dc, cx, marginX, safeW, topPad, contentBottom, days) {
        var labelFont = Gfx.FONT_XTINY;
        var lh = dc.getFontHeight(labelFont);
        var nDays = days == null ? 0 : days.size();

        // Header pinned to the top so the title lines up across all cards.
        var hy = drawHeader(dc, cx, marginX, safeW, topPad, contentBottom, "HISTORY");

        if (nDays == 0) {
            drawIntro(dc, cx, safeW, contentBottom, hy);
            return;
        }

        // Sum the days the selected period actually covers. A rollup exists for
        // days the background logger sealed (or the app opened); taking the last
        // N entries let "Week" reach back weeks whenever a day was skipped; the
        // window is N calendar days ending today, and days with no entry simply
        // contribute nothing.
        var windowN = HIST_DAYS[_histPeriod];
        var cutoff = SolarEstimates.dayIdKeyDaysAgo(windowN - 1);
        var totalPct = 0.0;
        var totalSun = 0.0;
        for (var i = 0; i < nDays; i++) {
            var key = SolarEstimates.dayIdKey(days[i][:day]);
            if (key == null || key < cutoff) {
                continue;
            }
            var p = days[i][:estPct];
            if (p != null) {
                totalPct += p;
            }
            var s = days[i][:sunHours];
            if (s != null) {
                totalSun += s;
            }
        }
        var runtimeMin = SolarEstimates.estimateRuntimeMinutes(totalPct);

        var rows = [
            ["Battery gained", formatPctClear(totalPct)],
            ["Extra runtime", formatRuntimeMins(runtimeMin)],
            ["Time with sun", totalSun.format("%.1f") + " h"]
        ];
        var rf = pickInlineFont(dc, safeW, rows);
        var rowH = dc.getFontHeight(rf);

        // Body: period tabs + 3 rows + estimate footer, centered below header.
        var bodyH = (lh + 4) + (rows.size() * (rowH + 3)) + (lh + 1);
        var y = centeredStartY(hy, contentBottom, bodyH);

        y = drawPeriodTabs(dc, cx, safeW, contentBottom, y, labelFont);
        y += 3;
        for (var r = 0; r < rows.size(); r++) {
            y = drawInlineRow(dc, contentBottom, cx, safeW, y, rows[r][0], rows[r][1], rf);
        }
        if (y + lh + 2 <= contentBottom) {
            dc.setColor(Gfx.COLOR_DK_GRAY, Gfx.COLOR_TRANSPARENT);
            drawFitted(dc, contentBottom, cx, y, labelFont, "≈ estimate", safeW, true);
        }
    }

    //! Period selector "Day · Week · Month" — active one white, others dim.
    function drawPeriodTabs(dc, cx, safeW, contentBottom, y, font) {
        var sep = "  ·  ";
        var sepW = dc.getTextWidthInPixels(sep, font);
        var totalW = 0;
        for (var i = 0; i < HIST_TABS.size(); i++) {
            totalW += dc.getTextWidthInPixels(HIST_TABS[i], font);
            if (i < HIST_TABS.size() - 1) {
                totalW += sepW;
            }
        }
        var x = cx - (totalW / 2);
        var fh = dc.getFontHeight(font);
        for (var j = 0; j < HIST_TABS.size(); j++) {
            var tabW = dc.getTextWidthInPixels(HIST_TABS[j], font);
            dc.setColor(j == _histPeriod ? Gfx.COLOR_WHITE : Gfx.COLOR_DK_GRAY, Gfx.COLOR_TRANSPARENT);
            dc.drawText(x, y, font, HIST_TABS[j], Gfx.TEXT_JUSTIFY_LEFT);
            x += tabW;
            if (j < HIST_TABS.size() - 1) {
                dc.setColor(Gfx.COLOR_DK_GRAY, Gfx.COLOR_TRANSPARENT);
                dc.drawText(x, y, font, sep, Gfx.TEXT_JUSTIFY_LEFT);
                x += sepW;
            }
        }
        return y + fh + 1;
    }

    function drawMetricRow(dc, contentBottom, cx, y, labelFont, label, value, safeW) {
        if (y >= contentBottom) {
            return y;
        }
        dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
        y = drawFitted(dc, contentBottom, cx, y, labelFont, label, safeW, true);
        if (y >= contentBottom) {
            return y;
        }
        var vf = pickValueFont(dc, safeW, value);
        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
        y = drawFitted(dc, contentBottom, cx, y, vf, value, safeW, true);
        return y + 2;
    }

    function drawPageDots(dc, h, cx, bottomPad) {
        var r = 3;
        var y = h - bottomPad + r + 2;
        var gap = 11;
        var totalW = (PAGE_COUNT - 1) * gap;
        var startX = cx - (totalW / 2);
        for (var i = 0; i < PAGE_COUNT; i++) {
            var dx = startX + (i * gap);
            if (i == _page) {
                dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
                dc.fillCircle(dx, y, r);
            } else {
                dc.setColor(Gfx.COLOR_DK_GRAY, Gfx.COLOR_TRANSPARENT);
                dc.drawCircle(dx, y, r);
            }
        }
    }

    function pickValueFont(dc, maxW, text) {
        // Medium (not the giant NUMBER font) so several stacked rows fit without clipping.
        var candidates = [Gfx.FONT_MEDIUM, Gfx.FONT_SMALL, Gfx.FONT_TINY, Gfx.FONT_XTINY];
        for (var i = 0; i < candidates.size(); i++) {
            var f = candidates[i];
            if (dc.getTextWidthInPixels(text, f) <= maxW) {
                return f;
            }
        }
        return Gfx.FONT_XTINY;
    }

    function drawFitted(dc, contentBottom, x, y, font, text, maxW, center) {
        var fh = dc.getFontHeight(font);
        if (y + fh > contentBottom) {
            return contentBottom;
        }
        var shown = truncateToWidth(dc, text, font, maxW);
        if (center) {
            dc.drawText(x, y, font, shown, Gfx.TEXT_JUSTIFY_CENTER);
        } else {
            dc.drawText(x, y, font, shown, Gfx.TEXT_JUSTIFY_LEFT);
        }
        return y + fh + 1;
    }

    function truncateToWidth(dc, text, font, maxW) {
        if (text == null) {
            return "";
        }
        if (dc.getTextWidthInPixels(text, font) <= maxW) {
            return text;
        }
        var ell = ELLIPSIS;
        var ellW = dc.getTextWidthInPixels(ell, font);
        if (ellW >= maxW) {
            return ell;
        }
        var lo = 0;
        var hi = text.length();
        var best = 0;
        while (lo <= hi) {
            var mid = (lo + hi) / 2;
            var candidate = text.substring(0, mid) + ell;
            if (dc.getTextWidthInPixels(candidate, font) <= maxW) {
                best = mid;
                lo = mid + 1;
            } else {
                hi = mid - 1;
            }
        }
        if (best <= 0) {
            return ell;
        }
        return text.substring(0, best) + ell;
    }

    function formatRuntimeClear(est) {
        if (est == null || est[:runtimeMin] == null) {
            return "—";
        }
        return RuntimeFormat.formatRuntimeMins(est[:runtimeMin]);
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

    //! Debug-only: %/intensity·h at 3 dp — DebugLog.num's 2 dp would round the
    //! bottom of the plausible band (0.005) away to "0.01".
    function formatK(k) {
        if (k == null) {
            return "-";
        }
        return k.format("%.3f");
    }

    function formatEpoch(epoch) {
        if (epoch == null) {
            return "--:--";
        }
        var info = Gregorian.info(new Time.Moment(epoch), Time.FORMAT_SHORT);
        return info.hour.format("%02d") + ":" + info.min.format("%02d");
    }
}
