#pragma once

#include <QFileSystemWatcher>
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

    Q_INVOKABLE bool autostartEnabled();
    Q_INVOKABLE bool setAutostart(bool enabled);
    Q_INVOKABLE bool backgroundOnClose() const;
    Q_INVOKABLE bool setBackgroundOnClose(bool enabled);
    Q_INVOKABLE void attachWindow(QObject *window);
    Q_INVOKABLE void showWindow();
    Q_INVOKABLE void showTray();

    // Console mode. Every display decision belongs to the engine and to
    // gamescope; what is left for the app is choosing the television, asking to
    // switch, and saying why it cannot.
    Q_INVOKABLE QVariantMap consoleStatus();
    Q_INVOKABLE QVariantList listDisplays();
    Q_INVOKABLE void enterConsole();
    Q_INVOKABLE bool cancelEntry();
    Q_INVOKABLE QString runSetup();
    Q_INVOKABLE bool setTv(const QString &connector);
    Q_INVOKABLE bool setBootMode(const QString &mode);
    Q_INVOKABLE bool setEnterOnController(bool enabled);

    // An entry the user did not ask for, announced by the wrapper. The
    // notification is the warning for a machine nobody is sitting at; this is
    // what lets the window show the same clock and offer the same way out.
    // Empty when nothing is pending.
    Q_INVOKABLE QVariantMap pendingEntry();

    Q_INVOKABLE bool engineAvailable();
    Q_INVOKABLE bool engineNeedsUpdate();

    Q_INVOKABLE void copyLogToClipboard();
    Q_INVOKABLE QString exportLogToHome();
    Q_INVOKABLE void clearLog();
    Q_INVOKABLE QString readLog();
    Q_INVOKABLE QVariantList logHistory();
    Q_INVOKABLE bool copyHistoryLogToClipboard(const QString &id);
    Q_INVOKABLE QString exportHistoryLog(const QString &id);
    Q_INVOKABLE QString readHistoryLog(const QString &id);

    Q_INVOKABLE bool onboardingSeen();
    Q_INVOKABLE void setOnboardingSeen(bool seen);

signals:
    void logLine(const QString &line);
    void actionFinished(bool success, const QString &message);
    void runningChanged();
    // Every setting is one engine call applied when it is chosen, and the
    // dashboard is a page that survives the settings page being pushed over it.
    // Without this it goes on showing what was true when it was built.
    void configChanged();
    void pendingEntryChanged();

private:
    QString engineCommand() const;
    QString runEngineSync(const QStringList &args, bool *ok = nullptr);
    void runEngineAsync(const QStringList &args);
    QString exportText(const QString &text, const QString &suffix) const;
    void watchPendingEntry();

    bool m_running = false;
    QProcess *m_asyncProcess = nullptr;
    class QSystemTrayIcon *m_trayIcon = nullptr;
    class QWindow *m_window = nullptr;

    QFileSystemWatcher m_runtimeWatcher;
    QString m_runtimeDir;

    ConfigStore *m_configStore = nullptr;
    EngineClient *m_engineClient = nullptr;
};
