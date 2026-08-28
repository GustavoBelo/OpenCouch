import QtQuick
import QtQuick.Controls as Controls
import org.kde.kirigami as Kirigami

Kirigami.ApplicationWindow {
    id: root
    title: appInfo.displayName + " v" + appInfo.version
    width: 560
    height: 720
    minimumWidth: 440
    minimumHeight: 520

    pageStack.defaultColumnWidth: root.width

    // Filled on first run and consumed by SetupPage to pre-select the combos.
    // Empty object means "no suggestion".
    property var suggestedSetup: ({})

    // Heuristic for which connected output is the TV: prefer an HDMI connector,
    // then the one with the larger current resolution. Deterministic — the raw
    // order the engine happens to return is not.
    function suggestOutputs() {
        var outputs = backend.listOutputs();
        var enabled = [];
        for (var i = 0; i < outputs.length; i++) {
            if (outputs[i] && outputs[i].name) {
                enabled.push(outputs[i]);
            }
        }
        if (enabled.length !== 2) {
            return {};
        }

        function widthOf(o) {
            var m = String(o.currentMode || "").split("x")[0];
            var n = parseInt(m, 10);
            return isNaN(n) ? 0 : n;
        }
        function isHdmi(o) {
            return /hdmi/i.test(String(o.name));
        }

        var tvIndex;
        if (isHdmi(enabled[0]) !== isHdmi(enabled[1])) {
            tvIndex = isHdmi(enabled[0]) ? 0 : 1;
        } else if (widthOf(enabled[0]) !== widthOf(enabled[1])) {
            tvIndex = widthOf(enabled[0]) > widthOf(enabled[1]) ? 0 : 1;
        } else {
            return {};
        }

        var tv = enabled[tvIndex];
        var desk = enabled[1 - tvIndex];
        return {
            DESK_OUTPUT: desk.name,
            TV_OUTPUT: tv.name,
            FALLBACK_DESK_MODE: desk.currentMode || "",
            FALLBACK_TV_MODE: tv.currentMode || "",
            FALLBACK_DESK_SCALE: String(desk.scale || 1),
            FALLBACK_TV_SCALE: String(tv.scale || 1),
            FALLBACK_DESK_POS: desk.pos || "0,0",
            FALLBACK_TV_POS: tv.pos || "0,0"
        };
    }

    onClosing: function(close) {
        if (backend.backgroundOnClose()) {
            close.accepted = false;
            backend.showTray();
            root.hide();
        }
    }

    Connections {
        target: pageStack
        function onCurrentIndexChanged() {
            if (pageStack.currentIndex === 0 && pageStack.depth > 1) {
                Qt.callLater(function() {
                    while (pageStack.depth > 1) {
                        pageStack.pop();
                    }
                });
            }
        }
    }

    OnboardingSheet {
        id: onboardingSheet
        onClosed: backend.setOnboardingSeen(true)
    }

    Component.onCompleted: {
        backend.attachWindow(root);

        Qt.callLater(function() {
            backend.ensureEngine();

            var config = backend.loadConfig();
            var configured = !!(config.DESK_OUTPUT && config.TV_OUTPUT);

            // On first run, suggest a desk/TV pair so the user only has to
            // confirm. This only pre-fills Setup — it never writes the config
            // nor skips the screen: picking the wrong output as "desk" would
            // blank the display the user is actually looking at.
            if (!configured) {
                root.suggestedSetup = root.suggestOutputs();
            }

            var setupPage;
            var dashboard = Qt.createComponent(Qt.resolvedUrl("DashboardPage.qml")).createObject(null);
            dashboard.reconfigureRequested.connect(function() {
                if (pageStack.currentItem !== setupPage) {
                    setupPage = Qt.createComponent(Qt.resolvedUrl("SetupPage.qml")).createObject(null);
                    pageStack.push(setupPage);
                }
            });
            dashboard.helpRequested.connect(function() {
                onboardingSheet.open();
            });
            pageStack.push(dashboard);

            if (!configured) {
                setupPage = Qt.createComponent(Qt.resolvedUrl("SetupPage.qml"))
                    .createObject(null, { suggestion: root.suggestedSetup });
                pageStack.push(setupPage);
            }

            if (!backend.onboardingSeen()) {
                onboardingSheet.open();
            }
        });
    }
}