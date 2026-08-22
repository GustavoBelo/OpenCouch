#pragma once

#include <QObject>
#include <QVariantList>
#include <QMap>
#include <QMutex>
#include "backend.h"

class ConfigStore;

class AppCleanupModel : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool enabled READ enabled WRITE setEnabled NOTIFY enabledChanged)
    Q_PROPERTY(int waitSeconds READ waitSeconds WRITE setWaitSeconds NOTIFY waitSecondsChanged)
    Q_PROPERTY(QVariantList appsToClose READ appsToClose NOTIFY appsToCloseChanged)
    Q_PROPERTY(QVariantList installedApps READ installedApps NOTIFY installedAppsChanged)
    Q_PROPERTY(QVariantList runningApps READ runningApps NOTIFY runningAppsChanged)
    Q_PROPERTY(bool loadingInstalled READ loadingInstalled NOTIFY loadingInstalledChanged)
    Q_PROPERTY(bool loadingRunning READ loadingRunning NOTIFY loadingRunningChanged)

public:
    explicit AppCleanupModel(QObject *parent = nullptr);

    Q_INVOKABLE void bindBackend(Backend *backend);
    Q_INVOKABLE bool save();

    Q_INVOKABLE void addApp(const QString &processName, const QString &displayName, const QString &icon);
    Q_INVOKABLE void removeApp(int index);

    // Synchronous (fast, native) – kept for compatibility, now uses native QDir/QFile
    Q_INVOKABLE QVariantList installedApplications();
    Q_INVOKABLE QVariantList runningApplications();

    // Async with in-memory cache – recommended for UI
    Q_INVOKABLE void requestInstalledApplications();
    Q_INVOKABLE void requestRunningApplications();

    bool enabled() const { return m_enabled; }
    void setEnabled(bool enabled);

    int waitSeconds() const { return m_waitSeconds; }
    void setWaitSeconds(int seconds);

    QVariantList appsToClose() const { return m_appsToClose; }
    QVariantList installedApps() const { return m_installedApps; }
    QVariantList runningApps() const { return m_runningApps; }
    bool loadingInstalled() const { return m_loadingInstalled; }
    bool loadingRunning() const { return m_loadingRunning; }

signals:
    void enabledChanged();
    void waitSecondsChanged();
    void appsToCloseChanged();
    void installedAppsChanged();
    void runningAppsChanged();
    void loadingInstalledChanged();
    void loadingRunningChanged();

private:
    // native helpers
    static bool isProtectedProcess(const QString &name);
    static QStringList extractProcessNames(const QString &execLine);
    static QStringList desktopSearchDirs();
    static QStringList enumerateDesktopFiles(const QString &baseDir);
    QMap<QString, QVariantMap> buildDesktopMap();
    QVariantList buildInstalledList();
    QVariantList buildRunningList();

    void ensureDesktopCacheAsync(std::function<void(QMap<QString, QVariantMap>)> callback);

    Backend *m_backend = nullptr;
    ConfigStore *m_configStore = nullptr;

    bool m_enabled = false;
    int m_waitSeconds = 5;
    QVariantList m_appsToClose;

    // cache em memória por sessão
    QMap<QString, QVariantMap> m_desktopMap;
    bool m_desktopCacheBuilt = false;
    QMutex m_cacheMutex;

    QVariantList m_installedApps;
    QVariantList m_runningApps;
    bool m_loadingInstalled = false;
    bool m_loadingRunning = false;
};
