import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import io.github.gustavobelo.opencouch

Controls.ApplicationWindow {
    id: root

    width: 620
    height: 760
    minimumWidth: 480
    minimumHeight: 560
    // Starting minimized never shows the window: hiding right after the show
    // races the first frame on Wayland, so the window simply is not born
    // visible. Launching the app again wakes it up.
    visible: !backend.startMinimized()
    title: appInfo.displayName + " v" + appInfo.version
    color: Colors.background

    onClosing: function(close) {
        if (backend.backgroundOnClose()) {
            close.accepted = false;
            backend.showTray();
            root.hide();
        }
    }

    // The app's own bar. Not a toolbar: it carries the mark and two actions,
    // and it is the only chrome, so the page below can run to the window edge.
    header: Item {
        implicitHeight: Metrics.headerHeight

        Rectangle {
            anchors.fill: parent
            color: Colors.background
        }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Metrics.pagePadding
            anchors.rightMargin: Metrics.lg
            spacing: Metrics.xl

            Rectangle {
                Layout.alignment: Qt.AlignVCenter
                width: Metrics.md
                height: Metrics.md
                radius: width / 2
                color: Colors.accent
            }

            Text {
                Layout.alignment: Qt.AlignVCenter
                text: "OPEN COUCH"
                color: Colors.foreground
                font.pixelSize: Metrics.body
                font.bold: true
                font.letterSpacing: 2.0
            }

            Item { Layout.fillWidth: true }

            IconAction {
                icon: "settings"
                tip: qsTrId("app.settings")
                active: stack.depth > 1
                onTriggered: root.showSettings()
            }

            IconAction {
                icon: "help"
                tip: qsTrId("dashboard.help")
                onTriggered: onboardingSheet.open()
            }
        }

        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: 1
            color: Colors.hairline
        }
    }

    // The pages sit on their own opaque ground rather than relying on the
    // window colour: a page that is transparent borrows whatever is behind it,
    // which is not always what the window painted.
    Rectangle {
        id: pageArea
        anchors.fill: parent
        color: Colors.background

    Controls.StackView {
        id: stack
        anchors.fill: parent

        // 140ms, the geometry budget. Anything slower reads as the app
        // hesitating; anything faster is not seen at all.
        pushEnter: Transition {
            NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Metrics.moveDuration; easing.type: Easing.OutCubic }
            NumberAnimation { property: "x"; from: Metrics.x5; to: 0; duration: Metrics.moveDuration; easing.type: Easing.OutCubic }
        }
        popExit: Transition {
            NumberAnimation { property: "opacity"; from: 1; to: 0; duration: Metrics.moveDuration; easing.type: Easing.OutCubic }
        }
        pushExit: Transition { NumberAnimation { property: "opacity"; from: 1; to: 0; duration: Metrics.fadeDuration } }
        popEnter: Transition { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Metrics.moveDuration } }
    }
    }

    function showSettings() {
        if (stack.depth > 1) {
            stack.pop();
            return;
        }
        stack.push(setupComponent);
    }

    Component { id: dashboardComponent; DashboardPage {} }
    Component { id: setupComponent; SetupPage {} }

    OnboardingSheet {
        id: onboardingSheet
        onClosed: backend.setOnboardingSeen(true)
    }

    Component.onCompleted: {
        backend.attachWindow(root);

        Qt.callLater(function() {
            const dashboard = stack.push(dashboardComponent);
            dashboard.settingsRequested.connect(root.showSettings);

            // "Configured" is the engine's answer, not a pair of settings keys:
            // console mode needs a gamescope session, a hosting login and a
            // display, and only the engine checks all three.
            if (backend.consoleStatus().ready !== true) {
                stack.push(setupComponent);
            }

            if (!backend.onboardingSeen()) {
                onboardingSheet.open();
            }
        });
    }
}
