using Toybox.Application;
using Toybox.Time;
using Toybox.Test;

(:test)
function fullBufferNightStartup(logger) {
    var now = Time.now().value();
    var rows = [];
    for (var i = 0; i < 288; i++) {
        rows.add([now - (287 - i) * 300, 80.0, false, i < 144 ? 60 : -1]);
    }
    Application.Storage.setValue("samples", rows);
    var days = [];
    for (var d = 30; d >= 0; d--) {
        var id = SolarDayRollup.dayIdFromEpoch(now - d * 86400);
        days.add([id, 1.0, 0.46, 0.0, 2.0, 60.0, 50.0, 0, 0]);
    }
    Application.Storage.setValue("days", days);
    Application.Storage.setValue("calib", [now - 90000, 48.0, 4.0, 12.0, 0.0, 4.0]);
    var view = new SolarTruthView();
    view._workStage = 0;
    for (var stage = 0; stage < 8; stage++) {
        view.onDeferredSnapshot();
        view.stopSnapTimer();
    }
    Test.assert(view._dataReady);
    Test.assert(view._cachedToday != null);
    Test.assert(view._cachedHistory.size() == 31);
    Test.assert(SolarLogger.getCount() == 288);
    Test.assert(view._workStage == -2);
    logger.debug("Full buffer + 31 days + night sentinel: staged startup completed");
    return true;
}

(:test)
function emptyStartup(logger) {
    Application.Storage.setValue("samples", []);
    Application.Storage.setValue("days", []);
    Application.Storage.setValue("calib", [0, 0.0, 0.0, 0.0, 0.0, 0.0]);
    var view = new SolarTruthView();
    view._workStage = 0;
    for (var stage = 0; stage < 8; stage++) {
        view.onDeferredSnapshot();
        view.stopSnapTimer();
    }
    Test.assert(view._dataReady);
    Test.assert(view._cachedToday != null);
    logger.debug("Empty storage: staged startup completed");
    return true;
}
