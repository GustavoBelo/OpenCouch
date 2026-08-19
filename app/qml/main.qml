import QtQuick
import QtQuick.Controls as Controls
import org.kde.kirigami as Kirigami

Kirigami.ApplicationWindow {
    id: root
    title: appInfo.displayName + " v" + appInfo.version
    width: 520
    height: 640
    minimumWidth: 420
    minimumHeight: 480

    pageStack.defaultColumnWidth: root.width

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
                setupPage = Qt.createComponent(Qt.resolvedUrl("SetupPage.qml")).createObject(null);
                pageStack.push(setupPage);
            }

            if (!backend.onboardingSeen()) {
                onboardingSheet.open();
            }
        });
    }
}