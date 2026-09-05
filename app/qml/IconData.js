.pragma library

// The icon set, as path data on a 24x24 grid.
//
// Drawn here rather than loaded from the system icon theme, and as Shape paths
// rather than SVG images. The theme was not survivable: on the machine this was
// built for, 9 of the 23 names the app used did not exist and the rest resolved
// to 16-pixel legacy art being drawn at 22 and 32. Paths were chosen over
// bundled SVG files because ShapePath takes a colour as a plain property --
// tinting an image needs a shader effect, and those render nothing at all under
// a software rasteriser.
//
// Each entry is a list of strokes, plus optional fills. One weight throughout:
// 2px on the 24 grid, round caps, round joins.

function circle(cx, cy, r) {
    return "M" + (cx - r) + " " + cy
         + "a" + r + " " + r + " 0 1 0 " + (2 * r) + " 0"
         + "a" + r + " " + r + " 0 1 0 " + (-2 * r) + " 0";
}

function roundRect(x, y, w, h, r) {
    return "M" + (x + r) + " " + y
         + "h" + (w - 2 * r) + "a" + r + " " + r + " 0 0 1 " + r + " " + r
         + "v" + (h - 2 * r) + "a" + r + " " + r + " 0 0 1 " + (-r) + " " + r
         + "h" + (-(w - 2 * r)) + "a" + r + " " + r + " 0 0 1 " + (-r) + " " + (-r)
         + "v" + (-(h - 2 * r)) + "a" + r + " " + r + " 0 0 1 " + r + " " + (-r) + "z";
}

var icons = {
    // The action. Solid, because a filled triangle reads as a command and an
    // outlined one as a hint.
    "enter":    { fills: ["M8 5.2l12 6.8-12 6.8z"] },

    "display":  { strokes: [roundRect(2.5, 4, 19, 13, 2), "M9 20.5h6M12 17.5v3"] },
    "session":  { strokes: ["M4 8.5h13l-3.2-3.2M20 15.5H7l3.2 3.2"] },
    "check":    { strokes: ["M4.5 12.5l5 5 10-11"] },
    "warn":     { strokes: ["M12 3.8L2.7 20.1h18.6z", "M12 9.6v4.8"],
                  fills: [circle(12, 17.7, 0.95)] },
    "refresh":  { strokes: ["M20 12a8 8 0 1 1-2.6-5.9", "M20.6 3.2v5h-5"] },
    "log":      { strokes: ["M4 6.5h16M4 12h16M4 17.5h10"] },
    "settings": { strokes: ["M3 7.5h4M13 7.5h8M3 16.5h8M17 16.5h4",
                            circle(10, 7.5, 2.6), circle(14, 16.5, 2.6)] },
    "help":     { strokes: [circle(12, 12, 9),
                            "M9.4 9.3a2.7 2.7 0 1 1 3.4 3.3c-.6.25-.9.8-.9 1.35v.65"],
                  fills: [circle(12, 17.4, 0.95)] },
    "copy":     { strokes: [roundRect(9, 9, 12, 12, 2),
                            "M5 15H4a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h10a1 1 0 0 1 1 1v1"] },
    "save":     { strokes: ["M12 3.5v11M7.5 10l4.5 4.5 4.5-4.5",
                            "M3.5 16v3.5a1 1 0 0 0 1 1h15a1 1 0 0 0 1-1V16"] },
    "clear":    { strokes: ["M3.5 6.5h17M9 6.5V4.5a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2",
                            "M5.5 6.5l1 13a1 1 0 0 0 1 .95h9a1 1 0 0 0 1-.95l1-13"] },
    "history":  { strokes: ["M3.5 12a8.5 8.5 0 1 0 2.8-6.3", "M3 3.6v4.4h4.4", "M12 7.5V12l3 2"] },
    "power":    { strokes: ["M12 3v8.5", "M18 6.3a8.5 8.5 0 1 1-12 0"] },
    "chevron":  { strokes: ["M6 9.5l6 6 6-6"] },
    "close":    { strokes: ["M6 6l12 12M18 6L6 18"] },
    "heart":    { fills: ["M12 20.8l-1.5-1.36C5.2 14.68 2 11.78 2 8.22 2 5.32 4.28 3 7.2 3c1.65 0 3.23.77 4.26 1.98h1.08C13.57 3.77 15.15 3 16.8 3 19.72 3 22 5.32 22 8.22c0 3.56-3.2 6.46-8.5 11.23z"] }
};

function strokesFor(name) {
    var entry = icons[name];
    return (entry && entry.strokes) ? entry.strokes : [];
}

function fillsFor(name) {
    var entry = icons[name];
    return (entry && entry.fills) ? entry.fills : [];
}

function has(name) {
    return icons.hasOwnProperty(name);
}
