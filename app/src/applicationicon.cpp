#include "applicationicon.h"

#include <QIcon>
#include <QIconEngine>

namespace {
// The 512 is deliberately not bundled: it is 292 KB and nothing in this
// application draws an icon that large. A window icon, a tray icon and a task
// switcher entry all live between 16 and 64, and the 256 covers whatever a
// scaled desktop asks for beyond that. The installed icon theme has the 512 for
// anything that really wants it.
const int kBundledSizes[] = {16, 24, 32, 48, 64, 128, 256};
}

QIcon applicationIcon()
{
    // Built from the sizes rather than from one image scaled down. The icon is
    // a drawing of a room -- a shelf, a poster, two controllers -- and letting
    // one renderer squeeze all of that into 16 pixels gives mud. Each size was
    // resampled on its own, and Qt picks the nearest rather than resampling
    // again.
    QIcon icon;
    for (const int size : kBundledSizes) {
        icon.addFile(QStringLiteral(":/icons/%1.png").arg(size), QSize(size, size));
    }
    if (!icon.availableSizes().isEmpty()) {
        return icon;
    }

    // Nothing was bundled, which means the resource did not build. The theme is
    // the only place left to look: a package installs the same set under
    // hicolor, so on an installed system this still finds the real icon.
    const QIcon themedIcon = QIcon::fromTheme(QStringLiteral("io.github.gustavobelo.opencouch"));
    if (!themedIcon.availableSizes().isEmpty()) {
        return themedIcon;
    }

    const QStringList fallbackNames = {
        QStringLiteral("applications-games"),
        QStringLiteral("preferences-desktop-display"),
        QStringLiteral("preferences-system-windows")
    };
    for (const QString &name : fallbackNames) {
        const QIcon fallbackIcon = QIcon::fromTheme(name);
        if (!fallbackIcon.availableSizes().isEmpty()) {
            return fallbackIcon;
        }
    }

    return QIcon();
}
