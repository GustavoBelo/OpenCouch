pragma Singleton
import QtQuick
import io.github.gustavobelo.opencouch

// The whole colour system: four colours and a set of named derivations.
//
// There is no grey ramp and no elevation palette, on purpose. Every surface in
// the app is the foreground colour at 4-22% over the background, and every
// border is the foreground at 14-28%. With one hue nothing can drift out of
// step, and a state change is a single token.
//
// The derivations are named properties rather than a helper function so that
// call sites cannot invent a forty-first alpha, and so the set stays small
// enough to hold in your head.
QtObject {
    // The four colours follow the desktop when the desktop publishes a theme,
    // and fall back to these otherwise. Everything below is derived, so a theme
    // change moves every surface, border and wash in step without any of them
    // being restated.
    readonly property color background: DesktopTheme.available ? DesktopTheme.background : "#0d0f12"
    readonly property color surface:    DesktopTheme.available ? DesktopTheme.surface    : "#11141a"
    readonly property color foreground: DesktopTheme.available ? DesktopTheme.foreground : "#e6e8ea"
    readonly property color accent:     DesktopTheme.available ? DesktopTheme.accent     : "#4ade80"
    readonly property color urgent:     DesktopTheme.available ? DesktopTheme.urgent     : "#f87171"

    // Dim text is derived rather than declared, so it can never disagree with
    // the foreground it is meant to recede from.
    readonly property color muted:    Qt.darker(foreground, 1.9)
    readonly property color disabled: Qt.darker(foreground, 2.6)

    // Foreground washes: the state ladder for a neutral surface.
    readonly property color fill:         Qt.rgba(foreground.r, foreground.g, foreground.b, 0.04)
    readonly property color fillHover:    Qt.rgba(foreground.r, foreground.g, foreground.b, 0.08)
    readonly property color fillSelected: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.18)
    readonly property color fillPressed:  Qt.rgba(foreground.r, foreground.g, foreground.b, 0.22)

    // Lines. Hairline is for dividers, line for card edges, lineHover for a
    // control the pointer is over, edge for something raised above the page.
    readonly property color hairline:  Qt.rgba(foreground.r, foreground.g, foreground.b, 0.08)
    readonly property color line:      Qt.rgba(foreground.r, foreground.g, foreground.b, 0.14)
    readonly property color edge:      Qt.rgba(foreground.r, foreground.g, foreground.b, 0.16)
    readonly property color lineHover: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.28)
    readonly property color lineRaised: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.22)

    // Accent washes, same ladder in the accent hue.
    readonly property color accentFill:     Qt.rgba(accent.r, accent.g, accent.b, 0.07)
    readonly property color accentWash:     Qt.rgba(accent.r, accent.g, accent.b, 0.10)
    readonly property color accentHover:    Qt.rgba(accent.r, accent.g, accent.b, 0.16)
    readonly property color accentSelected: Qt.rgba(accent.r, accent.g, accent.b, 0.26)
    readonly property color accentPressed:  Qt.rgba(accent.r, accent.g, accent.b, 0.34)
    readonly property color accentTrack:    Qt.rgba(accent.r, accent.g, accent.b, 0.32)
    readonly property color accentLine:     Qt.rgba(accent.r, accent.g, accent.b, 0.35)
    readonly property color accentEdge:     Qt.rgba(accent.r, accent.g, accent.b, 0.40)
    readonly property color accentBorder:   Qt.rgba(accent.r, accent.g, accent.b, 0.55)
    readonly property color accentStrong:   Qt.rgba(accent.r, accent.g, accent.b, 0.70)
    readonly property color accentBright:   Qt.rgba(accent.r, accent.g, accent.b, 0.90)

    readonly property color urgentWash: Qt.rgba(urgent.r, urgent.g, urgent.b, 0.10)
    readonly property color urgentEdge: Qt.rgba(urgent.r, urgent.g, urgent.b, 0.40)

    readonly property color scrim: Qt.rgba(background.r, background.g, background.b, 0.97)
    readonly property color veil:  Qt.rgba(background.r, background.g, background.b, 0.85)
}
