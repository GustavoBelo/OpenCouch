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
            var config = backend.loadConfig();
            var configured = !!(config.DESK_OUTPUT && config.TV_OUTPUT);
            
            pageStack.push(dashboardComponent);
            
            if (!configured) {
                pageStack.push(setupComponent);
            }

            if (!backend.onboardingSeen()) {
                onboardingSheet.open();
            }
        });
    }

    Component {
        id: setupComponent
        SetupPage {}
    }

    Component {
        id: dashboardComponent
        DashboardPage { 
            onReconfigureRequested: {
                if (pageStack.currentItem !== setupComponent) {
                    pageStack.push(setupComponent);
                }
            }
            onHelpRequested: onboardingSheet.open()
        }
    }
}