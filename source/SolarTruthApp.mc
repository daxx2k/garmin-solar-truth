using Toybox.Application as App;
using Toybox.WatchUi;
using Toybox.System;

//! Solar Truth — 3 page cards (NOW | TODAY | HISTORY) + background logger.
class SolarTruthApp extends App.AppBase {

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state) {
        SolarLogger.ensureScheduled();
    }

    //! Second net under the FIT exporter, behind View.onHide: a recording
    //! session that outlived the app would keep the watch recording with no
    //! way left to stop it.
    function onStop(state) {
        if (_view != null) {
            _view.finalizeExportOnExit();
        }
    }

    var _view = null;

    function getInitialView() {
        _view = new SolarTruthView();
        return [_view, new SolarTruthDelegate(_view)];
    }

    (:background)
    function getServiceDelegate() {
        return [new SolarLoggerService()];
    }

    //! Compact preview shown in the glance carousel (swipe up/down from the
    //! watch face). Annotated (:glance) so only the glance-scope code is loaded.
    (:glance)
    function getGlanceView() {
        return [new SolarTruthGlanceView()];
    }

    //! Fired when a background exit returns while the app is open (or next launch).
    function onBackgroundData(data) {
        if (_view != null) { _view.requestRefresh(); }
        WatchUi.requestUpdate();
    }
}

