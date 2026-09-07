#include "configstore.h"

#include <QDBusConnection>
#include <QDBusInterface>
#include <QDBusPendingCall>
#include <QDBusPendingReply>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QSettings>
#include <QStandardPaths>
#include <QTextStream>

namespace {
QString autostartCommand()
{
    // Just the name. It is on PATH whether a package installed it or a build
    // did, and there is no bundle to point at any more.
    return QStringLiteral("opencouch");
}

QString desktopEntryArgument(const QString &argument)
{
    QString escaped = argument;
    escaped.replace(QStringLiteral("\\"), QStringLiteral("\\\\"));
    escaped.replace(QLatin1Char('"'), QStringLiteral("\\\""));
    escaped.replace(QLatin1Char('`'), QStringLiteral("\\`"));
    escaped.replace(QLatin1Char('$'), QStringLiteral("\\$"));
    return QStringLiteral("\"") + escaped + QStringLiteral("\"");
}

QString autostartEntryPath()
{
    return QStandardPaths::writableLocation(QStandardPaths::ConfigLocation)
        + QStringLiteral("/autostart/io.github.gustavobelo.opencouch.desktop");
}

bool updateAutostartEntry(bool enabled)
{
    const QString path = autostartEntryPath();
    QFile entry(path);
    if (!enabled) {
        if (!entry.exists()) {
            return true;
        }
        if (!entry.open(QIODevice::ReadOnly | QIODevice::Text)) {
            return false;
        }
        const bool managedByOpenCouch = QTextStream(&entry).readAll()
            .contains(QStringLiteral("X-Open-Couch-Autostart=true"));
        entry.close();
        return !managedByOpenCouch || entry.remove();
    }

    if (!QDir().mkpath(QFileInfo(path).absolutePath())) {
        return false;
    }
    if (!entry.open(QIODevice::WriteOnly | QIODevice::Text | QIODevice::Truncate)) {
        return false;
    }

    QTextStream stream(&entry);
    stream << "[Desktop Entry]\n"
           << "Type=Application\n"
           << "Name=Open Couch\n"
           << "Exec=" << desktopEntryArgument(autostartCommand()) << "\n"
           << "Icon=io.github.gustavobelo.opencouch\n"
           << "Terminal=false\n"
           << "X-GNOME-Autostart-enabled=true\n"
           << "X-Open-Couch-Autostart=true\n";
    return stream.status() == QTextStream::Ok;
}

}

ConfigStore::ConfigStore(QObject *parent)
    : QObject(parent)
{
}

bool ConfigStore::autostartEnabled() const
{
    return QSettings().value(QStringLiteral("autostartEnabled"), false).toBool();
}

bool ConfigStore::setAutostart(bool enabled) const
{
    // The portal first, because a desktop that has one wants to know; the
    // autostart entry when it does not answer. There is no sandbox left to
    // decide between, so both paths are simply tried in order.
    bool success = requestBackgroundPortal(enabled);
    if (!success) {
        success = updateAutostartEntry(enabled);
    } else if (!enabled) {
        updateAutostartEntry(false);
    }

    if (success) {
        QSettings().setValue(QStringLiteral("autostartEnabled"), enabled);
    }
    return success;
}

bool ConfigStore::requestBackgroundPortal(bool enabled) const
{
    QDBusInterface portal (
        QStringLiteral("org.freedesktop.portal.Desktop"),
        QStringLiteral("/org/freedesktop/portal/desktop"),
        QStringLiteral("org.freedesktop.portal.Background"),
        QDBusConnection::sessionBus()
    );

    if (!portal.isValid()) {
        return false;
    }

    QVariantMap options;
    options[QStringLiteral("reason")] =
        QStringLiteral("Used to monitor Steam and automatically switch displays.");
    options[QStringLiteral("autostart")] = enabled;
    options[QStringLiteral("commandline")] = QStringList{autostartCommand()};
    options[QStringLiteral("dbus-activatable")] = false;

    QDBusPendingCall pending = portal.asyncCall(
        QStringLiteral("RequestBackground"),
        QStringLiteral(""),
        options
    );

    QDBusPendingReply<QDBusObjectPath> reply(pending);
    reply.waitForFinished();
    return !reply.isError();
}

bool ConfigStore::backgroundOnClose() const
{
    return QSettings().value(QStringLiteral("backgroundOnClose"), true).toBool();
}

bool ConfigStore::setBackgroundOnClose(bool enabled) const
{
    QSettings settings;
    settings.setValue(QStringLiteral("backgroundOnClose"), enabled);
    return true;
}

bool ConfigStore::startMinimized() const
{
    return QSettings().value(QStringLiteral("startMinimized"), false).toBool();
}

bool ConfigStore::setStartMinimized(bool enabled) const
{
    QSettings settings;
    settings.setValue(QStringLiteral("startMinimized"), enabled);
    return true;
}

bool ConfigStore::onboardingSeen() const
{
    QSettings settings;
    return settings.value(QStringLiteral("onboardingSeen"), false).toBool();
}

void ConfigStore::setOnboardingSeen(bool seen) const
{
    QSettings settings;
    settings.setValue(QStringLiteral("onboardingSeen"), seen);
}
