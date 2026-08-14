import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as Controls
import org.kde.kirigami as Kirigami

Controls.Popup {
    id: sheet

    modal: true
    focus: true
    dim: true
    closePolicy: Controls.Popup.CloseOnEscape | Controls.Popup.CloseOnPressOutside
    anchors.centerIn: parent
    
    implicitWidth: Math.min(parent ? parent.width * 0.9 : 500, Kirigami.Units.gridUnit * 35)
    
    implicitHeight: Math.min(parent ? parent.height * 0.9 : 600, mainLayout.implicitHeight + padding * 2)
    padding: Kirigami.Units.largeSpacing

    background: Rectangle {
        radius: Kirigami.Units.largeSpacing
        color: Kirigami.Theme.backgroundColor
        border.color: Kirigami.Theme.focusColor
        border.width: 1
        opacity: 0.95
    }

    contentItem: ColumnLayout {
        id: mainLayout
        spacing: Kirigami.Units.largeSpacing

        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            Kirigami.Icon {
                source: "help-about"
                Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                Kirigami.Theme.colorSet: Kirigami.Theme.Button
                Kirigami.Theme.inherit: false
            }

            Kirigami.Heading {
                text: qsTrId("onboarding.welcome")
                level: 2
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
            }
        }

        Kirigami.Separator {
            Layout.fillWidth: true
        }

        Controls.ScrollView {
            id: contentScroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            Controls.ScrollBar.horizontal.policy: Controls.ScrollBar.AlwaysOff

            ColumnLayout {
                width: contentScroll.availableWidth 
                spacing: Kirigami.Units.largeSpacing

                Controls.Label {
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    text: qsTrId("onboarding.introduction")
                    font.pointSize: Kirigami.Theme.defaultFont.pointSize + 1
                    opacity: 0.9
                }

                component FeatureBlock : RowLayout {
                    property string iconName
                    property string titleText
                    property string descText
                    property string codeSnippet: ""

                    Layout.fillWidth: true
                    spacing: Kirigami.Units.largeSpacing
                    Layout.topMargin: Kirigami.Units.smallSpacing

                    Kirigami.Icon {
                        source: iconName
                        Layout.alignment: Qt.AlignTop
                        Layout.preferredWidth: Kirigami.Units.iconSizes.large
                        Layout.preferredHeight: Kirigami.Units.iconSizes.large
                        opacity: 0.7
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing

                        Kirigami.Heading {
                            level: 4
                            text: titleText
                            Layout.fillWidth: true
                            wrapMode: Text.Wrap
                        }
                        
                        Controls.Label {
                            Layout.fillWidth: true
                            wrapMode: Text.Wrap
                            text: descText
                            opacity: 0.8
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.topMargin: Kirigami.Units.smallSpacing
                            Layout.preferredHeight: codeRow.implicitHeight + (Kirigami.Units.smallSpacing * 2)
                            visible: codeSnippet !== ""
                            color: Kirigami.Theme.alternateBackgroundColor
                            radius: Kirigami.Units.smallSpacing
                            border.color: Kirigami.Theme.focusColor
                            border.width: 1
                            opacity: 0.9

                            RowLayout {
                                id: codeRow
                                anchors.fill: parent
                                anchors.margins: Kirigami.Units.smallSpacing
                                spacing: Kirigami.Units.smallSpacing

                                Controls.TextField {
                                    id: codeField
                                    Layout.fillWidth: true
                                    text: codeSnippet
                                    font.family: "monospace"
                                    readOnly: true
                                    background: null
                                    color: Kirigami.Theme.textColor
                                }

                                Controls.ToolButton {
                                    icon.name: "edit-copy"
                                    Controls.ToolTip.text: "Copiar comando"
                                    Controls.ToolTip.visible: hovered
                                    onClicked: {
                                        codeField.selectAll();
                                        codeField.copy();
                                        codeField.deselect();
                                        
                                        icon.name = "dialog-ok";
                                        feedbackTimer.start();
                                    }

                                    Timer {
                                        id: feedbackTimer
                                        interval: 2000
                                        onTriggered: parent.icon.name = "edit-copy"
                                    }
                                }
                            }
                        }
                    }
                }

                FeatureBlock {
                    iconName: "configure"
                    titleText: qsTrId("onboarding.configuration_title")
                    descText: qsTrId("onboarding.configuration_description")
                }

                FeatureBlock {
                    iconName: "video-display"
                    titleText: qsTrId("onboarding.desktop_display_title")
                    descText: qsTrId("onboarding.desktop_display_description")
                }

                FeatureBlock {
                    iconName: "media-playback-start"
                    titleText: qsTrId("onboarding.usage_title")
                    descText: qsTrId("onboarding.usage_description")
                }

                FeatureBlock {
                    iconName: "dialog-information"
                    titleText: qsTrId("onboarding.requirement_title")
                    descText: qsTrId("onboarding.requirement_description") + "\n\n" + qsTrId("onboarding.install_description")
                    codeSnippet: "./packaging/host/install.sh"
                }
            }
        }

        Kirigami.Separator {
            Layout.fillWidth: true
        }

        RowLayout {
            Layout.fillWidth: true

            Item { Layout.fillWidth: true }

            Controls.Button {
                text: qsTrId("common.got_it")
                icon.name: "dialog-ok"
                highlighted: true
                onClicked: sheet.close()
                
                Component.onCompleted: forceActiveFocus() 
            }
        }
    }
}