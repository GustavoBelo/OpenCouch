#include "appcleanupmodel.h"

#include "backend.h"
#include "configstore.h"

#include <QCoreApplication>
#include <QDebug>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcess>
#include <QRegularExpression>
#include <QSet>
#include <QStandardPaths>
#include <QTextStream>
#include <QThread>
#include <QMutexLocker>

#include <algorithm>
#include <unistd.h>

namespace {
const QStringList kProtectedProcesses = {
    QStringLiteral("plasmashell"),
    QStringLiteral("kwin_wayland"),
    QStringLiteral("kwin_x11"),
    QStringLiteral("kwin_wayland_wrapper"),
    QStringLiteral("ksmserver"),
    QStringLiteral("systemsettings"),
    QStringLiteral("steam"),
    QStringLiteral("steamwebhelper"),
    QStringLiteral("open-couch"),
    QStringLiteral("opencouch"),
    QStringLiteral("open-couch-engine"),
    QStringLiteral("Xwayland")
};
}

AppCleanupModel::AppCleanupModel(QObject *parent)
    : QObject(parent),
      m_configStore(new ConfigStore(this))
{
    m_enabled = m_configStore->closeAppsEnabled();
    m_waitSeconds = m_configStore->closeAppsWaitSeconds();
}

bool AppCleanupModel::isProtectedProcess(const QString &name)
{
    const QString lower = name.toLower();
    if (lower.startsWith(QLatin1String("xwayland"))) {
        return true;
    }
    for (const QString &p : kProtectedProcesses) {
        if (p.toLower() == lower) {
            return true;
        }
    }
    return false;
}

QStringList AppCleanupModel::extractProcessNames(const QString &execLine)
{
    QStringList names;
    if (execLine.contains(QLatin1String("flatpak run"))) {
        QRegularExpression cmdRe(R"(--command=([^\s]+))");
        QRegularExpressionMatch m = cmdRe.match(execLine);
        if (m.hasMatch()) {
            QString cmd = m.captured(1);
            cmd.remove(QLatin1Char('"'));
            cmd.remove(QLatin1Char('\''));
            if (cmd.contains(QLatin1Char('/'))) {
                cmd = QFileInfo(cmd).fileName();
                cmd = cmd.trimmed();
                if (!cmd.isEmpty()) {
                    names << cmd;
                }
            }
        }
        QRegularExpression appIdRe(R"([A-Za-z0-9_-]+\.[A-Za-z0-9._-]+)");
        QRegularExpressionMatchIterator it = appIdRe.globalMatch(execLine);
        QString appId;
        while (it.hasNext()) {
            QRegularExpressionMatch mm = it.next();
            QString cand = mm.captured(0);
            if (cand.contains(QLatin1Char('.'))) {
                appId = cand;
                break;
            }
        }
        if (!appId.isEmpty()) {
            QString last = appId.section(QLatin1Char('.'), -1).trimmed();
            if (!last.isEmpty()) {
                names << last;
            }
        }
        if (names.isEmpty()) {
            names << QStringLiteral("flatpak");
        }
    } else {
        QString cleaned = execLine;
        cleaned.remove(QRegularExpression(R"(\s%[fFuUdDnNiCkKvVm])"));
        cleaned = cleaned.trimmed();
        QStringList parts = cleaned.split(QRegularExpression(R"(\s+)"), Qt::SkipEmptyParts);
        QString token;
        for (const QString &p : parts) {
            if (p.contains(QLatin1Char('=')) && !p.contains(QLatin1Char('/')) && !p.contains(QLatin1Char(':'))) {
                QRegularExpression envRe(R"(^[A-Za-z_][A-Za-z0-9_]*=)");
                if (envRe.match(p).hasMatch()) {
                    continue;
                }
            }
            if (p == QLatin1String("env")) {
                continue;
            }
            token = p;
            break;
        }
        if (token.isEmpty() && !parts.isEmpty()) {
            token = parts.first();
        }
        token.remove(QLatin1Char('"'));
        token.remove(QLatin1Char('\''));
        QString pname = QFileInfo(token).fileName().trimmed();
        if (!pname.isEmpty()) {
            names << pname;
        }
    }
    return names;
}

static bool isRunningInFlatpak()
{
    return QFileInfo::exists(QStringLiteral("/.flatpak-info"));
}

QStringList AppCleanupModel::desktopSearchDirs()
{
    QStringList dirs;
    QString dataHome = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + QStringLiteral("/applications");
    dirs << dataHome;

    QString xdgDataDirs = qEnvironmentVariable("XDG_DATA_DIRS", QStringLiteral("/usr/local/share:/usr/share"));
    for (const QString &d : xdgDataDirs.split(QLatin1Char(':'), Qt::SkipEmptyParts)) {
        if (d.isEmpty()) continue;
        dirs << d + QStringLiteral("/applications");
    }
    dirs << QDir::homePath() + QStringLiteral("/.local/share/flatpak/exports/share/applications");
    dirs << QStringLiteral("/var/lib/flatpak/exports/share/applications");
    dirs << QStringLiteral("/var/lib/snapd/desktop/applications");

    if (isRunningInFlatpak()) {
        // Host filesystem is often exposed at /run/host when running inside Flatpak
        dirs << QStringLiteral("/run/host/usr/share/applications");
        dirs << QStringLiteral("/run/host/usr/local/share/applications");
        dirs << QDir::homePath() + QStringLiteral("/.local/share/flatpak/exports/share/applications");
        dirs << QStringLiteral("/run/host/var/lib/flatpak/exports/share/applications");
        // Also try to read host XDG_DATA_DIRS via flatpak-spawn if available
    }

    // deduplicate preserving order
    QSet<QString> seen;
    QStringList uniq;
    for (const QString &d : dirs) {
        if (!seen.contains(d)) {
            seen.insert(d);
            uniq << d;
        }
    }
    return uniq;
}

QStringList AppCleanupModel::enumerateDesktopFiles(const QString &baseDir)
{
    QStringList files;
    QDir dir(baseDir);
    if (!dir.exists()) {
        return files;
    }
    QDirIterator it(baseDir, QStringList() << QStringLiteral("*.desktop"), QDir::Files, QDirIterator::Subdirectories | QDirIterator::FollowSymlinks);
    while (it.hasNext()) {
        QString path = it.next();
        QString rel = path.mid(baseDir.length() + 1);
        // depth = number of '/' + 1 (file itself). Allow up to 2 levels (file at top or one subdir)
        int slashCount = rel.count(QLatin1Char('/'));
        if (slashCount >= 2) {
            continue;
        }
        files << path;
    }
    return files;
}

static QVariantList runHostEngine(const QStringList &args)
{
    QProcess proc;
    QStringList cmd;
    // When inside Flatpak, use flatpak-spawn --host to reach the host engine
    if (isRunningInFlatpak()) {
        cmd << QStringLiteral("flatpak-spawn") << QStringLiteral("--host");
    }
    // Prefer the user-installed engine in ~/.local/bin
    QString enginePath = QDir::homePath() + QStringLiteral("/.local/bin/open-couch-engine");
    if (QFileInfo::exists(enginePath)) {
        cmd << enginePath;
    } else {
        cmd << QStringLiteral("open-couch-engine");
    }
    cmd.append(args);
    proc.start(cmd.first(), cmd.mid(1));
    if (!proc.waitForFinished(5000)) {
        return {};
    }
    if (proc.exitStatus() != QProcess::NormalExit || proc.exitCode() != 0) {
        return {};
    }
    QByteArray out = proc.readAllStandardOutput();
    QJsonDocument doc = QJsonDocument::fromJson(out);
    if (!doc.isArray()) {
        return {};
    }
    QVariantList result;
    for (const QJsonValue &v : doc.array()) {
        if (!v.isObject()) continue;
        result.append(v.toObject().toVariantMap());
    }
    return result;
}

QMap<QString, QVariantMap> AppCleanupModel::buildDesktopMap()
{
    QMutexLocker locker(&m_cacheMutex);
    if (m_desktopCacheBuilt) {
        return m_desktopMap;
    }
    locker.unlock();

    // Try fast native scan first
    QMap<QString, QVariantMap> map;
    QStringList searchDirs = desktopSearchDirs();
    QSet<QString> visited;
    for (const QString &dirPath : searchDirs) {
        if (visited.contains(dirPath)) continue;
        visited.insert(dirPath);
        QDir d(dirPath);
        if (!d.exists()) continue;
        QStringList files = enumerateDesktopFiles(dirPath);
        for (const QString &filePath : files) {
            QFile file(filePath);
            if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) continue;
            QTextStream in(&file);
            QString name, exec, icon, type;
            bool noDisplay = false, hidden = false;
            bool nameSet = false, execSet = false, iconSet = false, typeSet = false;
            while (!in.atEnd()) {
                QString line = in.readLine().trimmed();
                if (line.isEmpty() || line.startsWith(QLatin1Char('#'))) continue;
                if (!typeSet && line.startsWith(QLatin1String("Type="))) {
                    type = line.mid(5).trimmed();
                    typeSet = true;
                } else if (line.startsWith(QLatin1String("NoDisplay="))) {
                    QString v = line.mid(10).trimmed();
                    noDisplay = (v.compare(QLatin1String("true"), Qt::CaseInsensitive) == 0);
                } else if (line.startsWith(QLatin1String("Hidden="))) {
                    QString v = line.mid(7).trimmed();
                    hidden = (v.compare(QLatin1String("true"), Qt::CaseInsensitive) == 0);
                } else if (!nameSet && line.startsWith(QLatin1String("Name="))) {
                    name = line.mid(5).trimmed();
                    nameSet = true;
                } else if (!execSet && line.startsWith(QLatin1String("Exec="))) {
                    exec = line.mid(5).trimmed();
                    execSet = true;
                } else if (!iconSet && line.startsWith(QLatin1String("Icon="))) {
                    icon = line.mid(5).trimmed();
                    iconSet = true;
                }
            }
            if (noDisplay || hidden) continue;
            if (!type.isEmpty() && type != QLatin1String("Application")) continue;
            if (name.isEmpty() || exec.isEmpty()) continue;
            QStringList pnames = extractProcessNames(exec);
            for (const QString &pname : pnames) {
                if (pname.isEmpty()) continue;
                if (isProtectedProcess(pname)) continue;
                QString lower = pname.toLower();
                if (map.contains(lower)) continue;
                QVariantMap entry;
                entry.insert(QStringLiteral("processName"), pname);
                entry.insert(QStringLiteral("displayName"), name);
                entry.insert(QStringLiteral("icon"), icon.isEmpty() ? QStringLiteral("application-x-executable") : icon);
                map.insert(lower, entry);
            }
        }
    }

    // Inside Flatpak the native scan may see only the runtime's apps (~20 entries).
    // If we are in Flatpak and the map looks suspiciously small, try the host.
    if (isRunningInFlatpak() && map.size() < 30) {
        QVariantList hostList = runHostEngine({QStringLiteral("list-apps")});
        if (!hostList.isEmpty()) {
            QMap<QString, QVariantMap> hostMap;
            for (const QVariant &v : hostList) {
                QVariantMap m = v.toMap();
                QString pn = m.value(QStringLiteral("processName")).toString();
                if (pn.isEmpty() || isProtectedProcess(pn)) continue;
                QString lower = pn.toLower();
                if (hostMap.contains(lower)) continue;
                hostMap.insert(lower, m);
            }
            if (hostMap.size() > map.size()) {
                map = hostMap;
            }
        }
    }

    locker.relock();
    m_desktopMap = map;
    m_desktopCacheBuilt = true;
    return m_desktopMap;
}

QVariantList AppCleanupModel::buildInstalledList()
{
    QMap<QString, QVariantMap> map = buildDesktopMap();
    QVariantList result;
    result.reserve(map.size());
    for (auto it = map.constBegin(); it != map.constEnd(); ++it) {
        result.append(it.value());
    }
    std::sort(result.begin(), result.end(), [](const QVariant &a, const QVariant &b) {
        return a.toMap().value(QStringLiteral("displayName")).toString().localeAwareCompare(
                   b.toMap().value(QStringLiteral("displayName")).toString()) < 0;
    });
    return result;
}

QVariantList AppCleanupModel::buildRunningList()
{
    // Inside Flatpak the sandbox's /proc only shows sandbox processes.
    // Prefer host's view via /run/host/proc or engine host call.
    if (isRunningInFlatpak()) {
        if (QDir(QStringLiteral("/run/host/proc")).exists()) {
            // Use host proc directly with native scanning
            QMap<QString, QVariantMap> desktopMap = buildDesktopMap();
            QDir procDir(QStringLiteral("/run/host/proc"));
            QStringList entries = procDir.entryList(QDir::Dirs | QDir::NoDotAndDotDot);
            QSet<QString> seenLower;
            QVariantList result;
            uid_t currentUid = ::getuid();
            for (const QString &entry : entries) {
                bool ok = false;
                int pid = entry.toInt(&ok);
                if (!ok) continue;
                QString procPath = QStringLiteral("/run/host/proc/") + entry;
                QFileInfo procInfo(procPath);
                if (procInfo.ownerId() != currentUid) {
                    if (procInfo.exists() && procInfo.ownerId() != 0) {
                        continue;
                    }
                }
                QString exePath = QStringLiteral("/run/host/proc/") + entry + QStringLiteral("/exe");
                QFileInfo exeInfo(exePath);
                QString target = exeInfo.symLinkTarget();
                QString pname;
                if (!target.isEmpty()) {
                    pname = QFileInfo(target).fileName();
                    if (pname.endsWith(QLatin1String(" (deleted)"))) {
                        pname.chop(10);
                    }
                    pname = pname.trimmed();
                }
                if (pname.isEmpty()) {
                    QFile commFile(QStringLiteral("/run/host/proc/") + entry + QStringLiteral("/comm"));
                    if (commFile.open(QIODevice::ReadOnly)) {
                        pname = QString::fromUtf8(commFile.readAll()).trimmed();
                    }
                }
                if (pname.isEmpty()) continue;
                QString lower = pname.toLower();
                if (seenLower.contains(lower)) continue;
                if (isProtectedProcess(pname)) continue;
                auto it = desktopMap.find(lower);
                if (it == desktopMap.end()) continue;
                seenLower.insert(lower);
                QString displayName = it.value().value(QStringLiteral("displayName")).toString();
                QString icon = it.value().value(QStringLiteral("icon")).toString();
                if (displayName.isEmpty()) displayName = pname;
                if (icon.isEmpty()) icon = QStringLiteral("application-x-executable");
                QString windowTitle;
                QFile cmdFile(QStringLiteral("/run/host/proc/") + entry + QStringLiteral("/cmdline"));
                if (cmdFile.open(QIODevice::ReadOnly)) {
                    QByteArray data = cmdFile.readAll();
                    data.replace('\0', ' ');
                    windowTitle = QString::fromUtf8(data).trimmed().left(300);
                }
                if (windowTitle.isEmpty()) windowTitle = displayName;
                QVariantMap m;
                m.insert(QStringLiteral("processName"), pname);
                m.insert(QStringLiteral("pid"), pid);
                m.insert(QStringLiteral("displayName"), displayName);
                m.insert(QStringLiteral("windowTitle"), windowTitle);
                m.insert(QStringLiteral("icon"), icon);
                result.append(m);
            }
            std::sort(result.begin(), result.end(), [](const QVariant &a, const QVariant &b) {
                return a.toMap().value(QStringLiteral("displayName")).toString().localeAwareCompare(
                           b.toMap().value(QStringLiteral("displayName")).toString()) < 0;
            });
            if (!result.isEmpty()) return result;
        }
        // Fallback: ask host engine (bash, but async so UI not blocked)
        QVariantList hostResult = runHostEngine({QStringLiteral("list-running")});
        if (!hostResult.isEmpty()) {
            std::sort(hostResult.begin(), hostResult.end(), [](const QVariant &a, const QVariant &b) {
                return a.toMap().value(QStringLiteral("displayName")).toString().localeAwareCompare(
                           b.toMap().value(QStringLiteral("displayName")).toString()) < 0;
            });
            return hostResult;
        }
        // Final fallback: continue to native sandbox proc (will be limited)
    }

    QMap<QString, QVariantMap> desktopMap = buildDesktopMap();
    QDir procDir(QStringLiteral("/proc"));
    QStringList entries = procDir.entryList(QDir::Dirs | QDir::NoDotAndDotDot);
    QSet<QString> seenLower;
    QVariantList result;
    uid_t currentUid = ::getuid();

    for (const QString &entry : entries) {
        bool ok = false;
        int pid = entry.toInt(&ok);
        if (!ok) continue;
        QString procPath = QStringLiteral("/proc/") + entry;
        QFileInfo procInfo(procPath);
        // filter by user
        if (procInfo.ownerId() != currentUid) {
            // On some systems proc owner may not be reliable via QFileInfo, fallback to reading status if needed
            // but keep filter; if we cannot determine owner, allow
            // Check if ownerId is 0 when file not exists -> skip check
            if (procInfo.exists() && procInfo.ownerId() != 0) {
                // only skip if we are sure it's another user
                // QFileInfo::ownerId returns 0 for root-owned proc dirs of other users? So skip non-current
                // But for flatpak bwrap, owner is still user
                // So if owner != currentUid, skip
                continue;
            }
        }
        QString exePath = QStringLiteral("/proc/") + entry + QStringLiteral("/exe");
        QFileInfo exeInfo(exePath);
        QString target = exeInfo.symLinkTarget();
        QString pname;
        if (!target.isEmpty()) {
            pname = QFileInfo(target).fileName();
            if (pname.endsWith(QLatin1String(" (deleted)"))) {
                pname.chop(10);
            }
            pname = pname.trimmed();
        }
        if (pname.isEmpty()) {
            QFile commFile(QStringLiteral("/proc/") + entry + QStringLiteral("/comm"));
            if (commFile.open(QIODevice::ReadOnly)) {
                pname = QString::fromUtf8(commFile.readAll()).trimmed();
            }
        }
        if (pname.isEmpty()) continue;
        QString lower = pname.toLower();
        if (seenLower.contains(lower)) continue;
        if (isProtectedProcess(pname)) continue;
        auto it = desktopMap.find(lower);
        if (it == desktopMap.end()) continue;
        seenLower.insert(lower);
        QString displayName = it.value().value(QStringLiteral("displayName")).toString();
        QString icon = it.value().value(QStringLiteral("icon")).toString();
        if (displayName.isEmpty()) displayName = pname;
        if (icon.isEmpty()) icon = QStringLiteral("application-x-executable");

        QString windowTitle;
        QFile cmdFile(QStringLiteral("/proc/") + entry + QStringLiteral("/cmdline"));
        if (cmdFile.open(QIODevice::ReadOnly)) {
            QByteArray data = cmdFile.readAll();
            data.replace('\0', ' ');
            windowTitle = QString::fromUtf8(data).trimmed().left(300);
        }
        if (windowTitle.isEmpty()) windowTitle = displayName;

        QVariantMap m;
        m.insert(QStringLiteral("processName"), pname);
        m.insert(QStringLiteral("pid"), pid);
        m.insert(QStringLiteral("displayName"), displayName);
        m.insert(QStringLiteral("windowTitle"), windowTitle);
        m.insert(QStringLiteral("icon"), icon);
        result.append(m);
    }

    std::sort(result.begin(), result.end(), [](const QVariant &a, const QVariant &b) {
        return a.toMap().value(QStringLiteral("displayName")).toString().localeAwareCompare(
                   b.toMap().value(QStringLiteral("displayName")).toString()) < 0;
    });
    return result;
}

void AppCleanupModel::bindBackend(Backend *backend)
{
    m_backend = backend;
    if (!m_backend || !m_configStore) {
        return;
    }
    // Async to avoid blocking SetupPage
    requestInstalledApplications();
    // When installed apps are ready, resolve appsToClose
    // Connect once
    static bool connected = false;
    if (!connected) {
        connected = true;
        connect(this, &AppCleanupModel::installedAppsChanged, this, [this]() {
            if (!m_configStore) return;
            QMap<QString, QVariantMap> byProcessName;
            for (const QVariant &entry : m_installedApps) {
                const QVariantMap map = entry.toMap();
                byProcessName.insert(map.value(QStringLiteral("processName")).toString(), map);
            }
            // Also include runningApps if available for fallback? Use installed only for now,
            // but keep previous fallback logic: if process not in installed, keep generic
            m_appsToClose.clear();
            for (const QString &processName : m_configStore->appsToClose()) {
                if (processName.isEmpty()) continue;
                if (byProcessName.contains(processName)) {
                    m_appsToClose.append(byProcessName.value(processName));
                    continue;
                }
                QVariantMap fallback;
                fallback.insert(QStringLiteral("processName"), processName);
                fallback.insert(QStringLiteral("displayName"), processName);
                fallback.insert(QStringLiteral("icon"), QStringLiteral("application-x-executable"));
                m_appsToClose.append(fallback);
            }
            emit appsToCloseChanged();
        });
    }
    // Trigger immediate resolution if cache already built
    if (m_desktopCacheBuilt) {
        // will be handled via installedAppsChanged after request, but also ensure appsToClose is set synchronously if possible
        // Defer to async path
    }
}

QVariantList AppCleanupModel::installedApplications()
{
    // Fast synchronous version using native cache (no QProcess)
    return buildInstalledList();
}

QVariantList AppCleanupModel::runningApplications()
{
    return buildRunningList();
}

void AppCleanupModel::requestInstalledApplications()
{
    if (m_loadingInstalled) return;
    {
        QMutexLocker locker(&m_cacheMutex);
        if (m_desktopCacheBuilt && !m_installedApps.isEmpty()) {
            // already cached, emit immediately via queued connection to keep async semantics
            QMetaObject::invokeMethod(this, [this]() {
                emit installedAppsChanged();
            }, Qt::QueuedConnection);
            return;
        }
    }
    m_loadingInstalled = true;
    emit loadingInstalledChanged();

    QThread *thread = QThread::create([this]() {
        QVariantList result = this->buildInstalledList();
        QMetaObject::invokeMethod(this, [this, result]() {
            m_installedApps = result;
            m_loadingInstalled = false;
            emit installedAppsChanged();
            emit loadingInstalledChanged();
        }, Qt::QueuedConnection);
    });
    connect(thread, &QThread::finished, thread, &QThread::deleteLater);
    thread->start();
}

void AppCleanupModel::requestRunningApplications()
{
    if (m_loadingRunning) return;
    m_loadingRunning = true;
    emit loadingRunningChanged();

    QThread *thread = QThread::create([this]() {
        QVariantList result = this->buildRunningList();
        QMetaObject::invokeMethod(this, [this, result]() {
            m_runningApps = result;
            m_loadingRunning = false;
            emit runningAppsChanged();
            emit loadingRunningChanged();
        }, Qt::QueuedConnection);
    });
    connect(thread, &QThread::finished, thread, &QThread::deleteLater);
    thread->start();
}

void AppCleanupModel::addApp(const QString &processName, const QString &displayName, const QString &icon)
{
    if (processName.isEmpty()) {
        return;
    }
    for (const QVariant &entry : std::as_const(m_appsToClose)) {
        if (entry.toMap().value(QStringLiteral("processName")).toString() == processName) {
            return;
        }
    }

    QVariantMap entry;
    entry.insert(QStringLiteral("processName"), processName);
    entry.insert(QStringLiteral("displayName"), displayName.isEmpty() ? processName : displayName);
    entry.insert(QStringLiteral("icon"), icon);
    m_appsToClose.append(entry);
    emit appsToCloseChanged();
}

void AppCleanupModel::removeApp(int index)
{
    if (index < 0 || index >= m_appsToClose.size()) {
        return;
    }
    m_appsToClose.removeAt(index);
    emit appsToCloseChanged();
}

bool AppCleanupModel::save()
{
    if (!m_configStore) {
        return false;
    }

    QStringList processNames;
    for (const QVariant &entry : std::as_const(m_appsToClose)) {
        processNames << entry.toMap().value(QStringLiteral("processName")).toString();
    }

    bool ok = m_configStore->setCloseAppsEnabled(m_enabled);
    ok = m_configStore->setCloseAppsWaitSeconds(m_waitSeconds) && ok;
    ok = m_configStore->setAppsToClose(processNames) && ok;
    return ok;
}

void AppCleanupModel::setEnabled(bool enabled)
{
    if (m_enabled == enabled) {
        return;
    }
    m_enabled = enabled;
    emit enabledChanged();
}

void AppCleanupModel::setWaitSeconds(int seconds)
{
    if (seconds < 0) {
        seconds = 0;
    }
    if (seconds > 60) {
        seconds = 60;
    }
    if (m_waitSeconds == seconds) {
        return;
    }
    m_waitSeconds = seconds;
    emit waitSecondsChanged();
}
