import QtQuick
import QtQuick.Controls as Controls
import io.github.gustavobelo.opencouch

// A dropdown with every part of the platform style replaced. The stock control
// is kept for its keyboard handling and popup positioning, which are tedious
// and easy to get subtly wrong; nothing of its appearance survives.
Controls.ComboBox {
    id: root

    // Nothing chosen is a state worth naming. An empty box reads as a control
    // that failed to load rather than one waiting for an answer.
    property string placeholder: ""

    implicitHeight: Metrics.controlHeight
    font.pixelSize: Metrics.body

    background: StateSurface {
        pressed: root.pressed
        // The focus ring is the hover state on purpose: one affordance for
        // pointer, keyboard and touch rather than three that must agree.
        hovered: root.hovered || root.activeFocus
    }

    contentItem: Text {
        leftPadding: Metrics.xl
        rightPadding: Metrics.sm
        text: root.currentIndex < 0 && root.placeholder !== "" ? root.placeholder : root.displayText
        color: root.currentIndex < 0 && root.placeholder !== "" ? Colors.muted
             : root.enabled ? Colors.foreground : Colors.disabled
        font: root.font
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
    }

    indicator: Icon {
        x: root.width - width - Metrics.xl
        y: (root.height - height) / 2
        name: "chevron"
        size: Metrics.iconSmall
        color: root.hovered ? Colors.foreground : Colors.muted
    }

    popup: Controls.Popup {
        y: root.height + Metrics.xs
        width: root.width
        implicitHeight: Math.min(contentItem.implicitHeight + Metrics.md, Metrics.dropdownMax)
        padding: Metrics.xs

        background: Rectangle {
            color: Colors.surface
            radius: Metrics.radiusSmall
            border.width: 1
            border.color: Colors.lineRaised
        }

        contentItem: ListView {
            clip: true
            implicitHeight: contentHeight
            model: root.popup.visible ? root.delegateModel : null
            currentIndex: root.highlightedIndex
            boundsBehavior: Flickable.StopAtBounds
            Controls.ScrollIndicator.vertical: Controls.ScrollIndicator {}
        }
    }

    delegate: Controls.ItemDelegate {
        required property var model
        required property int index

        width: root.width - Metrics.md
        height: Metrics.controlHeight

        background: Rectangle {
            radius: Metrics.radiusSmall
            color: root.highlightedIndex === index ? Colors.fillHover : "transparent"
            Behavior on color { ColorAnimation { duration: Metrics.fadeDuration } }
        }

        contentItem: Text {
            leftPadding: Metrics.md
            text: model[root.textRole] !== undefined ? model[root.textRole] : String(model.modelData)
            color: root.currentIndex === index ? Colors.accent : Colors.foreground
            font.pixelSize: Metrics.body
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
    }
}
