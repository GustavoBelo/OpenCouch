#include "configstore.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QSettings>
#include <QStandardPaths>
#include <QTextStream>

namespace {
QString normalizeValue(const QString &raw)
{
    QString value = raw.trimmed();
    if (value.size() >= 2 && value.startsWith('\'') && value.endsWith('\'')) {
        value = value.mid(1, value.length() - 2);
    }
    return value;
}
}

ConfigStore::ConfigStore(QObject *parent)
    : QObject(parent)
{
}

QString ConfigStore::configFilePath()
{
    const QString base = qEnvironmentVariableIsSet("XDG_CONFIG_HOME")
        ? qEnvironmentVariable("XDG_CONFIG_HOME")
        : QDir::homePath() + QStringLiteral("/.config");
    return base + QStringLiteral("/open-couch-engine/config.env");
}

QString ConfigStore::autostartDesktopFilePath()
{
    return QStandardPaths::writableLocation(QStandardPaths::ConfigLocation)
        + QStringLiteral("/autostart/io.github.gustavobelo.opencouch.desktop");
}

QVariantMap ConfigStore::loadConfig() const
{
    QVariantMap config;
    QFile file(configFilePath());
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) {
        return config;
    }

    QTextStream stream(&file);
    while (!stream.atEnd()) {
        const QString line = stream.readLine().trimmed();
        if (line.isEmpty() || line.startsWith('#')) {
            continue;
        }

        const int eq = line.indexOf('=');
        if (eq <= 0) {
            continue;
        }

        const QString key = line.left(eq).trimmed();
        QString value = normalizeValue(line.mid(eq + 1));
        if (!key.isEmpty()) {
            config.insert(key, value);
        }
    }
    return config;
}

bool ConfigStore::saveConfig(const QVariantMap &config) const
{
    const QString path = configFilePath();
    QDir().mkpath(QFileInfo(path).absolutePath());

    QFile file(path);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Text | QIODevice::Truncate)) {
        return false;
    }

    QTextStream stream(&file);
    stream << "# Gerado pelo app Open Couch - nao editar manualmente durante o uso do app\n";
    for (auto it = config.constBegin(); it != config.constEnd(); ++it) {
        stream << it.key() << "='" << it.value().toString().replace("'", "'\\''") << "'\n";
    }
    return true;
}

bool ConfigStore::autostartEnabled() const
{
    return QFileInfo::exists(autostartDesktopFilePath());
}

bool ConfigStore::setAutostart(bool enabled) const
{
    const QString path = autostartDesktopFilePath();
    if (!enabled) {
        return !QFileInfo::exists(path) || QFile::remove(path);
    }

    QDir().mkpath(QFileInfo(path).absolutePath());
    QFile file(path);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Text | QIODevice::Truncate)) {
        return false;
    }

    QTextStream stream(&file);
    stream << "[Desktop Entry]\n"
           << "Type=Application\n"
           << "Name=Open Couch\n"
           << "Comment=Alterna o layout das telas para desktop e sala\n"
           << "Exec=flatpak run io.github.gustavobelo.opencouch\n"
           << "Icon=io.github.gustavobelo.opencouch\n"
           << "X-GNOME-Autostart-enabled=true\n";
    return true;
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
