#include "backend.h"

#include "configstore.h"
#include "displaysettingsvalidator.h"
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
    const QStringList themeCandidates = {
        QStringLiteral("io.github.gustavobelo.opencouch"),
        QStringLiteral("applications-graphics"),
        QStringLiteral("preferences-desktop-display"),
        QStringLiteral("preferences-system-windows")
    };

    for (const QString &name : themeCandidates) {
        const QIcon icon = QIcon::fromTheme(name);
        if (!icon.isNull()) {
            return icon;
        }
    }

    const QStringList iconPaths = {
        QCoreApplication::applicationDirPath() + QStringLiteral("/../share/icons/hicolor/scalable/apps/io.github.gustavobelo.opencouch.svg"),
        QStringLiteral("/app/share/icons/hicolor/scalable/apps/io.github.gustavobelo.opencouch.svg"),
        QStringLiteral("/usr/share/icons/hicolor/scalable/apps/io.github.gustavobelo.opencouch.svg")
    };

    for (const QString &path : iconPaths) {
        if (QFileInfo(path).exists()) {
            return QIcon(path);
        }
    }

    return QIcon();
}

QString formatOutputLine(const QJsonObject &out)
{
    const QString roleLabel = out.value(QStringLiteral("role")).toString() == QLatin1String("desk")
        ? qtTrId("status.desktop")
        : qtTrId("status.couch");
    const QString name = out.value(QStringLiteral("name")).toString();
    const bool connected = out.value(QStringLiteral("connected")).toBool();
    const bool enabled = out.value(QStringLiteral("enabled")).toBool();
    const QString mode = out.value(QStringLiteral("mode")).toString();
    const double scale = out.value(QStringLiteral("scale")).toDouble(1.0);

    QString state;
    if (!connected) {
        state = qtTrId("status.disconnected");
    } else if (!enabled) {
        state = qtTrId("status.disabled");
    } else {
        state = qtTrId("status.enabled");
        if (!mode.isEmpty()) {
            state += QStringLiteral(", %1").arg(mode);
        }
        if (scale != 1.0) {
            state += qtTrId("status.scale").arg(scale);
        }
    }

    return qtTrId("status.format").arg(roleLabel, name, state);
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

bool Backend::watcherEnabled()
{
    return loadConfig().value(QStringLiteral("WATCH_BIG_PICTURE")).toString() == QLatin1String("true");
}

void Backend::startWatcher()
{
    if (m_watcherProcess && m_watcherProcess->state() != QProcess::NotRunning) {
        return;
    }

    m_watcherProcess = new QProcess(this);
    m_watcherProcess->setProcessChannelMode(QProcess::MergedChannels);
    connect(m_watcherProcess, &QProcess::readyReadStandardOutput, this, [this]() {
        const QByteArray chunk = m_watcherProcess->readAllStandardOutput();
        for (const QByteArray &line : chunk.split('\n')) {
            if (!line.isEmpty()) {
                emit logLine(QString::fromUtf8(line));
            }
        }
    });
    connect(m_watcherProcess, qOverload<int, QProcess::ExitStatus>(&QProcess::finished),
            this, [this](int exitCode, QProcess::ExitStatus status) {
        if (status == QProcess::NormalExit && exitCode != 0) {
            emit logLine(qtTrId("watcher.failed").arg(exitCode));
        }
    });

    const QStringList command = m_engineClient->commandLine({QStringLiteral("watch")});
    m_watcherProcess->start(command.first(), command.mid(1));
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

QVariantList Backend::listOutputs()
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

bool Backend::validateSettings(const QVariantMap &config, QString *error) const
{
    return DisplaySettingsValidator::validate(config, error);
}

QString Backend::validateDisplaySettings(const QVariantMap &config) const
{
    QString error;
    return validateSettings(config, &error) ? QString() : error;
}

bool Backend::saveConfig(const QVariantMap &config)
{
    QString error;
    if (!validateSettings(config, &error)) {
        return false;
    }
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

void Backend::play()
{
    emit logLine(qtTrId("engine.start_couch"));
    runEngineAsync({QStringLiteral("play")});
}

void Backend::restore()
{
    emit logLine(qtTrId("engine.restore_desktop"));
    runEngineAsync({QStringLiteral("restore")});
}

void Backend::refreshStatus()
{
    bool ok = false;
    const QString output = runEngineSync({QStringLiteral("status")}, &ok);
    if (!ok) {
        emit statusUpdated(qtTrId("status.unavailable"));
        return;
    }

    const QJsonDocument doc = QJsonDocument::fromJson(output.toUtf8());
    if (!doc.isArray()) {
        emit statusUpdated(output);
        return;
    }

    QStringList lines;
    for (const QJsonValue &value : doc.array()) {
        if (value.isObject()) {
            lines << formatOutputLine(value.toObject());
        }
    }
    emit statusUpdated(lines.join(QStringLiteral("\n")));
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
QString Backend::readLog()
{
    bool ok = false;
    const QString output = runEngineSync({QStringLiteral("log")}, &ok);
    
    if (!ok) {
        return QString();
    }
    
    return output;
}