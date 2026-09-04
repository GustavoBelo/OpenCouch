pragma Singleton
import QtQuick

// Spacing, type and dimensions, as named tokens on one scale.
//
// Tokens rather than an arbitrary space(px) helper, and that is a design choice
// as much as a practical one: a function that takes any number invites forty
// different gaps and no rhythm. Ten steps and a handful of named dimensions
// force the layout to agree with itself.
//
// `scale` is the density knob: everything below multiplies by it, so nothing is
// hardcoded in pixels and nothing clips when it moves.
QtObject {
    readonly property real scale: 1.0

    // Rhythm.
    readonly property int xxs: Math.round(2 * scale)
    readonly property int xs:  Math.round(4 * scale)
    readonly property int sm:  Math.round(6 * scale)
    readonly property int md:  Math.round(8 * scale)
    readonly property int lg:  Math.round(10 * scale)
    readonly property int xl:  Math.round(12 * scale)
    readonly property int xxl: Math.round(14 * scale)
    readonly property int x3:  Math.round(16 * scale)
    readonly property int x4:  Math.round(20 * scale)
    readonly property int x5:  Math.round(24 * scale)

    // Type. Density comes from small text carrying weight and colour, not from
    // cramming large text into small boxes.
    readonly property int caption: Math.round(11 * scale)
    readonly property int body:    Math.round(14 * scale)
    readonly property int title:   Math.round(18 * scale)
    readonly property int heading: Math.round(22 * scale)
    readonly property int display: Math.round(30 * scale)
    readonly property int numeral: Math.round(96 * scale)

    readonly property int iconSmall: Math.round(16 * scale)
    readonly property int icon:      Math.round(20 * scale)
    readonly property int iconLarge: Math.round(28 * scale)

    readonly property int radius:      Math.round(10 * scale)
    readonly property int radiusSmall: Math.round(6 * scale)

    // Dimensions that are decisions, not rhythm.
    readonly property int controlHeight: Math.round(38 * scale)
    readonly property int buttonHeight:  Math.round(52 * scale)
    readonly property int iconButton:    Math.round(40 * scale)
    readonly property int headerHeight:  Math.round(56 * scale)
    readonly property int toggleWidth:   Math.round(44 * scale)
    readonly property int toggleHeight:  Math.round(24 * scale)
    readonly property int logHeight:     Math.round(200 * scale)
    readonly property int dropdownMax:   Math.round(280 * scale)
    readonly property int countdownWidth: Math.round(420 * scale)
    readonly property int sheetWidth:    Math.round(560 * scale)
    readonly property int sheetHeight:   Math.round(640 * scale)

    // Named uses of the rhythm, so a page never picks a step by eye.
    readonly property int pagePadding: x4
    readonly property int cardPadding: Math.round(18 * scale)
    readonly property int sectionGap:  x3
    readonly property int rowGap:      lg
    readonly property int labelGap:    sm

    // The motion budget. Surfaces cross-fade, geometry eases, spinners spin.
    // A duration that is not one of these is a bug.
    readonly property int fadeDuration: 60
    readonly property int moveDuration: 140
    readonly property int spinDuration: 900

    readonly property string monoFamily: "monospace"
}
