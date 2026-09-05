#include "desktoptheme.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QRegularExpression>
#include <QTextStream>
#include <QTimer>

namespace {
// Only the keys this application has a use for. colors.toml carries a full
// terminal palette as well; reading the lot and exposing it would invite the
// interface to grow a second colour system next to the one it has.
const QLatin1String kColorsFile("colors.toml");
const QLatin1String kNameFile("theme.name");

QColor colorFor(const QHash<QString, QString> &values, const char *key)
{
    const QString raw = values.value(QString::fromLatin1(key)).trimmed();
    if (raw.isEmpty()) {
        return QColor();
    }
    const QColor parsed(raw);
    return parsed.isValid() ? parsed : QColor();
}
}

QString DesktopTheme::themeDir()
{
    return QDir::homePath() + QStringLiteral("/.local/state/omarchy/current/theme");
}

DesktopTheme::DesktopTheme(QObject *parent)
    : QObject(parent)
{
    connect(&m_watcher, &QFileSystemWatcher::fileChanged, this, [this]() {
        // The file is rewritten rather than edited, so it briefly disappears.
        // Reading on the change signal alone catches it mid-write; a short
        // delay lets the writer finish, and rewatch puts the watch back on the
        // new inode.
        QTimer::singleShot(120, this, [this]() {
            rewatch();
            reload();
        });
    });
    connect(&m_watcher, &QFileSystemWatcher::directoryChanged, this, [this]() {
        QTimer::singleShot(120, this, [this]() {
            rewatch();
            reload();
        });
    });

    rewatch();
    reload();
}

void DesktopTheme::rewatch()
{
    if (!m_watcher.files().isEmpty()) {
        m_watcher.removePaths(m_watcher.files());
    }
    if (!m_watcher.directories().isEmpty()) {
        m_watcher.removePaths(m_watcher.directories());
    }

    const QString dir = themeDir();
    if (QFileInfo::exists(dir)) {
        // The directory as well as the file: switching themes replaces the
        // whole directory, and a watch on the old file would be left pointing
        // at an inode nobody writes to again.
        m_watcher.addPath(dir);
        const QString colors = dir + QLatin1Char('/') + kColorsFile;
        if (QFileInfo::exists(colors)) {
            m_watcher.addPath(colors);
        }
    }
}

void DesktopTheme::reload()
{
    const QString dir = themeDir();
    QFile file(dir + QLatin1Char('/') + kColorsFile);

    const bool wasAvailable = m_available;

    if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) {
        m_available = false;
        if (wasAvailable) {
            emit changed();
        }
        return;
    }

    // A deliberately small TOML reader: this file is a flat list of
    // `key = "value"` lines, and pulling in a parser for it would be a
    // dependency bigger than the feature.
    QHash<QString, QString> values;
    static const QRegularExpression line(QStringLiteral("^\\s*([A-Za-z_]+)\\s*=\\s*\"([^\"]*)\"\\s*$"));
    QTextStream stream(&file);
    while (!stream.atEnd()) {
        const QRegularExpressionMatch match = line.match(stream.readLine());
        if (match.hasMatch()) {
            values.insert(match.captured(1), match.captured(2));
        }
    }

    const QColor background = colorFor(values, "background");
    const QColor foreground = colorFor(values, "foreground");
    const QColor accent = colorFor(values, "accent");

    // A theme missing any of the three is not usable: filling the gaps from the
    // built-in palette would produce a mix that neither side chose.
    if (!background.isValid() || !foreground.isValid() || !accent.isValid()) {
        m_available = false;
        if (wasAvailable) {
            emit changed();
        }
        return;
    }

    m_background = background;
    m_foreground = foreground;
    m_accent = accent;

    const QColor surface = colorFor(values, "lighter_background");
    m_surface = surface.isValid() ? surface : background.lighter(130);

    const QColor red = colorFor(values, "red");
    m_urgent = red.isValid() ? red : QColor(QStringLiteral("#f87171"));

    QFile nameFile(dir + QLatin1Char('/') + kNameFile);
    if (nameFile.open(QIODevice::ReadOnly | QIODevice::Text)) {
        m_name = QString::fromUtf8(nameFile.readAll()).trimmed();
    }

    m_available = true;
    emit changed();
}
