import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import io.github.gustavobelo.opencouch

// The help sheet. Full-bleed rather than a dialog with a title bar, because
// this is the one screen that is read rather than operated.
Controls.Popup {
    id: root

    parent: Controls.Overlay.overlay
    anchors.centerIn: Controls.Overlay.overlay
    width: Math.min(parent ? parent.width - Metrics.iconButton : Metrics.sheetWidth, Metrics.sheetWidth)
    height: Math.min(parent ? parent.height - Metrics.iconButton : Metrics.sheetHeight, Metrics.sheetHeight)
    modal: true
    padding: 0

    Controls.Overlay.modal: Rectangle {
        color: Colors.veil
    }

    background: Rectangle {
        color: Colors.surface
        radius: Metrics.radius
        border.width: 1
        border.color: Colors.edge
    }

    contentItem: ColumnLayout {
        spacing: 0

        RowLayout {
            Layout.fillWidth: true
            Layout.margins: Metrics.cardPadding
            spacing: Metrics.xl

            Rectangle {
                width: Metrics.md; height: Metrics.md
                radius: width / 2
                color: Colors.accent
            }

            Text {
                Layout.fillWidth: true
                text: qsTrId("onboarding.welcome")
                color: Colors.foreground
                font.pixelSize: Metrics.heading
                font.bold: true
                wrapMode: Text.Wrap
            }

            IconAction {
                icon: "close"
                onTriggered: root.close()
            }
        }

        Rectangle {
            Layout.fillWidth: true
            height: 1
            color: Colors.hairline
        }

        Controls.ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: availableWidth
            clip: true

            ColumnLayout {
                width: parent.parent.width
                spacing: Metrics.sectionGap

                Item { Layout.preferredHeight: Metrics.xs }

                Text {
                    Layout.fillWidth: true
                    Layout.leftMargin: Metrics.cardPadding
                    Layout.rightMargin: Metrics.cardPadding
                    text: qsTrId("onboarding.introduction")
                    color: Colors.muted
                    font.pixelSize: Metrics.body
                    wrapMode: Text.Wrap
                }

                Repeater {
                    model: [
                        { icon: "warn",    title: qsTrId("onboarding.needs_title"),    body: qsTrId("onboarding.needs_body") },
                        { icon: "session", title: qsTrId("onboarding.session_title"),  body: qsTrId("onboarding.session_body") },
                        { icon: "display", title: qsTrId("onboarding.display_title"),  body: qsTrId("onboarding.display_body") },
                        { icon: "enter",   title: qsTrId("onboarding.entering_title"), body: qsTrId("onboarding.entering_body") }
                    ]

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.leftMargin: Metrics.cardPadding
                        Layout.rightMargin: Metrics.cardPadding
                        spacing: Metrics.xxl

                        Icon {
                            Layout.alignment: Qt.AlignTop
                            name: modelData.icon
                            size: Metrics.icon
                            color: Colors.accent
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: Metrics.xs

                            Text {
                                Layout.fillWidth: true
                                text: modelData.title
                                color: Colors.foreground
                                font.pixelSize: Metrics.body
                                font.bold: true
                                wrapMode: Text.Wrap
                            }

                            Text {
                                Layout.fillWidth: true
                                text: modelData.body
                                color: Colors.muted
                                font.pixelSize: Metrics.body
                                wrapMode: Text.Wrap
                            }
                        }
                    }
                }

                Item { Layout.preferredHeight: Metrics.md }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            height: 1
            color: Colors.hairline
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.margins: Metrics.cardPadding
            spacing: Metrics.md

            Text {
                Layout.fillWidth: true
                text: appInfo.displayName + "  ·  v" + appInfo.version
                color: Colors.muted
                font.pixelSize: Metrics.caption
            }

            AppButton {
                primary: true
                text: qsTrId("common.got_it")
                icon: "check"
                onClicked: root.close()
            }
        }
    }
}
