using Toybox.Lang;

//! Shared Extra-runtime / estimated-gain duration strings for TODAY, HISTORY,
//! and the glance preview. (:glance) so SolarTruthGlanceView can call it without
//! loading the full View.
(:glance)
module RuntimeFormat {

    //! Minutes → "~23 min" / "~5 h 22 m" under 24 h; "~1 d" / "~1 d 8 h" from 24 h up.
    //! Remaining minutes are dropped once the value is shown in days+hours.
    function formatRuntimeMins(mins) {
        if (mins == null) {
            return "—";
        }
        if (mins < 0) {
            mins = 0;
        }
        var total = mins.toNumber();
        if (total < 60) {
            return "~" + total.toString() + " min";
        }
        var hours = total / 60;
        if (hours < 24) {
            var rem = total % 60;
            if (rem == 0) {
                return "~" + hours.toString() + " h";
            }
            return "~" + hours.toString() + " h " + rem.toString() + " m";
        }
        var days = hours / 24;
        var remH = hours % 24;
        if (remH == 0) {
            return "~" + days.toString() + " d";
        }
        return "~" + days.toString() + " d " + remH.toString() + " h";
    }
}
