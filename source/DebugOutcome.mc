using Toybox.Application as App;
using Toybox.Lang;
using Toybox.Time;
using Toybox.Time.Gregorian;

//! Persistent record of the last debug-overlay action, phrased for a human.
//!
//! This is the diagnostic channel that works with nothing attached: Storage is
//! encrypted on disk, the simulator is unavailable, and println only survives
//! when GARMIN/APPS/LOGS/<prg>.TXT was created beforehand — so an action that
//! fails silently is unobservable on the watch itself unless its outcome
//! outlives the app. Every state change writes one short row, which the actions
//! screen reads back on the next launch.
//!
//! K_STARTED is written before the backup does any real work, so finding it
//! still there separates "the run path was reached and then died" from "the run
//! path was never reached at all" — precisely the distinction that could not be
//! made from the watch. It is how the FIT export's fatal field overrun was
//! finally attributed.
module DebugOutcome {

    const LAST_KEY = "dbgLast";
    const AUTO_KEY = "dbgAutoAt";
    const SEQ_KEY = "dbgSeq";

    //! Column layout of LAST_KEY. A primitive array, because Storage cannot
    //! serialize Symbol-keyed dictionaries.
    const L_KIND = 0;
    const L_WHAT = 1;
    const L_AUTO = 2;
    const L_ROWS = 3;
    const L_AT = 4;
    const L_ERR = 5;
    const L_LEN = 6;

    //! What happened. STARTED is overwritten by whichever of the others the
    //! run reaches; surviving to the next launch is itself the finding.
    const K_STARTED = 1;
    const K_OK = 2;
    const K_FAIL = 3;
    const K_STOPPED = 4;
    const K_EXIT = 5;
    const K_WIPED = 6;

    //! Which action the row is about.
    const W_DAYS = 0;
    const W_SAMPLES = 1;
    const W_CAL = 2;

    const MON = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                 "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

    //! Overwrite the single outcome slot. Storage writes are wrapped: the
    //! bookkeeping must never be what kills the action it is recording.
    function note(kind, what, auto, rows, err) {
        try {
            App.Storage.setValue(LAST_KEY, [
                kind,
                what,
                auto == true,
                rows == null ? 0 : rows.toNumber(),
                Time.now().value(),
                err == null ? null : err.toString()
            ]);
            var seq = App.Storage.getValue(SEQ_KEY);
            if (!(seq instanceof Lang.Number)) {
                seq = 0;
            }
            App.Storage.setValue(SEQ_KEY, seq + 1);
        } catch (ex) {
        }
    }

    function noteWiped() {
        note(K_WIPED, W_CAL, false, 0, null);
    }

    //! Only a run that actually wrote a file re-arms the automatic gap, so a
    //! failing backup is retried on the next overlay entry instead of being
    //! locked out for the rate-limit window.
    function markAutoSaved() {
        try {
            App.Storage.setValue(AUTO_KEY, Time.now().value());
        } catch (ex) {
        }
    }

    //! Seconds still to wait before the automatic backup may run again, 0 when
    //! it is due. A clock that has moved backwards reads as due rather than
    //! locking the backup out for the length of the jump.
    function secondsUntilAuto(gap) {
        var at = App.Storage.getValue(AUTO_KEY);
        if (!(at instanceof Lang.Number)) {
            return 0;
        }
        var now = Time.now().value();
        if (now < at) {
            return 0;
        }
        var left = gap - (now - at);
        return left > 0 ? left : 0;
    }

    //! The stored row, or null when nothing has been recorded yet.
    function last() {
        var r = App.Storage.getValue(LAST_KEY);
        if (!(r instanceof Lang.Array) || r.size() < L_LEN) {
            return null;
        }
        return r;
    }

    function seq() {
        var s = App.Storage.getValue(SEQ_KEY);
        return (s instanceof Lang.Number) ? s : 0;
    }

    function at() {
        var r = last();
        return r == null ? null : r[L_AT];
    }

    function wasAuto() {
        var r = last();
        return r != null && r[L_AUTO] == true;
    }

    //! Headline for the actions screen. Kept to 16 characters: the top row of
    //! that screen's band is the narrowest part of the circle it uses.
    function headline() {
        var r = last();
        if (r == null) {
            return "NO BACKUP YET";
        }
        var kind = r[L_KIND];
        if (kind == K_WIPED) {
            return "NUMBERS WIPED";
        }
        if (kind == K_OK) {
            return r[L_WHAT] == W_SAMPLES ? "SAMPLES SAVED" : "BACKUP COMPLETE";
        }
        if (kind == K_FAIL) {
            return "BACKUP FAILED";
        }
        if (kind == K_STOPPED) {
            return "BACKUP STOPPED";
        }
        if (kind == K_EXIT) {
            return "BACKUP CUT SHORT";
        }
        // K_STARTED surviving to a later launch means the run never reached any
        // of its own exit paths — the app went down mid-export. Naming that is
        // the point of persisting the row at all.
        return "BACKUP CRASHED";
    }

    //! The line under the headline: how much was saved, or why it was not.
    function detail() {
        var r = last();
        if (r == null) {
            return "none run yet";
        }
        var kind = r[L_KIND];
        var n = (r[L_ROWS] instanceof Lang.Number) ? r[L_ROWS] : 0;
        if (kind == K_WIPED) {
            return "totals cleared";
        }
        if (kind == K_OK) {
            return n.toString() + (r[L_WHAT] == W_SAMPLES ? " samples saved" : " days saved");
        }
        if (kind == K_FAIL) {
            return reasonWords(r[L_ERR]);
        }
        if (kind == K_STOPPED) {
            return "stopped at " + n.toString();
        }
        if (kind == K_EXIT) {
            return "app was closed";
        }
        return "app died mid-backup";
    }

    //! FitExport's failure tokens as something the user can act on. The token
    //! itself stays on the diagnostics screen for us.
    function reasonWords(err) {
        if (err == null) {
            return "unknown reason";
        }
        var e = err.toString();
        if (e.equals("noapi")) {
            return "no FIT support";
        }
        if (e.equals("busy")) {
            return "watch is recording";
        }
        if (e.equals("nodata")) {
            return "nothing to save";
        }
        if (e.equals("nosess")) {
            return "no file could open";
        }
        if (e.equals("stale")) {
            return "old file still open";
        }
        if (e.equals("fields")) {
            return "columns refused";
        }
        if (e.equals("nofield")) {
            return "FIT fields not supported";
        }
        if (e.equals("toomany")) {
            return "too many FIT columns";
        }
        if (e.equals("start")) {
            return "would not start";
        }
        if (e.equals("save")) {
            return "could not save";
        }
        if (e.equals("user")) {
            return "you stopped it";
        }
        if (e.equals("exit")) {
            return "app was closed";
        }
        return e;
    }

    //! "15:40", or "--:--" with nothing recorded.
    function timeText() {
        var epoch = at();
        if (epoch == null) {
            return "--:--";
        }
        var info = Gregorian.info(new Time.Moment(epoch), Time.FORMAT_SHORT);
        return info.hour.format("%02d") + ":" + info.min.format("%02d");
    }

    //! "15:40 today" / "15:40 Jul 27" — enough to tell a fresh result from a
    //! stale one at a glance, which is the whole point of persisting it.
    function whenText() {
        var epoch = at();
        if (epoch == null) {
            return "never";
        }
        var info = Gregorian.info(new Time.Moment(epoch), Time.FORMAT_SHORT);
        var now = Gregorian.info(Time.now(), Time.FORMAT_SHORT);
        if (info.year == now.year && info.month == now.month && info.day == now.day) {
            return timeText() + " today";
        }
        var mo = info.month;
        var name = (mo >= 1 && mo <= 12) ? MON[mo - 1] : "?";
        return timeText() + " " + name + " " + info.day.toString();
    }

    //! Raw row for the diagnostics screen — tokens, not prose.
    function tokenLine() {
        var r = last();
        if (r == null) {
            return "none";
        }
        return "k=" + r[L_KIND].toString()
            + " w=" + r[L_WHAT].toString()
            + " a=" + (r[L_AUTO] == true ? "T" : "F")
            + " n=" + r[L_ROWS].toString()
            + " e=" + (r[L_ERR] == null ? "-" : r[L_ERR].toString())
            + " #" + seq().toString();
    }
}
