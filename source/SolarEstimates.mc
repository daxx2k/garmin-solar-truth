using Toybox.Application as App;
using Toybox.Lang;
using Toybox.System;
using Toybox.Time;
using Toybox.Time.Gregorian;

//! Honest Phase-1+ estimates from SolarLogger ring buffer.
//! All harvest / runtime figures are ESTIMATES — not milliwatts, not Garmin kLux·h.
//!
//! Exposure proxy (intensity·h):
//!   exposureScore = sum( max(0, si) / 100 * intervalHours )
//!   si is CIQ solarIntensity 0..100 (negatives treated as 0 for integral).
//!
//! Est. battery % gain:
//!   1) Observed: sum of positive Δbattery while !USB and solar >= HIGH_SOLAR
//!   2) Else heuristic: exposureScore * effectivePctPerIntensityH()
//!      i.e. the personally measured %/intensity·h once enough evidence has
//!      accumulated, otherwise the PCT_PER_INTENSITY_H default of 0.46
//!      (~2.2 intensity·h ≈ +1% battery) — see source/README.md.
//!
//! USB rises (charging==true) are NOT attributed to solar.
//! (:glance) so computeToday()/getLastDay()/estimateRuntimeMinutes() are loaded
//! into the glance scope for SolarTruthGlanceView (whole-module for simplicity;
//! the fenix8solar glance budget easily covers it). Still fully available to the
//! main app, since the main build loads every scope.
(:glance)
module SolarEstimates {

    //! % battery per intensity·h — fallback used until the personal
    //! calibration below is trustworthy (see effectivePctPerIntensityH).
    //! Derived from Garmin's own fenix 8 Solar 51 mm figures: 29 d smartwatch
    //! mode becomes 48 d with 3 h/day at 50 klux, i.e. 3.45 %/day drops to
    //! 2.08 %/day, so ~1.37 % of pack is saved per 3 sunlit hours. Taking
    //! solarIntensity ≈ 100 at 50 klux gives 1.37 / 3.0 ≈ 0.46. Rounded to the
    //! conservative end of the plausible band (0.46–0.9, the spread being
    //! whether 50 klux reads as 100 or 50 on the sensor).
    const PCT_PER_INTENSITY_H = 0.46;
    //! Trust gates for the measured %/intensity·h. Battery level is reported in
    //! whole percent, so every accumulated drop carries a ~1 % quantisation
    //! floor; these keep that floor small next to the signal being measured.
    //! Zero-sun hours needed before darkRate is a usable baseline (~1 day of
    //! normal wear, ≥3 % of pack drained, so the 1 % step is a minor share).
    const CAL_MIN_DARK_H = 24.0;
    //! Sunlit hours needed on the other side of the comparison.
    const CAL_MIN_SUN_H = 6.0;
    //! Minimum accumulated exposure (intensity·h) in the denominator.
    const CAL_MIN_EXPOSURE = 2.0;
    //! The measured saving itself must clear ~2× the 1 % battery step, else it
    //! is a rounding artefact no matter how much time went into it.
    const CAL_MIN_SAVED_PCT = 2.0;
    //! Plausibility band for the measured constant. Upper bound is ~2× the
    //! figure implied by the fenix 8 Solar 51 mm spec (29 d → 48 d smartwatch
    //! mode on 3 h/day of 50 klux ⇒ ≈0.5 %/intensity·h); lower bound is
    //! "indistinguishable from no solar at all". Outside the band the
    //! measurement is not trustworthy — fall back, never clamp into range.
    const CAL_MIN_K = 0.005;
    const CAL_MAX_K = 1.0;
    //! Plausibility clamp on one interval's battery movement, in % of pack per
    //! hour, applied in both directions. Off USB a fenix-class pack cannot move
    //! at 20 %/h — that is a full pack in five hours, well past the worst
    //! multiband-GPS-with-music drain, and the sun cannot add at anything like
    //! that rate either. A step that steep is a gauge recalibration after a
    //! charge, or a charge session that fitted entirely between two samples.
    //! The totals are permanent, so such an interval is dropped rather than
    //! folded in: one bogus drop would bias the calibration forever.
    const CAL_MAX_PCT_PER_H = 20.0;
    //! A stored lastT this far ahead of the clock cannot come from a 5-minute
    //! sampler, so it is a clock jump that has since been corrected. Left alone
    //! it would stall accumulation until real time caught up.
    const CAL_MAX_FUTURE_SEC = 3600;
    //! Solar efficiency % above which positive Δbattery may count as solar.
    const HIGH_SOLAR = 20;
    //! Physical ceiling on what the panel can add, in % of pack per hour at
    //! full intensity; scaled by the interval's intensity before use. Three
    //! times the spec figure of 0.46 %/intensity·h, so the whole plausible
    //! band is inside it and only impossible rates are refused.
    //!
    //! Battery level is quantised to whole percent, so one +1 % step across a
    //! 5-minute interval reads as 12 %/h and is refused here. That is the
    //! intent, not collateral damage: at 0.46 %/intensity·h a full-sun hour
    //! buys about half a percent, so a whole percent appearing inside five
    //! minutes is a charge or a gauge movement, never sunlight.
    const SOLAR_MAX_PCT_PER_H = 1.38;
    //! Battery movement just after the cable comes out is the gauge settling,
    //! not the sun — a pack that has been topped up keeps reporting a rising
    //! level for a while. Intervals this close behind a charging sample carry
    //! no usable drain or gain signal.
    const POST_CHARGE_GUARD_SEC = 30 * 60;
    //! A pack reading full is saturated: it can show neither drain nor gain,
    //! so an interval spent there measures nothing. It is also where a watch
    //! sits for hours on a development machine — and `charging` has been seen
    //! to read false once a charge completes, which is the one regime that can
    //! otherwise pour charger energy into the solar totals.
    const FULL_BATTERY_PCT = 99.5;
    //! Cap a single interval so a long gap does not dominate the integral.
    const MAX_INTERVAL_SEC = 15 * 60;
    //! Verdict thresholds on today's exposureScore (intensity·h).
    const VERDICT_HELPING = 0.5;
    const VERDICT_STRONG = 2.0;

    //! Compute TODAY from embedded FIT arrays (no dict alloc) + Storage logger tail.
    //! Embedded series is never wiped; Storage rows with t > last embedded are appended.
    //! The logger tail is read in place as compact rows (SolarLogger.R_*): this
    //! runs in the glance, where a rehydrated buffer would not fit.
    function computeToday() {
        var storage = SolarLogger.getRawSamples();
        var storageCount = storage == null ? 0 : storage.size();
        var usedEmbedded = TodaySolarData.isForToday() && TodaySolarData.COUNT > 1;
        var embCount = usedEmbedded ? TodaySolarData.COUNT : 0;

        var dayStart = startOfLocalDayEpoch();
        var exposure = 0.0;
        var sunTime = 0.0;   // hours where any sun was present (matches "Time with sun")
        var usbMin = 0.0;
        var usbPct = 0.0;
        var solarObs = 0.0;
        var intervals = 0;
        var sampleCount = 0;
        var lastT = null;
        //! Raw intensity of the previous sample, sentinel included: the
        //! "unknown" case has to survive as far as the interval maths, which
        //! skips such an interval instead of reading it as darkness.
        var lastSi = null;
        var lastB = null;
        var lastC = false;
        //! Timestamp of the most recent sample seen charging, or null if none.
        //! Drives the post-charge guard — see solarGainCredible().
        var lastChargeT = null;

        if (usedEmbedded) {
            var nEmb = TodaySolarData.COUNT;
            if (nEmb > TodaySolarData.T.size()) {
                nEmb = TodaySolarData.T.size();
            }
            if (nEmb > TodaySolarData.SI.size()) {
                nEmb = TodaySolarData.SI.size();
            }
            sampleCount = nEmb;
            for (var i = 1; i < nEmb; i++) {
                var t0 = TodaySolarData.T[i - 1];
                var t1 = TodaySolarData.T[i];
                if (t1 < dayStart) {
                    continue;
                }
                var dt = t1 - t0;
                if (dt <= 0) {
                    continue;
                }
                if (dt > MAX_INTERVAL_SEC) {
                    dt = MAX_INTERVAL_SEC;
                }
                var hours = dt / 3600.0;
                intervals += 1;
                var raw0 = TodaySolarData.SI[i - 1];
                var raw1 = TodaySolarData.SI[i];
                if (siKnown(raw0) && siKnown(raw1)) {
                    var si0 = solarForIntegral(raw0);
                    var si1 = solarForIntegral(raw1);
                    exposure += ((si0 + si1) / 2.0 / 100.0) * hours;
                    if (intervalHasSun(raw0, raw1)) {
                        sunTime += hours;
                    }
                }
            }
            lastT = TodaySolarData.T[nEmb - 1];
            lastSi = TodaySolarData.SI[nEmb - 1];
            lastB = null;
            lastC = false;
        }

        // Append CIQ Storage samples after embedded (or full day if no embed).
        if (storage != null) {
            for (var j = 0; j < storage.size(); j++) {
                var row = storage[j];
                if (!SolarLogger.isRow(row)) {
                    continue;
                }
                var rt = row[SolarLogger.R_T];
                if (rt == null) {
                    continue;
                }
                if (lastT != null && rt <= lastT) {
                    continue;
                }
                sampleCount += 1;
                if (lastT != null) {
                    var t0s = lastT;
                    var t1s = rt;
                    if (t1s >= dayStart) {
                        var dts = t1s - t0s;
                        if (dts > 0) {
                            if (dts > MAX_INTERVAL_SEC) {
                                dts = MAX_INTERVAL_SEC;
                            }
                            var hs = dts / 3600.0;
                            intervals += 1;
                            var siA = lastSi;
                            var siB = row[SolarLogger.R_SI];
                            var siAvgS = 0.0;
                            var siKnownS = siKnown(siA) && siKnown(siB);
                            if (siKnownS) {
                                siAvgS = (solarForIntegral(siA) + solarForIntegral(siB)) / 2.0;
                                exposure += (siAvgS / 100.0) * hs;
                                if (intervalHasSun(siA, siB)) {
                                    sunTime += hs;
                                }
                            }

                            var c0 = lastC;
                            var c1 = row[SolarLogger.R_C] ? true : false;
                            var usb = c0 || c1;
                            if (usb) {
                                usbMin += hs * 60.0;
                            }
                            var b0 = lastB;
                            var b1 = row[SolarLogger.R_B];
                            if (b0 != null && b1 != null) {
                                var db = b1 - b0;
                                if (db > 0) {
                                    if (usb) {
                                        usbPct += db;
                                    } else if (siKnownS) {
                                        var offSec = lastChargeT == null ? null : t0s - lastChargeT;
                                        if (solarGainCredible(db, hs, siAvgS, offSec, b0, b1)) {
                                            solarObs += db;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                lastT = rt;
                lastSi = row[SolarLogger.R_SI];
                lastB = row[SolarLogger.R_B];
                lastC = row[SolarLogger.R_C] ? true : false;
                if (lastC) {
                    lastChargeT = rt;
                }
            }
        }

        // Second pass over TODAY's samples for the DETAILS card:
        //   peak intensity, average positive intensity, first/last sun (window).
        var peak = 0.0;
        var sumPos = 0.0;
        var nPos = 0;
        var firstSun = null;
        var lastSun = null;
        var embLastEpoch = null;
        if (usedEmbedded) {
            var ne = TodaySolarData.COUNT;
            if (ne > TodaySolarData.T.size()) {
                ne = TodaySolarData.T.size();
            }
            if (ne > TodaySolarData.SI.size()) {
                ne = TodaySolarData.SI.size();
            }
            for (var di = 0; di < ne; di++) {
                var dt2 = TodaySolarData.T[di];
                if (dt2 < dayStart) {
                    continue;
                }
                var dsi = solarForIntegral(TodaySolarData.SI[di]);
                if (dsi > peak) {
                    peak = dsi;
                }
                if (dsi > 0) {
                    sumPos += dsi;
                    nPos += 1;
                    if (firstSun == null) {
                        firstSun = dt2;
                    }
                    lastSun = dt2;
                }
            }
            if (ne > 0) {
                embLastEpoch = TodaySolarData.T[ne - 1];
            }
        }
        if (storage != null) {
            for (var si2 = 0; si2 < storage.size(); si2++) {
                var r2 = storage[si2];
                if (!SolarLogger.isRow(r2)) {
                    continue;
                }
                var r2t = r2[SolarLogger.R_T];
                if (r2t == null) {
                    continue;
                }
                if (r2t < dayStart) {
                    continue;
                }
                if (embLastEpoch != null && r2t <= embLastEpoch) {
                    continue;
                }
                var rsi = solarForIntegral(r2[SolarLogger.R_SI]);
                if (rsi > peak) {
                    peak = rsi;
                }
                if (rsi > 0) {
                    sumPos += rsi;
                    nPos += 1;
                    if (firstSun == null) {
                        firstSun = r2t;
                    }
                    lastSun = r2t;
                }
            }
        }
        var avgPos = nPos > 0 ? sumPos / nPos : 0.0;

        var out = {
            :ready => false,
            :sampleCount => sampleCount,
            :exposure => exposure,
            :sunHours => sunTime,
            :peak => peak,
            :avg => avgPos,
            :firstSun => firstSun,
            :lastSun => lastSun,
            :estPct => null,
            :estPctSource => "none",
            :runtimeMin => null,
            :usbMinutes => usbMin,
            :usbPctGain => usbPct,
            :solarPctObs => solarObs,
            :verdict => "Unknown",
            :status => "logging…",
            :dataSource => "none",
            :dataSourceDetail => "none",
            :embeddedCount => embCount,
            :storageCount => storageCount
        };

        if (usedEmbedded) {
            if (storageCount > 0 && sampleCount > embCount) {
                out[:dataSource] = TodaySolarData.SOURCE_LABEL + "+log";
            } else {
                out[:dataSource] = TodaySolarData.SOURCE_LABEL;
            }
            out[:dataSourceDetail] = TodaySolarData.SOURCE_DETAIL;
        } else {
            out[:dataSource] = "CIQ Storage";
            out[:dataSourceDetail] = "logger";
        }

        if (sampleCount == 0) {
            out[:status] = "logging…";
            return out;
        }
        if (sampleCount < 2 || intervals == 0) {
            out[:status] = "need more samples";
            return out;
        }

        out[:ready] = true;
        out[:status] = "ok";
        var heuristic = exposure * effectivePctPerIntensityH();
        var estPct;
        var src;
        if (solarObs > 0.0) {
            estPct = solarObs;
            src = "observed";
        } else {
            estPct = heuristic;
            src = "heuristic";
        }
        out[:estPct] = estPct;
        out[:estPctSource] = src;
        out[:runtimeMin] = estimateRuntimeMinutes(estPct);
        out[:verdict] = verdictFor(exposure, estPct);
        return out;
    }

    //! Epoch seconds of LOCAL midnight starting the given calendar date.
    //! Gregorian.moment() reads its options as UTC while Gregorian.info() hands
    //! back the local date, so the raw moment is local midnight plus the UTC
    //! offset — on a UTC+2 watch that would make the app's day run 02:00→02:00
    //! and leave dayStart in the future until 02:00 every night. Every day
    //! window goes through here so consecutive days keep tiling exactly.
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

    //! Local-day start epoch for a "YYYY-MM-DD" id, or null if unparseable.
    function dayStartEpochFromId(dayId) {
        if (dayId == null) {
            return null;
        }
        var s = dayId.toString();
        if (s.length() < 10) {
            return null;
        }
        var y = s.substring(0, 4).toNumber();
        var mo = s.substring(5, 7).toNumber();
        var d = s.substring(8, 10).toNumber();
        if (y == null || mo == null || d == null) {
            return null;
        }
        return localMidnightEpoch(y, mo, d);
    }

    //! DETAILS fallback: reconstruct a past day's peak / average / sun window /
    //! sun hours / exposure directly from the raw sample buffer, for days stored
    //! before the rollup carried those fields. The buffer only spans ~24 h and
    //! slides forward, so a reconstruction of an older day is partial by nature
    //! and must never displace a stored rollup that already has detail.
    //! The interval maths mirrors computeToday() exactly (same 15-min cap, same
    //! trapezoid average), so a day rebuilt here lines up with a day measured
    //! live — see repairEmbeddedDay(), which relies on that.
    function computeDayDetail(dayId) {
        return computeDayDetailFrom(dayId, SolarLogger.getRawSamples());
    }

    //! computeDayDetail() against an already-read sample buffer (compact rows,
    //! SolarLogger.R_*), so a caller looping over many days reads Storage once
    //! rather than once per day.
    function computeDayDetailFrom(dayId, storage) {
        var out = {
            :ready => false,
            :peak => null,
            :avg => null,
            :sunHours => null,
            :exposure => null,
            :firstSun => null,
            :lastSun => null
        };
        var ds = dayStartEpochFromId(dayId);
        if (ds == null) {
            return out;
        }
        var de = ds + 86400;
        var peak = 0.0;
        var sumPos = 0.0;
        var nPos = 0;
        var firstSun = null;
        var lastSun = null;
        var sunTime = 0.0;
        var exposure = 0.0;
        var lastT = 0;
        var lastSi = null;   // raw, sentinel included — see siKnown()
        var hasLast = false;
        var n = 0;
        var embLast = null;

        // Embedded device-FIT day (e.g. the last full day) lives here, not in the
        // storage buffer — scan it first when it matches the requested day.
        if (TodaySolarData.DAY.equals(dayId) && TodaySolarData.COUNT > 0) {
            var ne = TodaySolarData.COUNT;
            if (ne > TodaySolarData.T.size()) {
                ne = TodaySolarData.T.size();
            }
            if (ne > TodaySolarData.SI.size()) {
                ne = TodaySolarData.SI.size();
            }
            for (var e = 0; e < ne; e++) {
                var et = TodaySolarData.T[e];
                var esiRaw = TodaySolarData.SI[e];
                var esi = solarForIntegral(esiRaw);
                n += 1;
                if (esi > peak) {
                    peak = esi;
                }
                if (esi > 0) {
                    sumPos += esi;
                    nPos += 1;
                    if (firstSun == null) {
                        firstSun = et;
                    }
                    lastSun = et;
                }
                if (hasLast && siKnown(lastSi) && siKnown(esiRaw)) {
                    var edt = et - lastT;
                    if (edt > 0) {
                        if (edt > MAX_INTERVAL_SEC) {
                            edt = MAX_INTERVAL_SEC;
                        }
                        var eHours = edt / 3600.0;
                        var eAvg = (solarForIntegral(lastSi) + esi) / 2.0;
                        exposure += (eAvg / 100.0) * eHours;
                        if (intervalHasSun(lastSi, esiRaw)) {
                            sunTime += eHours;
                        }
                    }
                }
                lastT = et;
                lastSi = esiRaw;
                hasLast = true;
            }
            if (ne > 0) {
                embLast = TodaySolarData.T[ne - 1];
            }
        }

        // Append any logged storage samples for that day (after embedded tail).
        if (storage != null) {
            for (var i = 0; i < storage.size(); i++) {
                var r = storage[i];
                if (!SolarLogger.isRow(r)) {
                    continue;
                }
                var t = r[SolarLogger.R_T];
                if (t == null) {
                    continue;
                }
                if (t < ds || t >= de) {
                    continue;
                }
                if (embLast != null && t <= embLast) {
                    continue;
                }
                var siRaw = r[SolarLogger.R_SI];
                var si = solarForIntegral(siRaw);
                n += 1;
                if (si > peak) {
                    peak = si;
                }
                if (si > 0) {
                    sumPos += si;
                    nPos += 1;
                    if (firstSun == null) {
                        firstSun = t;
                    }
                    lastSun = t;
                }
                if (hasLast && siKnown(lastSi) && siKnown(siRaw)) {
                    var dt = t - lastT;
                    if (dt > 0) {
                        if (dt > MAX_INTERVAL_SEC) {
                            dt = MAX_INTERVAL_SEC;
                        }
                        var hours = dt / 3600.0;
                        var avgS = (solarForIntegral(lastSi) + si) / 2.0;
                        exposure += (avgS / 100.0) * hours;
                        if (intervalHasSun(lastSi, siRaw)) {
                            sunTime += hours;
                        }
                    }
                }
                lastT = t;
                lastSi = siRaw;
                hasLast = true;
            }
        }
        if (n == 0) {
            return out;
        }
        out[:ready] = true;
        out[:peak] = peak;
        out[:avg] = nPos > 0 ? sumPos / nPos : 0.0;
        out[:sunHours] = sunTime;
        out[:exposure] = exposure;
        out[:firstSun] = firstSun;
        out[:lastSun] = lastSun;
        return out;
    }

    //! Compute today's dashboard estimates from sample dicts (:t :si :b :c).
    //! Returns a Dictionary with keys used by SolarTruthView.
    function compute(samples) {
        var out = {
            :ready => false,
            :sampleCount => 0,
            :exposure => 0.0,
            :estPct => null,
            :estPctSource => "none",
            :runtimeMin => null,
            :usbMinutes => 0.0,
            :usbPctGain => 0.0,
            :solarPctObs => 0.0,
            :verdict => "Unknown",
            :status => "logging…",
            :dataSource => "none",
            :dataSourceDetail => "none",
            :embeddedCount => 0,
            :storageCount => 0
        };

        if (samples == null) {
            return out;
        }
        var n = samples.size();
        out[:sampleCount] = n;
        if (n == 0) {
            out[:status] = "logging…";
            return out;
        }
        if (n < 2) {
            out[:status] = "need more samples";
            return out;
        }

        var dayStart = startOfLocalDayEpoch();
        var exposure = 0.0;
        var usbMin = 0.0;
        var usbPct = 0.0;
        var solarObs = 0.0;
        var intervals = 0;
        var lastChargeT = null;

        for (var i = 1; i < n; i++) {
            var a = samples[i - 1];
            var b = samples[i];
            if (a == null || b == null) {
                continue;
            }
            var t0 = a[:t];
            var t1 = b[:t];
            if (t0 == null || t1 == null) {
                continue;
            }
            // Attribute interval to "today" if the later sample is today.
            if (t1 < dayStart) {
                continue;
            }

            var dt = t1 - t0;
            if (dt <= 0) {
                continue;
            }
            if (dt > MAX_INTERVAL_SEC) {
                dt = MAX_INTERVAL_SEC;
            }
            var hours = dt / 3600.0;
            intervals += 1;

            // Trapezoid-ish: average intensity over the interval, but only when
            // both ends are measurements — see siKnown().
            var siRaw0 = a[:si];
            var siRaw1 = b[:si];
            var known = siKnown(siRaw0) && siKnown(siRaw1);
            var siAvg = 0.0;
            if (known) {
                siAvg = (solarForIntegral(siRaw0) + solarForIntegral(siRaw1)) / 2.0;
                exposure += (siAvg / 100.0) * hours;
            }

            var c0 = a[:c] ? true : false;
            var c1 = b[:c] ? true : false;
            var usb = c0 || c1;
            if (usb) {
                usbMin += hours * 60.0;
            }

            var b0 = a[:b];
            var b1 = b[:b];
            if (b0 != null && b1 != null) {
                var db = b1 - b0;
                if (db > 0) {
                    if (usb) {
                        usbPct += db;
                    } else if (known) {
                        var offSec = lastChargeT == null ? null : t0 - lastChargeT;
                        if (solarGainCredible(db, hours, siAvg, offSec, b0, b1)) {
                            solarObs += db;
                        }
                    }
                }
            }
            if (c1) {
                lastChargeT = t1;
            }
        }

        out[:exposure] = exposure;
        out[:usbMinutes] = usbMin;
        out[:usbPctGain] = usbPct;
        out[:solarPctObs] = solarObs;

        if (intervals == 0) {
            out[:status] = "need more samples";
            return out;
        }

        out[:ready] = true;
        out[:status] = "ok";

        var heuristic = exposure * effectivePctPerIntensityH();
        var estPct;
        var src;
        if (solarObs > 0.0) {
            estPct = solarObs;
            src = "observed";
        } else {
            estPct = heuristic;
            src = "heuristic";
        }
        out[:estPct] = estPct;
        out[:estPctSource] = src;
        out[:runtimeMin] = estimateRuntimeMinutes(estPct);
        out[:verdict] = verdictFor(exposure, estPct);
        return out;
    }

    function solarForIntegral(si) {
        if (si == null) {
            return 0.0;
        }
        if (si < 0) {
            return 0.0;
        }
        return si.toFloat();
    }

    //! True when an intensity reading is a measurement rather than the sensor's
    //! "unavailable" sentinel. CIQ reports -1 (and the logger stores null when
    //! the field is absent) when it cannot read the panel. That is not
    //! darkness: counted as zero it would invent both exposure the watch never
    //! saw and a dark-drain baseline that was never measured. Every consumer
    //! that integrates over an interval must therefore ask this first, and skip
    //! the interval rather than substitute a number.
    function siKnown(si) {
        return si != null && si >= 0;
    }

    //! Sun time is only credited when BOTH ends of the interval saw sun. With
    //! one end dark the sun arrived (or left) somewhere inside the interval and
    //! its length says nothing about when; crediting it whole is what turned a
    //! single stray reading of intensity 1, flanked by two capped 15-minute
    //! gaps, into half an hour of "time with sun" on 25 Jul.
    function intervalHasSun(si0, si1) {
        return siKnown(si0) && siKnown(si1) && si0 > 0 && si1 > 0;
    }

    //! True when a positive battery movement over an interval can physically be
    //! sunlight: intensity known and high at both ends, the charger gone for
    //! long enough that the gauge has settled, the pack not saturated at full,
    //! and a rate the panel could actually deliver at that intensity.
    //!
    //! Anything else is dropped whole rather than clamped into range: once a
    //! charger artefact is credited as solar it is indistinguishable from real
    //! gain, and the headline number the user reads is built from this sum.
    //! `offChargerSec` is null when no charging sample was seen at all.
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

    //! Map est % → rough runtime minutes using batteryInDays when available.
    function estimateRuntimeMinutes(estPct) {
        if (estPct == null) {
            return null;
        }
        var stats = System.getSystemStats();
        var daysFull = null;
        if (stats has :batteryInDays) {
            var bid = stats.batteryInDays;
            var batt = stats.battery;
            if (bid != null && batt != null && batt > 1.0) {
                // Scale remaining-days estimate up to a full-pack equivalent.
                daysFull = bid * (100.0 / batt);
            } else if (bid != null) {
                daysFull = bid;
            }
        }
        if (daysFull == null || daysFull <= 0) {
            // Fallback: ~14-day pack (tactix-class, mixed use) — still an ESTIMATE.
            daysFull = 14.0;
        }
        var hours = (estPct / 100.0) * daysFull * 24.0;
        return hours * 60.0;
    }

    function verdictFor(exposure, estPct) {
        if (exposure >= VERDICT_STRONG || (estPct != null && estPct >= 0.5)) {
            return "Strong";
        }
        if (exposure >= VERDICT_HELPING || (estPct != null && estPct >= 0.1)) {
            return "Helping";
        }
        if (exposure > 0.0 || (estPct != null && estPct > 0.0)) {
            return "Minimal";
        }
        return "Unknown";
    }

    function startOfLocalDayEpoch() {
        var info = Gregorian.info(Time.now(), Time.FORMAT_SHORT);
        return localMidnightEpoch(info.year, info.month, info.day);
    }

    //! Rolling multi-day history for the HISTORY card.
    const DAYS_KEY = "days";
    const MAX_DAYS = 31;   // enough for a "last month" summary

    function todayId() {
        var info = Gregorian.info(Time.now(), Time.FORMAT_SHORT);
        return info.year.format("%04d") + "-" + info.month.format("%02d") + "-" + info.day.format("%02d");
    }

    //! Maintain a ring buffer of daily rollups in Storage (key "days").
    //! Each entry is a serializable primitive array:
    //!   [dayId(String), exposure(Float), estPct(Float), usbMin(Float),
    //!    sunHours(Float), peak(Float), avg(Float), firstSun(Number), lastSun(Number)]
    //! firstSun/lastSun store 0 when there was no sun (sentinel for "unknown").
    //! The LAST entry is typically "today" and is updated in place on each call.
    //! Background SolarDayRollup.syncFromSamples() also writes this key so days
    //! are sealed without opening the UI; this path remains the richer today
    //! writer (embedded FIT + observed gain) when the app is open.
    function updateDayTotals(estimates) {
        if (estimates == null || estimates[:ready] == false) {
            return;
        }
        var day = todayId();
        var entry = dayEntry(day, estimates);

        var days = App.Storage.getValue(DAYS_KEY);
        if (days == null || !(days instanceof Lang.Array)) {
            days = [];
        }

        var n = days.size();
        var lastIsToday = false;
        if (n > 0) {
            var last = days[n - 1];
            if (last instanceof Lang.Array && last.size() > 0 && day.equals(last[0])) {
                lastIsToday = true;
            }
        }

        var copyEnd = lastIsToday ? n - 1 : n;   // drop stale "today" if replacing
        var start = 0;
        if (copyEnd + 1 > MAX_DAYS) {
            start = copyEnd + 1 - MAX_DAYS;       // trim oldest to fit MAX_DAYS
        }
        var next = [];
        for (var i = start; i < copyEnd; i++) {
            next.add(days[i]);
        }
        next.add(entry);
        App.Storage.setValue(DAYS_KEY, next);
    }

    //! Shape one rollup array from a computeToday()-style estimates dict. The
    //! only place the entry layout and its null/float coercions are written, so
    //! every producer of a stored day emits the exact same nine elements.
    function dayEntry(day, estimates) {
        var expo = estimates[:exposure] == null ? 0.0 : estimates[:exposure].toFloat();
        var pct = estimates[:estPct] == null ? 0.0 : estimates[:estPct].toFloat();
        var usb = estimates[:usbMinutes] == null ? 0.0 : estimates[:usbMinutes].toFloat();
        var sun = estimates[:sunHours] == null ? 0.0 : estimates[:sunHours].toFloat();
        var peak = estimates[:peak] == null ? 0.0 : estimates[:peak].toFloat();
        var avg = estimates[:avg] == null ? 0.0 : estimates[:avg].toFloat();
        var fs = estimates[:firstSun] == null ? 0 : estimates[:firstSun].toNumber();
        var ls = estimates[:lastSun] == null ? 0 : estimates[:lastSun].toNumber();
        return [day, expo, pct, usb, sun, peak, avg, fs, ls];
    }

    //! True when a rollup already carries the detail fields, i.e. it was written
    //! by the current updateDayTotals(): nine elements with a real peak.
    function hasStoredDetail(e) {
        return (e instanceof Lang.Array) && e.size() >= 9 && e[5] != null;
    }

    //! One-time migration: fill in peak/avg/window for older rollups that were
    //! frozen before those fields existed, reconstructing them from the raw
    //! sample buffer. Safe to call every launch — a stored entry that already
    //! has detail is skipped untouched, so this converges and then does nothing.
    //!
    //! It only ever ADDS missing detail. The reconstruction reads the ~24 h
    //! sample buffer, which no longer covers a past day in full (or at all), so
    //! treating it as authoritative would grind a correct rollup down to zero
    //! over the following days.
    function backfillDayDetails() {
        var days = App.Storage.getValue(DAYS_KEY);
        if (days == null || !(days instanceof Lang.Array)) {
            return;
        }
        var today = todayId();
        var changed = false;
        var samples = null;   // read lazily: usually nothing needs reconstructing
        var haveSamples = false;
        for (var i = 0; i < days.size(); i++) {
            var e = days[i];
            // Need at least the day id to reconstruct. Guard short/garbage rows.
            if (!(e instanceof Lang.Array) || e.size() < 1 || e[0] == null) {
                continue;
            }
            var dayId = e[0];
            // Never churn today's live rollup — updateDayTotals() owns it (its
            // sunHours comes from computeToday and is refreshed on every open).
            if (today.equals(dayId)) {
                continue;
            }
            if (hasStoredDetail(e)) {
                continue;   // already complete → nothing to add, and never redo it
            }
            if (!haveSamples) {
                samples = SolarLogger.getRawSamples();
                haveSamples = true;
            }
            var dd = computeDayDetailFrom(dayId, samples);
            if (dd == null || dd[:ready] == false) {
                continue;   // no source data to reconstruct from → leave as-is
            }
            // Stored values win field by field; the reconstruction only supplies
            // what the legacy entry never had. Defaults keep short legacy arrays
            // (size 4, or missing sunHours) safe.
            var expo = (e.size() >= 2 && e[1] != null) ? e[1] : 0.0;
            var pct = (e.size() >= 3 && e[2] != null) ? e[2] : 0.0;
            var usb = (e.size() >= 4 && e[3] != null) ? e[3] : 0.0;
            var sun = (e.size() >= 5 && e[4] != null)
                ? e[4]
                : (dd[:sunHours] == null ? 0.0 : dd[:sunHours].toFloat());
            var peak = dd[:peak] == null ? 0.0 : dd[:peak].toFloat();
            var avg = dd[:avg] == null ? 0.0 : dd[:avg].toFloat();
            var fs = dd[:firstSun] == null ? 0 : dd[:firstSun].toNumber();
            var ls = dd[:lastSun] == null ? 0 : dd[:lastSun].toNumber();
            var entry = [dayId, expo, pct, usb, sun, peak, avg, fs, ls];
            if (!entryEquals(e, entry)) {
                days[i] = entry;
                changed = true;
            }
        }
        if (changed) {
            App.Storage.setValue(DAYS_KEY, days);
        }
    }

    //! Element-wise equality for two rollup arrays (numeric == coerces 0/0.0),
    //! used so backfillDayDetails() skips the Storage write when the upgraded
    //! entry is identical to the stored one.
    function entryEquals(a, b) {
        if (!(a instanceof Lang.Array) || a.size() != b.size()) {
            return false;
        }
        for (var i = 0; i < b.size(); i++) {
            if (a[i] != b[i]) {
                return false;
            }
        }
        return true;
    }

    //! One-shot recovery of the single rollup that the old, over-eager backfill
    //! ground down to all zeros. That backfill rewrote past days from the ~24 h
    //! sample buffer on every open; as the buffer slid forward those entries
    //! decayed and finally froze at zero, and the samples behind them are gone.
    //! Only the day carried by the embedded device-FIT series can be rebuilt
    //! from real measurements, so only that day is ever considered.
    //!
    //! Deliberately narrow, since over-eager reconstruction is what caused the
    //! damage in the first place: it runs once ever, matches exactly one entry,
    //! refuses anything that is not literally all zeros, and produces its values
    //! through the same computeDayDetailFrom() maths and the same dayEntry()
    //! shaping a day recorded live goes through.
    const REPAIR_KEY = "embFix";

    //! Outcome of the one-shot repair, persisted so it survives restarts:
    //!   rep    rebuilt the embedded day's rollup
    //!   good   entry held real detail — left untouched
    //!   abs    no stored entry for the embedded day
    //!   live   embedded day is today, which updateDayTotals() owns
    //!   nodata embedded series had nothing to rebuild from
    //!   pend   has not run yet
    //! Any value other than "pend" is also the marker that blocks a second run.
    function repairStatus() {
        var v = App.Storage.getValue(REPAIR_KEY);
        if (v == null) {
            return "pend";
        }
        return v.toString();
    }

    //! Perform the one-shot repair described above. Cheap no-op once the marker
    //! exists, so it can sit on the app-open path.
    function repairEmbeddedDay() {
        if (App.Storage.getValue(REPAIR_KEY) != null) {
            return;
        }
        // Keyed off the date the embedded data actually carries, so a
        // regenerated TodaySolarData can only ever act on its own day.
        var day = TodaySolarData.DAY;
        if (day == null || TodaySolarData.COUNT < 2) {
            App.Storage.setValue(REPAIR_KEY, "nodata");
            return;
        }
        if (todayId().equals(day)) {
            App.Storage.setValue(REPAIR_KEY, "live");
            return;
        }
        var days = App.Storage.getValue(DAYS_KEY);
        if (days == null || !(days instanceof Lang.Array)) {
            App.Storage.setValue(REPAIR_KEY, "abs");
            return;
        }
        var idx = -1;
        for (var i = 0; i < days.size(); i++) {
            var e = days[i];
            if ((e instanceof Lang.Array) && e.size() >= 1 && e[0] != null && day.equals(e[0])) {
                idx = i;
                break;
            }
        }
        if (idx < 0) {
            App.Storage.setValue(REPAIR_KEY, "abs");
            return;
        }
        if (!isZeroedEntry(days[idx])) {
            App.Storage.setValue(REPAIR_KEY, "good");
            return;
        }
        var dd = computeDayDetailFrom(day, SolarLogger.getRawSamples());
        if (dd == null || dd[:ready] == false) {
            App.Storage.setValue(REPAIR_KEY, "nodata");
            return;
        }
        var expo = dd[:exposure] == null ? 0.0 : dd[:exposure];
        // The embedded FIT series carries no battery level and no charger
        // state, so computeToday()'s observed-gain branch could not have fired
        // for this day and no USB time can be attributed to it: the heuristic
        // on the current %/intensity·h is exactly what the live path stored.
        var est = {
            :exposure => expo,
            :estPct => expo * effectivePctPerIntensityH(),
            :usbMinutes => 0.0,
            :sunHours => dd[:sunHours],
            :peak => dd[:peak],
            :avg => dd[:avg],
            :firstSun => dd[:firstSun],
            :lastSun => dd[:lastSun]
        };
        var entry = dayEntry(day, est);
        // Claim the run before touching history. An interrupted write would
        // leave the entry zeroed and the repair spent, which is the safe way
        // round — the alternative order lets a second attempt exist at all.
        App.Storage.setValue(REPAIR_KEY, "rep");
        days[idx] = entry;
        App.Storage.setValue(DAYS_KEY, days);
    }

    //! True when a rollup carries a day id and no information: every numeric
    //! field is zero or missing. That is the signature the destructive backfill
    //! left behind and the only state repairEmbeddedDay() may overwrite — one
    //! real number anywhere in the entry means it is somebody's actual data.
    function isZeroedEntry(e) {
        if (!(e instanceof Lang.Array) || e.size() < 4) {
            return false;
        }
        for (var i = 1; i < e.size(); i++) {
            var v = e[i];
            if (v != null && v != 0) {
                return false;
            }
        }
        return true;
    }

    //! "YYYY-MM-DD" as the comparable number YYYYMMDD, or null if unparseable.
    //! Ordered exactly like the dates are, so a period window can be selected
    //! with an integer compare instead of a Moment per stored entry.
    function dayIdKey(dayId) {
        if (dayId == null) {
            return null;
        }
        var s = dayId.toString();
        if (s.length() < 10) {
            return null;
        }
        var y = s.substring(0, 4).toNumber();
        var mo = s.substring(5, 7).toNumber();
        var d = s.substring(8, 10).toNumber();
        if (y == null || mo == null || d == null) {
            return null;
        }
        return (y * 10000) + (mo * 100) + d;
    }

    //! dayIdKey() of the local calendar day n days before today — the oldest
    //! day an n+1 day period covers. Anchored at local noon so an hour of DST
    //! cannot land it on the neighbouring date.
    function dayIdKeyDaysAgo(n) {
        var noon = startOfLocalDayEpoch() + 43200 - (n * 86400);
        var info = Gregorian.info(new Time.Moment(noon), Time.FORMAT_SHORT);
        return (info.year * 10000) + (info.month * 100) + info.day;
    }

    //! Most recent recorded day rollup, or null if history is empty.
    function getLastDay() {
        var days = getDayHistory();
        var n = days.size();
        if (n == 0) {
            return null;
        }
        return days[n - 1];
    }

    //! Returns the stored multi-day history as an array of dicts:
    //!   { :day, :exposure, :estPct, :estPctStored, :usbMin, :sunHours,
    //!     :peak, :avg, :firstSun, :lastSun } — oldest first, today last.
    //! Older entries lacking a field default it (sunHours→0, detail fields→null).
    //!
    //! :estPct is DERIVED here, from the day's stored exposure and the
    //! %/intensity·h in force now — it is not the number that was stored on the
    //! day. Exposure is the measurement; the percentage is an interpretation of
    //! it, and the interpretation has changed twice (the default went 0.05 →
    //! 0.46, and a trusted calibration can replace it again). Reading the
    //! archive through today's constant is the only way "3 days" means the sum
    //! of three comparable numbers; kept as stored, the same sunshine counted
    //! sevenfold depending on which build was installed that week.
    //!
    //! The cost is that history is no longer a frozen ledger: every stored day
    //! moves when the calibration moves. :estPctStored keeps what was actually
    //! written, so the debug dump can show both and the shift stays visible.
    //! A day whose exposure is missing or zero has nothing to derive from and
    //! falls back to its stored value.
    function getDayHistory() {
        var days = App.Storage.getValue(DAYS_KEY);
        var out = [];
        if (days == null || !(days instanceof Lang.Array)) {
            return out;
        }
        var k = effectivePctPerIntensityH();
        for (var i = 0; i < days.size(); i++) {
            var e = days[i];
            if (e instanceof Lang.Array && e.size() >= 4) {
                var expo = e[1];
                var storedPct = e[2];
                var pct = storedPct;
                if (expo != null && expo > 0) {
                    pct = expo * k;
                }
                out.add({
                    :day => e[0],
                    :exposure => expo,
                    :estPct => pct,
                    :estPctStored => storedPct,
                    :usbMin => e[3],
                    :sunHours => (e.size() >= 5 ? e[4] : 0.0),
                    :peak => (e.size() >= 6 ? e[5] : null),
                    :avg => (e.size() >= 7 ? e[6] : null),
                    :firstSun => (e.size() >= 8 && e[7] != 0 ? e[7] : null),
                    :lastSun => (e.size() >= 9 && e[8] != 0 ? e[8] : null)
                });
            }
        }
        return out;
    }

    //! Empirical calibration of PCT_PER_INTENSITY_H from the logger buffer.
    //!
    //! Solar on a wrist device rarely *raises* the battery — it mostly slows the
    //! drain — so the gain is measured as avoided drain, not as a positive delta:
    //!   darkRate = %/h lost during zero-sun intervals   (the baseline)
    //!   savedPct = darkRate * sunHours - actual drop during sunny intervals
    //!   calibrated PCT_PER_INTENSITY_H = savedPct / exposure(intensity·h)
    //!
    //! An interval is only evidence if it measures something. Excluded outright:
    //! charging intervals (the charger swamps the signal), the half hour after a
    //! charge (the gauge is still settling), a pack sitting at full (saturated —
    //! no drain to see and no room for gain), intervals where the intensity
    //! sensor reported nothing (a sentinel, not darkness), and dark→sun
    //! transitions (their drain belongs to both regimes). The watch is on USB
    //! throughout every sideload and every ordinary recharge, so these are the
    //! normal condition of the buffer rather than rare cases.
    //!
    //! Needs zero-sun rows in the buffer, which is why appendSample() keeps them.
    //! Battery % is quantised, so the result only replaces PCT_PER_INTENSITY_H
    //! once it clears the CAL_MIN_* gates — see effectivePctPerIntensityH().
    //! Persistent calibration accumulators, so evidence survives the 24 h buffer:
    //!   [lastT, darkHours, darkDrop, sunHours, sunDrop, exposure]
    //! Only intervals newer than lastT are folded in, so repeated calls are safe.
    const CALIB_KEY = "calib";

    function getCalibTotals() {
        var c = App.Storage.getValue(CALIB_KEY);
        if (c == null || !(c instanceof Lang.Array) || c.size() < 6) {
            return [0, 0.0, 0.0, 0.0, 0.0, 0.0];
        }
        return c;
    }

    //! Drop the persistent calibration totals so they rebuild from scratch.
    //! The accumulators are permanent by design, so this is the only escape
    //! from evidence that turned out to be bad; it is reachable exclusively
    //! from the hidden debug overlay.
    function resetCalibration() {
        App.Storage.deleteValue(CALIB_KEY);
    }

    //! Fold every not-yet-counted buffer interval into the persistent totals.
    //! Call on app open / manual sample; cheap and idempotent.
    function updateCalibration() {
        var samples = SolarLogger.getRawSamples();
        if (samples == null || samples.size() < 2) {
            return;
        }
        var tot = getCalibTotals();
        var lastT = tot[0];
        var now = Time.now().value();
        if (lastT > now + CAL_MAX_FUTURE_SEC) {
            lastT = now;   // clock jumped forward and was corrected — resync
        }
        var darkHours = tot[1];
        var darkDrop = tot[2];
        var sunHours = tot[3];
        var sunDrop = tot[4];
        var exposure = tot[5];
        var newestT = lastT;
        var changed = false;
        //! Timestamp of the newest sample seen charging while walking the
        //! buffer, 0 when none. The watch is on USB during every sideload, so
        //! this is the normal state of affairs rather than an edge case.
        var chargeT = 0;

        for (var i = 1; i < samples.size(); i++) {
            var a = samples[i - 1];
            var b = samples[i];
            if (!SolarLogger.isRow(a) || !SolarLogger.isRow(b)) {
                continue;
            }
            var t0 = a[SolarLogger.R_T];
            var t1 = b[SolarLogger.R_T];
            if (t0 == null || t1 == null) {
                continue;
            }
            var c0 = a[SolarLogger.R_C] ? true : false;
            var c1 = b[SolarLogger.R_C] ? true : false;
            // Charger history is tracked over every row, including the ones
            // this run will skip, so the guard below sees a charge that ended
            // before the not-yet-counted part of the buffer begins.
            var chargeBefore = chargeT;
            if (c0 && t0 > chargeT) {
                chargeT = t0;
            }
            if (c1 && t1 > chargeT) {
                chargeT = t1;
            }
            if (t1 <= lastT) {
                continue;   // already folded in on a previous run
            }
            var dt = t1 - t0;
            if (dt <= 0 || dt > MAX_INTERVAL_SEC) {
                continue;
            }
            if (c0 || c1) {
                continue;   // on USB — tells us nothing about solar
            }
            if (chargeBefore > 0 && (t0 - chargeBefore) < POST_CHARGE_GUARD_SEC) {
                continue;   // gauge still settling after the cable came out
            }
            var b0 = a[SolarLogger.R_B];
            var b1 = b[SolarLogger.R_B];
            if (b0 == null || b1 == null) {
                continue;
            }
            if (b0 >= FULL_BATTERY_PCT || b1 >= FULL_BATTERY_PCT) {
                continue;   // saturated gauge: no drain to measure, no gain either
            }
            var siRaw0 = a[SolarLogger.R_SI];
            var siRaw1 = b[SolarLogger.R_SI];
            if (!siKnown(siRaw0) || !siKnown(siRaw1)) {
                continue;   // sensor unavailable — not a dark hour, just no reading
            }
            var hours = dt / 3600.0;
            var drop = b0 - b1;   // positive while discharging
            var rate = drop / hours;
            if (rate > CAL_MAX_PCT_PER_H || rate < -CAL_MAX_PCT_PER_H) {
                continue;   // gauge step / hidden charge, not consumption
            }
            // Three-way, not two: an interval that starts dark and ends sunlit
            // belongs to neither bucket — its drain is part baseline, part
            // assisted, and the sun arrived at an unknown moment inside it.
            // Folding transitions into the sun bucket (which is what "average
            // > 0" did) charges the sun for drain that happened in the dark.
            if (siRaw0 > 0 && siRaw1 > 0) {
                sunHours += hours;
                sunDrop += drop;
                exposure += ((solarForIntegral(siRaw0) + solarForIntegral(siRaw1)) / 2.0 / 100.0) * hours;
            } else if (siRaw0 == 0 && siRaw1 == 0) {
                darkHours += hours;
                darkDrop += drop;
            } else {
                continue;
            }
            if (t1 > newestT) {
                newestT = t1;
            }
            changed = true;
        }

        if (changed) {
            App.Storage.setValue(CALIB_KEY,
                [newestT, darkHours, darkDrop, sunHours, sunDrop, exposure]);
        }
    }

    function computeCalibration() {
        var tot = getCalibTotals();
        var darkHours = tot[1];
        var darkDrop = tot[2];
        var sunHours = tot[3];
        var sunDrop = tot[4];
        var exposure = tot[5];

        var out = {
            :ready => false,
            :darkHours => darkHours,
            :sunHours => sunHours,
            :darkRate => 0.0,
            :sunRate => 0.0,
            :exposure => exposure,
            :savedPct => 0.0,
            :pctPerIntensityH => null,
            :trusted => false,
            :block => null,
            :current => PCT_PER_INTENSITY_H
        };

        if (darkHours > 0) {
            out[:darkRate] = darkDrop / darkHours;
        }
        if (sunHours > 0) {
            out[:sunRate] = sunDrop / sunHours;
        }
        if (darkHours <= 0 || sunHours <= 0 || exposure <= 0) {
            // Need both regimes before a ratio means anything.
            out[:block] = calibBlock(darkHours, sunHours, exposure, out[:darkRate], 0.0, null);
            return out;
        }

        var saved = (darkDrop / darkHours) * sunHours - sunDrop;
        out[:savedPct] = saved;
        out[:pctPerIntensityH] = saved / exposure;
        out[:ready] = true;
        out[:block] = calibBlock(darkHours, sunHours, exposure, out[:darkRate],
            saved, out[:pctPerIntensityH]);
        out[:trusted] = (out[:block] == null);
        return out;
    }

    //! First unmet trust gate as a short token for the debug overlay, or null
    //! when the measurement may drive the estimates. Ordered so the token names
    //! what is still missing (data volume first, then plausibility).
    function calibBlock(darkHours, sunHours, exposure, darkRate, saved, k) {
        if (darkHours < CAL_MIN_DARK_H) {
            return "dark<" + CAL_MIN_DARK_H.format("%.0f") + "h";
        }
        if (sunHours < CAL_MIN_SUN_H) {
            return "sun<" + CAL_MIN_SUN_H.format("%.0f") + "h";
        }
        if (exposure < CAL_MIN_EXPOSURE) {
            return "expo<" + CAL_MIN_EXPOSURE.format("%.1f");
        }
        if (darkRate <= 0) {
            // Non-positive baseline drain: the pack gained charge in the dark,
            // so the whole "avoided drain" model does not apply to this data.
            return "drk%/h<=0";
        }
        if (saved < CAL_MIN_SAVED_PCT) {
            return "saved<" + CAL_MIN_SAVED_PCT.format("%.0f");
        }
        if (k == null || k < CAL_MIN_K || k > CAL_MAX_K) {
            return "K out of band";
        }
        return null;
    }

    //! The %/intensity·h the estimates actually run on: the personally measured
    //! constant once every gate in calibBlock() is met, else the default. Single
    //! accessor so every estimate path stays on the same number.
    function effectivePctPerIntensityH() {
        var cal = computeCalibration();
        if (cal == null || cal[:trusted] != true || cal[:pctPerIntensityH] == null) {
            return PCT_PER_INTENSITY_H;
        }
        return cal[:pctPerIntensityH];
    }

}
