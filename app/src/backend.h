#pragma once

#include <QObject>
#include <QProcess>
#include <QString>
#include <QVariantList>
#include <QVariantMap>

class ConfigStore;
class EngineClient;

class Backend : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool running READ isRunning NOTIFY runningChanged)

public:
    explicit Backend(QObject *parent = nullptr);

    bool isRunning() const { return m_running; }

    Q_INVOKABLE QVariantList listOutputs();
    Q_INVOKABLE QVariantMap loadConfig();
    Q_INVOKABLE bool saveConfig(const QVariantMap &config);
    Q_INVOKABLE QString validateDisplaySettings(const QVariantMap &config) const;
    Q_INVOKABLE bool autostartEnabled();
    Q_INVOKABLE bool setAutostart(bool enabled);
    Q_INVOKABLE bool backgroundOnClose() const;
    Q_INVOKABLE bool setBackgroundOnClose(bool enabled);
    Q_INVOKABLE void attachWindow(QObject *window);
    Q_INVOKABLE void showWindow();
    Q_INVOKABLE void showTray();

    Q_INVOKABLE void play();
    Q_INVOKABLE void restore();
    Q_INVOKABLE void refreshStatus();
    Q_INVOKABLE bool watcherEnabled();
    Q_INVOKABLE void startWatcher();

    Q_INVOKABLE bool engineAvailable();
    Q_INVOKABLE bool engineNeedsUpdate();
    Q_INVOKABLE bool canAutoInstallEngine();
    Q_INVOKABLE QString tryAutoInstallEngine();
    Q_INVOKABLE QString ensureEngine();

    Q_INVOKABLE void copyLogToClipboard();
    Q_INVOKABLE QString exportLogToHome();
    Q_INVOKABLE void clearLog();
    Q_INVOKABLE QString readLog();
    Q_INVOKABLE QVariantList logHistory();
    Q_INVOKABLE bool copyHistoryLogToClipboard(const QString &id);
    Q_INVOKABLE QString exportHistoryLog(const QString &id);

    Q_INVOKABLE bool onboardingSeen();
    Q_INVOKABLE void setOnboardingSeen(bool seen);
    Q_INVOKABLE QString readHistoryLog(const QString &id);

signals:
    void logLine(const QString &line);
    void actionFinished(bool success, const QString &message);
    void statusUpdated(const QString &statusText);
    void runningChanged();

private:
    bool validateSettings(const QVariantMap &config, QString *error = nullptr) const;
    QString engineCommand() const;
    QString runEngineSync(const QStringList &args, bool *ok = nullptr);
    void runEngineAsync(const QStringList &args);
    QString configFilePath() const;

    bool m_running = false;
    QProcess *m_asyncProcess = nullptr;
    QProcess *m_watcherProcess = nullptr;
    class QSystemTrayIcon *m_trayIcon = nullptr;
    class QWindow *m_window = nullptr;

    ConfigStore *m_configStore = nullptr;
    EngineClient *m_engineClient = nullptr;
};
