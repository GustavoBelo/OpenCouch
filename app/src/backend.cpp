#include "backend.h"

#include "applicationicon.h"
#include "configstore.h"
#include "engineclient.h"

#include <QApplication>
#include <QClipboard>
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMenu>
#include <QProcess>
#include <QSettings>
#include <QSystemTrayIcon>
#include <QTextStream>
#include <QWindow>

namespace {
QIcon trayIcon()
{
    return applicationIcon();
}

}

Backend::Backend(QObject *parent)
    : QObject(parent),
      m_configStore(new ConfigStore(this)),
      m_engineClient(new EngineClient(this))
{
    const QIcon icon = trayIcon();
    if (!icon.isNull() && QSystemTrayIcon::isSystemTrayAvailable()) {
        m_trayIcon = new QSystemTrayIcon(icon, this);
        m_trayIcon->setToolTip(qtTrId("tray.tooltip"));

        auto *menu = new QMenu;
        QAction *openAction = menu->addAction(qtTrId("tray.open"));
        QAction *quitAction = menu->addAction(qtTrId("tray.quit"));
        connect(openAction, &QAction::triggered, this, &Backend::showWindow);
        connect(quitAction, &QAction::triggered, qApp, &QCoreApplication::quit);
        connect(m_trayIcon, &QSystemTrayIcon::activated, this,
                [this](QSystemTrayIcon::ActivationReason reason) {
                    if (reason == QSystemTrayIcon::Trigger) {
                        showWindow();
                    }
                });
        m_trayIcon->setContextMenu(menu);
    }
}

QString Backend::configFilePath() const
{
    return ConfigStore::configFilePath();
}

QString Backend::engineCommand() const
{
    return m_engineClient->engineName();
}

QString Backend::runEngineSync(const QStringList &args, bool *ok)
{
    return m_engineClient->runSync(args, ok);
}

void Backend::runEngineAsync(const QStringList &args)
{
    if (m_asyncProcess) {
        m_asyncProcess->deleteLater();
    }

    m_asyncProcess = new QProcess(this);
    m_asyncProcess->setProcessChannelMode(QProcess::MergedChannels);

    connect(m_asyncProcess, &QProcess::readyReadStandardOutput, this, [this]() {
        const QByteArray chunk = m_asyncProcess->readAllStandardOutput();
        for (const QByteArray &line : chunk.split('\n')) {
            if (!line.isEmpty()) {
                emit logLine(QString::fromUtf8(line));
            }
        }
    });

    connect(m_asyncProcess, qOverload<int, QProcess::ExitStatus>(&QProcess::finished), this,
            [this, process = m_asyncProcess](int exitCode, QProcess::ExitStatus status) {
                if (process != m_asyncProcess) {
                    return;
                }
                m_running = false;
                emit runningChanged();
                const bool success = status == QProcess::NormalExit && exitCode == 0;
                emit actionFinished(success,
                                     success ? qtTrId("engine.completed")
                                             : qtTrId("engine.failed").arg(exitCode));
            });

    const QStringList command = m_engineClient->commandLine(args);
    m_running = true;
    emit runningChanged();
    m_asyncProcess->start(command.first(), command.mid(1));
}

bool Backend::engineAvailable()
{
    return m_engineClient->engineAvailable();
}

bool Backend::engineNeedsUpdate()
{
    return m_engineClient->engineNeedsUpdate();
}

bool Backend::canAutoInstallEngine()
{
    return EngineClient::canAutoInstall();
}

QString Backend::tryAutoInstallEngine()
{
    QString error;
    if (!m_engineClient->installBundledEngine(&error)) {
        return error.isEmpty() ? QString("Unknown error") : error;
    }
    return QString();
}

QString Backend::ensureEngine()
{
    if (m_engineClient->engineAvailable() && !m_engineClient->engineNeedsUpdate()) {
        return QString();
    }

    if (!EngineClient::canAutoInstall()) {
        return QStringLiteral("No bundled engine is available");
    }

    const QString error = tryAutoInstallEngine();
    if (!error.isEmpty()) {
        return error;
    }

    if (!m_engineClient->engineAvailable() || m_engineClient->engineNeedsUpdate()) {
        return QStringLiteral("The bundled engine is unavailable or outdated");
    }

    return QString();
}

QVariantList Backend::listDisplays()
{
    bool ok = false;
    const QString output = runEngineSync({QStringLiteral("outputs")}, &ok);
    QVariantList result;
    if (!ok) {
        return result;
    }

    const QJsonDocument doc = QJsonDocument::fromJson(output.toUtf8());
    if (!doc.isArray()) {
        return result;
    }

    for (const QJsonValue &value : doc.array()) {
        result.append(value.toObject().toVariantMap());
    }
    return result;
}

QVariantMap Backend::loadConfig()
{
    return m_configStore->loadConfig();
}

bool Backend::saveConfig(const QVariantMap &config)
{
    return m_configStore->saveConfig(config);
}

bool Backend::autostartEnabled()
{
    return m_configStore->autostartEnabled();
}

bool Backend::setAutostart(bool enabled)
{
    return m_configStore->setAutostart(enabled);
}

bool Backend::backgroundOnClose() const
{
    return m_configStore->backgroundOnClose();
}

bool Backend::setBackgroundOnClose(bool enabled)
{
    if (m_configStore) {
        m_configStore->setBackgroundOnClose(enabled);
    }
    if (m_trayIcon && !m_trayIcon->icon().isNull() && QSystemTrayIcon::isSystemTrayAvailable()) {
        m_trayIcon->setVisible(enabled);
    }
    return true;
}

void Backend::attachWindow(QObject *window)
{
    m_window = qobject_cast<QWindow *>(window);
    if (m_window && backgroundOnClose() && m_trayIcon && !m_trayIcon->icon().isNull()
        && QSystemTrayIcon::isSystemTrayAvailable()) {
        m_trayIcon->show();
    }
}

void Backend::showWindow()
{
    if (!m_window) {
        return;
    }
    m_window->show();
    m_window->raise();
    m_window->requestActivate();
}

void Backend::showTray()
{
    if (m_trayIcon && !m_trayIcon->icon().isNull() && QSystemTrayIcon::isSystemTrayAvailable()) {
        m_trayIcon->show();
    }
}

QVariantMap Backend::consoleStatus()
{
    bool ok = false;
    const QString output = runEngineSync({QStringLiteral("status")}, &ok);
    if (!ok) {
        return {};
    }
    const QJsonDocument doc = QJsonDocument::fromJson(output.toUtf8());
    if (!doc.isObject()) {
        return {};
    }
    return doc.object().toVariantMap();
}

// There is deliberately no leaveConsole() here. Entering ends this session, so
// while the console runs there is no window to press a button in; the way home
// is Steam's own "Switch to Desktop", or `open-couch-engine leave` over ssh.
void Backend::enterConsole()
{
    // --yes because the countdown belongs to the window the user is looking at.
    // The engine has one of its own for the launcher entry and the command
    // line, which have nowhere to draw a button; here there is somewhere
    // better, and two countdowns would race each other.
    emit logLine(qtTrId("engine.enter_console"));
    runEngineAsync({QStringLiteral("enter"), QStringLiteral("--yes")});
}

bool Backend::cancelEntry()
{
    bool ok = false;
    runEngineSync({QStringLiteral("cancel")}, &ok);
    return ok;
}

QString Backend::runSetup()
{
    bool ok = false;
    const QString output = runEngineSync({QStringLiteral("setup")}, &ok);
    return ok ? output : QString();
}

bool Backend::setTv(const QString &connector)
{
    bool ok = false;
    runEngineSync({QStringLiteral("tv"), connector}, &ok);
    return ok;
}

bool Backend::setBootMode(const QString &mode)
{
    bool ok = false;
    runEngineSync({QStringLiteral("boot"), mode}, &ok);
    return ok;
}

void Backend::closeTrackedApps(const QStringList &processNames)
{
    if (processNames.isEmpty()) {
        return;
    }
    // Synchronous on purpose: this runs on the way into console mode, and the
    // point is that the applications have been asked to quit before the session
    // they are running in ends.
    bool ok = false;
    const QString output = runEngineSync(QStringList{QStringLiteral("close-apps")} + processNames, &ok);
    for (const QString &line : output.split(QLatin1Char('\n'), Qt::SkipEmptyParts)) {
        emit logLine(line);
    }
}

void Backend::copyLogToClipboard()
{
    bool ok = false;
    const QString output = runEngineSync({QStringLiteral("log")}, &ok);
    if (ok) {
        QGuiApplication::clipboard()->setText(output);
    }
}

QString Backend::exportLogToHome()
{
    bool ok = false;
    const QString output = runEngineSync({QStringLiteral("export-log")}, &ok);
    if (!ok) {
        return QString();
    }
    return output.trimmed();
}

void Backend::clearLog()
{
    runEngineSync({QStringLiteral("clear-log")});
}

QVariantList Backend::logHistory()
{
    bool ok = false;
    const QString output = runEngineSync({QStringLiteral("log-history")}, &ok);
    QVariantList result;
    if (!ok) {
        return result;
    }

    const QJsonDocument doc = QJsonDocument::fromJson(output.toUtf8());
    if (!doc.isArray()) {
        return result;
    }

    for (const QJsonValue &value : doc.array()) {
        result.append(value.toObject().toVariantMap());
    }
    return result;
}

bool Backend::copyHistoryLogToClipboard(const QString &id)
{
    bool ok = false;
    const QString output = runEngineSync({QStringLiteral("print-history-log"), id}, &ok);
    if (!ok) {
        return false;
    }
    QGuiApplication::clipboard()->setText(output);
    return true;
}

QString Backend::exportHistoryLog(const QString &id)
{
    bool ok = false;
    const QString output = runEngineSync({QStringLiteral("export-history-log"), id}, &ok);
    if (!ok) {
        return QString();
    }
    return output.trimmed();
}

bool Backend::onboardingSeen()
{
    return m_configStore->onboardingSeen();
}

void Backend::setOnboardingSeen(bool seen)
{
    m_configStore->setOnboardingSeen(seen);
}

QString Backend::readHistoryLog(const QString &id) {
    bool ok = false;
    const QString output = runEngineSync({QStringLiteral("print-history-log"), id}, &ok);
    
    if (!ok) {
        return QString();
    }
    
    return output;
}

QString Backend::runSync(const QStringList &args)
{
    bool ok = false;
    const QString output = runEngineSync(args, &ok);
    if (!ok) {
        return QString();
    }
    return output;
}

QString Backend::readLog()
{
    bool ok = false;
    const QString output = runEngineSync({QStringLiteral("log")}, &ok);
    
    if (!ok) {
        return QString();
    }
    
    return output;
}