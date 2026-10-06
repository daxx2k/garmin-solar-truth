using Toybox.Lang;
using Toybox.System;
using Toybox.Time;
using Toybox.Time.Gregorian;

//! Greppable single-line diagnostics to the on-device Connect IQ log file
//! (Internal Storage\GARMIN\APPS\LOGS\<appid>.TXT, readable over MTP). Every
//! line is prefixed with "STDBG" so it can be grepped out of the SDK noise.
//!
//! This module is (:background) so the temporal-event sampler can log too — it
//! ONLY touches System / Time / Lang, never any UI code, so it is safe to call
//! from both the app view and the background ServiceDelegate.
(:background)
module DebugLog {

    //! Local HH:MM:SS for an epoch (seconds), or "--:--:--" when null.
    function hms(epoch) {
        if (epoch == null) {
            return "--:--:--";
        }
        var info = Gregorian.info(new Time.Moment(epoch), Time.FORMAT_SHORT);
        return info.hour.format("%02d") + ":" + info.min.format("%02d") + ":" + info.sec.format("%02d");
    }

    //! Current local HH:MM:SS.
    function nowHms() {
        return hms(Time.now().value());
    }

    //! Compact number for debug lines: "-" for null, 2 dp for floats, else raw.
    function num(v) {
        if (v == null) {
            return "-";
        }
        if (v instanceof Lang.Float || v instanceof Lang.Double) {
            return v.format("%.2f");
        }
        return v.toString();
    }

    //! "T"/"F" for a (possibly null) boolean-ish value.
    function bool(v) {
        return (v == true) ? "T" : "F";
    }

    //! "-" for null, else toString — safe for Strings/Numbers in debug lines.
    function str(v) {
        if (v == null) {
            return "-";
        }
        return v.toString();
    }

    //! Emit one STDBG record. `msg` is the already-composed compact payload.
    function line(msg) {
        System.println("STDBG " + msg);
    }
}
