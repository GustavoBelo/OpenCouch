#include "appinfomodel.h"

#include <QCoreApplication>
#include <QFileInfo>
#include <QString>

#include "appversion.h"

namespace {
QString sanitizeVersion(const QString &value)
{
    const QString cleaned = value.trimmed();
    return cleaned.isEmpty() ? QStringLiteral(OPENCOUCH_VERSION_STRING) : cleaned;
}
}

AppInfoModel::AppInfoModel(QObject *parent)
    : QObject(parent)
{
}

QString AppInfoModel::appName() const
{
    return QStringLiteral("OpenCouch");
}

QString AppInfoModel::displayName() const
{
    return QStringLiteral("Open Couch");
}

QString AppInfoModel::version() const
{
    const QString currentVersion = QCoreApplication::applicationVersion();
    return sanitizeVersion(currentVersion.isEmpty() ? QStringLiteral(OPENCOUCH_VERSION_STRING)
                                                    : currentVersion);
}

QString AppInfoModel::formattedVersion() const
{
    return version();
}

QString AppInfoModel::distributionType() const
{
    if (QFileInfo::exists(QStringLiteral("/.flatpak-info"))) {
        return QStringLiteral("flatpak");
    }
    if (!qEnvironmentVariable("APPIMAGE").isEmpty()) {
        return QStringLiteral("appimage");
    }
    return QStringLiteral("native");
}

QString AppInfoModel::installScriptUrl() const
{
    return QStringLiteral("https://raw.githubusercontent.com/GustavoBelo/open-couch/v")
           + version() 
           + QStringLiteral("/packaging/host/install.sh");
}
