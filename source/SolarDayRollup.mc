using Toybox.Application as App;
using Toybox.Lang;
using Toybox.System;
using Toybox.Time;
using Toybox.Time.Gregorian;

//! Background-safe day HISTORY rollups from the raw sample ring.
//! SolarEstimates is (:glance) and pulls TodaySolarData — too heavy for the
//! temporal-event process. This module only walks compact SolarLogger rows and
//! writes the same Storage "days" arrays the UI already reads.
//!
//! Why it exists: the sample ring is ~24 h. Without a rollup writer in
//! background, any calendar day the app never opens is never sealed and then
//! ages out of the buffer. Updating on every sample keeps HISTORY alive with
//! the UI closed; sealing prior local days still present in the buffer fixes
//! the "opened next morning, only today updated" hole.
(:background)
module SolarDayRollup {

    //! Must match SolarEstimates.DAYS_KEY / MAX_DAYS (Storage contract).
    const DAYS_KEY = "days";
    const MAX_DAYS = 31;
    //! Last local dayId whose rollup was synced (including live "today").
    const CURSOR_KEY = "rollupDay";

    const MAX_INTERVAL_SEC = 15 * 60;
    const HIGH_SOLAR = 20;
    const SOLAR_MAX_PCT_PER_H = 1.38;
    const POST_CHARGE_GUARD_SEC = 30 * 60;
    const FULL_BATTERY_PCT = 99.5;
    const PCT_PER_INTENSITY_H = 0.46;

    //! After a new sample (background) or on UI open: refresh today from the
    //! buffer and seal any prior local day still represented there.
    function syncFromSamples() {
        var samples = SolarLogger.getRawSamples();
        if (samples == null || samples.size() < 2) {
            return;
        }

        var todayStart = startOfLocalDayEpoch();
        var today = dayIdFromEpoch(todayStart);
        var nWritten = 0;

        // Prior days first so a rollover seals yesterday before today is written.
        // The ring is ~24 h, so at most yesterday and the day before can still
        // have rows; walk a fixed 2-day lookback — no dayId list allocation.
        for (var back = 2; back >= 1; back--) {
            var priorStart = todayStart - (back * 86400);
            var priorId = dayIdFromEpoch(priorStart);
            var priorEnd = priorStart + 86400;
            var priorEntry = rollupEntryForDay(priorId, priorStart, priorEnd, samples);
            if (priorEntry != null) {
                if (upsertDay(priorEntry, false)) {
                    nWritten += 1;
                }
            }
        }

        var todayEntry = rollupEntryForDay(today, todayStart, todayStart + 86400, samples);
        if (todayEntry != null) {
            if (upsertDay(todayEntry, true)) {
                nWritten += 1;
            }
        }

        App.Storage.setValue(CURSOR_KEY, today);
        DebugLog.line("bgrollup t=" + DebugLog.nowHms()
            + " day=" + today
            + " wrote=" + nWritten
            + " n=" + samples.size());
    }

    //! Build one Storage day row, or null when the window lacks enough samples.
    //! Layout matches SolarEstimates.dayEntry(): 
    //! [dayId, exposure, estPct, usbMin, sunHours, peak, avg, firstSun, lastSun]
    function rollupEntryForDay(dayId, dayStart, dayEnd, samples) {
        var exposure = 0.0;
        var sunTime = 0.0;
        var usbMin = 0.0;
        var solarObs = 0.0;
        var intervals = 0;
        var sampleCount = 0;
        var peak = 0.0;
        var sumPos = 0.0;
        var nPos = 0;
        var firstSun = null;
        var lastSun = null;
        var lastChargeT = null;

        var prevT = null;
        var prevSi = null;
        var prevB = null;
        var prevC = false;
        var havePrev = false;

        for (var i = 0; i < samples.size(); i++) {
            var row = samples[i];
            if (!SolarLogger.isRow(row)) {
                continue;
            }
            var t = row[SolarLogger.R_T];
            if (t == null) {
                continue;
            }
            // Keep one sample before the window so the first in-day interval
            // still has a left endpoint (mirrors computeToday's lastT carry).
            if (t >= dayEnd) {
                break;
            }

            var si = row[SolarLogger.R_SI];
            var b = row[SolarLogger.R_B];
            var c = row[SolarLogger.R_C] ? true : false;

            if (t >= dayStart) {
                sampleCount += 1;
                var sVal = solarForIntegral(si);
                if (sVal > peak) {
                    peak = sVal;
                }
                if (sVal > 0) {
                    sumPos += sVal;
                    nPos += 1;
                    if (firstSun == null) {
                        firstSun = t;
                    }
                    lastSun = t;
                }
            }

            if (havePrev) {
                var t1 = t;
                // Attribute the interval to this day when its end is inside it.
                if (t1 >= dayStart && t1 < dayEnd) {
                    var dt = t1 - prevT;
                    if (dt > 0) {
                        if (dt > MAX_INTERVAL_SEC) {
                            dt = MAX_INTERVAL_SEC;
                        }
                        var hours = dt / 3600.0;
                        intervals += 1;
                        var known = siKnown(prevSi) && siKnown(si);
                        var siAvg = 0.0;
                        if (known) {
                            siAvg = (solarForIntegral(prevSi) + solarForIntegral(si)) / 2.0;
                            exposure += (siAvg / 100.0) * hours;
                            if (intervalHasSun(prevSi, si)) {
                                sunTime += hours;
                            }
                        }
                        var usb = prevC || c;
                        if (usb) {
                            usbMin += hours * 60.0;
                        }
                        if (prevB != null && b != null) {
                            var db = b - prevB;
                            if (db > 0) {
                                if (!usb && known) {
                                    var offSec = lastChargeT == null ? null : prevT - lastChargeT;
                                    if (solarGainCredible(db, hours, siAvg, offSec, prevB, b)) {
                                        solarObs += db;
                                    }
                                }
                            }
                        }
                    }
                }
            }

            prevT = t;
            prevSi = si;
            prevB = b;
            prevC = c;
            havePrev = true;
            if (c) {
                lastChargeT = t;
            }
        }

        if (sampleCount < 2 || intervals == 0) {
            return null;
        }

        var estPct = solarObs > 0.0 ? solarObs : (exposure * pctPerIntensityH());
        var avg = nPos > 0 ? sumPos / nPos : 0.0;
        var fs = firstSun == null ? 0 : firstSun;
        var ls = lastSun == null ? 0 : lastSun;
        return [dayId, exposure, estPct, usbMin, sunTime, peak, avg, fs, ls];
    }

    //! Insert or replace a day row. For past days, never shrink a richer sealed
    //! rollup once morning samples have aged out of the ring (live today always
    //! replaces). Returns true when Storage was written.
    function upsertDay(entry, isToday) {
        if (entry == null || entry.size() < 9) {
            return false;
        }
        var dayId = entry[0];
        var days = App.Storage.getValue(DAYS_KEY);
        if (days == null || !(days instanceof Lang.Array)) {
            days = [];
        }

        var idx = -1;
        for (var i = 0; i < days.size(); i++) {
            var e = days[i];
            if ((e instanceof Lang.Array) && e.size() > 0 && e[0] != null && dayId.equals(e[0])) {
                idx = i;
                break;
            }
        }

        if (idx >= 0 && !isToday) {
            var old = days[idx];
            // Prefer the larger exposure — a partial recompute after the ring
            // slid must not grind a sealed day down toward zero.
            if (old instanceof Lang.Array && old.size() >= 2
                    && old[1] != null && entry[1] != null
                    && old[1].toFloat() > entry[1].toFloat()) {
                return false;
            }
        }

        var next;
        if (idx >= 0) {
            next = [];
            for (var j = 0; j < days.size(); j++) {
                next.add(j == idx ? entry : days[j]);
            }
        } else {
            next = insertChronological(days, entry);
        }

        if (next.size() > MAX_DAYS) {
            var trimmed = [];
            var start = next.size() - MAX_DAYS;
            for (var k = start; k < next.size(); k++) {
                trimmed.add(next[k]);
            }
            next = trimmed;
        }

        App.Storage.setValue(DAYS_KEY, next);
        return true;
    }

    //! Rebuild days with entry inserted by dayId string order (YYYY-MM-DD).
    function insertChronological(days, entry) {
        var dayId = entry[0];
        var out = [];
        var placed = false;
        for (var i = 0; i < days.size(); i++) {
            var e = days[i];
            if (!placed && (e instanceof Lang.Array) && e.size() > 0 && e[0] != null) {
                if (dayId.compareTo(e[0].toString()) < 0) {
                    out.add(entry);
                    placed = true;
                }
            }
            out.add(e);
        }
        if (!placed) {
            out.add(entry);
        }
        return out;
    }

    function startOfLocalDayEpoch() {
        var info = Gregorian.info(Time.now(), Time.FORMAT_SHORT);
        return localMidnightEpoch(info.year, info.month, info.day);
    }

    function localMidnightEpoch(y, mo, d) {
        var m = Gregorian.moment({
            :year => y,
            :month => mo,
            :day => d,
            :hour => 0,
            :min => 0,
            :sec => 0
        });
        return m.value() - System.getClockTime().timeZoneOffset;
    }

    function dayIdFromEpoch(epoch) {
        var info = Gregorian.info(new Time.Moment(epoch), Time.FORMAT_SHORT);
        return info.year.format("%04d") + "-" + info.month.format("%02d") + "-" + info.day.format("%02d");
    }

    //! Light read of trusted calib k; falls back to the fenix-spec default.
    //! Avoids pulling SolarEstimates / computeCalibration into background.
    function pctPerIntensityH() {
        var c = App.Storage.getValue("calib");
        if (c == null || !(c instanceof Lang.Array) || c.size() < 6) {
            return PCT_PER_INTENSITY_H;
        }
        var darkHours = c[1];
        var darkDrop = c[2];
        var sunHours = c[3];
        var sunDrop = c[4];
        var exposure = c[5];
        if (darkHours == null || sunHours == null || exposure == null) {
            return PCT_PER_INTENSITY_H;
        }
        if (darkHours < 24.0 || sunHours < 6.0 || exposure < 2.0) {
            return PCT_PER_INTENSITY_H;
        }
        var saved = (darkDrop / darkHours) * sunHours - sunDrop;
        if (saved < 2.0) {
            return PCT_PER_INTENSITY_H;
        }
        var k = saved / exposure;
        if (k < 0.005 || k > 1.0) {
            return PCT_PER_INTENSITY_H;
        }
        return k;
    }

    function solarForIntegral(si) {
        if (si == null || si < 0) {
            return 0.0;
        }
        return si.toFloat();
    }

    function siKnown(si) {
        return si != null && si >= 0;
    }

    function intervalHasSun(si0, si1) {
        return siKnown(si0) && siKnown(si1) && si0 > 0 && si1 > 0;
    }

    function solarGainCredible(db, hours, siAvg, offChargerSec, b0, b1) {
        if (db <= 0 || hours <= 0) {
            return false;
        }
        if (siAvg < HIGH_SOLAR) {
            return false;
        }
        if (offChargerSec != null && offChargerSec < POST_CHARGE_GUARD_SEC) {
            return false;
        }
        if (b0 != null && b0 >= FULL_BATTERY_PCT) {
            return false;
        }
        if (b1 != null && b1 >= FULL_BATTERY_PCT) {
            return false;
        }
        return (db / hours) <= (SOLAR_MAX_PCT_PER_H * (siAvg / 100.0));
    }
}
