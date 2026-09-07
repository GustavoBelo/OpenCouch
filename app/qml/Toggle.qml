import QtQuick
import io.github.gustavobelo.opencouch

// A switch. The track carries the accent when on, because the state has to be
// readable without finding the knob first.
//
// It shows a state, it does not keep one. Writing to `checked` here would break
// the binding the owner set up, and from then on the control would report what
// it was last clicked to rather than what the engine actually did -- which is
// how a setting comes to look saved while nothing on the machine changed.
Item {
    id: root

    property bool checked: false
    signal toggled(bool value)

    implicitWidth: Metrics.toggleWidth
    implicitHeight: Metrics.x5

    Rectangle {
        id: track
        anchors.fill: parent
        radius: height / 2
        color: root.checked ? Colors.accentTrack : Colors.fill
        border.width: 1
        border.color: root.checked ? Colors.accentStrong
                                   : (mouse.containsMouse ? Colors.lineHover : Colors.line)
        opacity: root.enabled ? 1 : 0.4
        Behavior on color { ColorAnimation { duration: Metrics.fadeDuration } }
        Behavior on border.color { ColorAnimation { duration: Metrics.fadeDuration } }
    }

    Rectangle {
        id: knob
        width: parent.height - Metrics.md
        height: width
        radius: height / 2
        y: Metrics.xs
        x: root.checked ? root.width - width - Metrics.xs : Metrics.xs
        color: root.checked ? Colors.accent : Colors.muted
        opacity: root.enabled ? 1 : 0.4

        Behavior on x { NumberAnimation { duration: Metrics.moveDuration; easing.type: Easing.OutCubic } }
        Behavior on color { ColorAnimation { duration: Metrics.fadeDuration } }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        enabled: root.enabled
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggled(!root.checked)
    }
}
