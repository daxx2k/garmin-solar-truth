using Toybox.System;
using Toybox.WatchUi;

class SolarTruthDelegate extends WatchUi.BehaviorDelegate {

    var _view;

    function initialize(view) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    //! Raw key events, ahead of the behaviour translation.
    //!
    //! The debug overlay's actions were unreachable because the SELECT
    //! behaviour never arrived for a short START press on this device, while
    //! the MENU behaviour from a held START did — the overlay opened, and
    //! nothing inside it could be triggered. Nothing downstream could have
    //! swallowed it silently: every branch of the view's action handler
    //! repaints, and every early return in FitExport.start() flips the state
    //! to FX_FAIL, which takes over the whole screen.
    //!
    //! So the key is read directly, but only as a fallback: the behaviour
    //! translation runs first and is left in charge whenever it produced
    //! anything at all. That keeps the hold-to-open gesture intact on a device
    //! that delivers it as a KEY_ENTER hold, and avoids acting twice where
    //! both layers fire.
    function onKey(evt) {
        var key = evt.getKey();
        _view.noteKey(key);
        var selBefore = _view.behaviorSelects();
        var menuBefore = _view.behaviorMenus();
        var handled = BehaviorDelegate.onKey(evt);
        if (key == WatchUi.KEY_ENTER
            && _view.behaviorSelects() == selBefore
            && _view.behaviorMenus() == menuBefore) {
            _view.onSelectFromKey();
            return true;
        }
        return handled == true;
    }

    //! START/SELECT: cycle HISTORY period, or take a manual sample on other
    //! cards; inside the overlay it runs the selected action.
    function onSelect() {
        _view.onSelectFromBehavior();
        return true;
    }

    //! BACK closes the debug overlay first — reaching for it to escape a panel
    //! you opened by accident should not kill the app. Inside the overlay it
    //! unwinds one step at a time (leave the diagnostics screen, cancel a
    //! running backup, dismiss its result, disarm) before it will close
    //! anything.
    function onBack() {
        if (_view.isDebug()) {
            if (!_view.onDebugBack()) {
                _view.toggleDebug();
            }
            return true;
        }
        System.exit();
        return true;
    }

    //! MENU — hidden toggle for the debug overlay (Feature B). On the tactix 8 /
    //! fenix 8 this is a long press, a natural hidden gesture that is not used
    //! by the normal 3-card UI. Returns true so the press is fully consumed.
    //! Once the overlay is open MENU switches between its two screens, which is
    //! also the route to the diagnostics numbers while a backup is recording:
    //! BACK is the way out.
    function onMenu() {
        _view.noteMenu();
        if (_view.isDebug()) {
            _view.toggleDebugScreen();
            return true;
        }
        _view.toggleDebug();
        return true;
    }

    //! DOWN / swipe up — inside the overlay move the selection or scroll the
    //! dump, else next page card.
    function onNextPage() {
        if (_view.isDebug()) {
            _view.scrollDebug(1);
            return true;
        }
        _view.nextPage();
        WatchUi.requestUpdate();
        return true;
    }

    //! UP / swipe down — the mirror of onNextPage.
    function onPreviousPage() {
        if (_view.isDebug()) {
            _view.scrollDebug(-1);
            return true;
        }
        _view.previousPage();
        WatchUi.requestUpdate();
        return true;
    }
}
