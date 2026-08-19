#include "applicationicon.h"

#include <QCoreApplication>
#include <QFileInfo>

QIcon applicationIcon()
{
    const QIcon bundledIcon(QStringLiteral(":/io.github.gustavobelo.opencouch.svg"));
    if (!bundledIcon.isNull()) {
        return bundledIcon;
    }

    const QStringList iconPaths = {
        QCoreApplication::applicationDirPath()
            + QStringLiteral("/../share/icons/hicolor/scalable/apps/io.github.gustavobelo.opencouch.svg"),
        QStringLiteral("/app/share/icons/hicolor/scalable/apps/io.github.gustavobelo.opencouch.svg"),
        QStringLiteral("/usr/share/icons/hicolor/scalable/apps/io.github.gustavobelo.opencouch.svg")
    };

    for (const QString &path : iconPaths) {
        if (QFileInfo::exists(path)) {
            return QIcon(path);
        }
    }

    const QIcon themedIcon = QIcon::fromTheme(QStringLiteral("io.github.gustavobelo.opencouch"));
    if (!themedIcon.isNull()) {
        return themedIcon;
    }

    const QStringList fallbackNames = {
        QStringLiteral("applications-graphics"),
        QStringLiteral("preferences-desktop-display"),
        QStringLiteral("preferences-system-windows")
    };
    for (const QString &name : fallbackNames) {
        const QIcon fallbackIcon = QIcon::fromTheme(name);
        if (!fallbackIcon.isNull()) {
            return fallbackIcon;
        }
    }

    return QIcon();
}
