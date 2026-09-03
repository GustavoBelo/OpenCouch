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

            // "Configured" is the engine's answer, not a pair of settings keys:
            // console mode needs a gamescope session, a hosting login and a
            // television, and only the engine checks all three.
            var configured = backend.consoleStatus().ready === true;

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