#include "backend.h"

#include "applicationicon.h"
#include "configstore.h"
#include "engineclient.h"

#include <QApplication>
#include <QClipboard>
#include <QCoreApplication>
#include <QDateTime>
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
#include <QStandardPaths>
#include <QSystemTrayIcon>
#include <QTextStream>
#include <QTimer>
#include <QWindow>

namespace {
// The engine's own name for the announcement it leaves in $XDG_RUNTIME_DIR.
// It has to match pendingFile in engine/internal/console/pending.go.
const QLatin1String kPendingEntryFile("open-couch-entry-pending");

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
    watchPendingEntry();
}

// The wrapper leaves an announcement in the runtime directory when something
// other than this window asks for the console -- a controller being switched
// on. Watching the directory as well as the file is the point: the file appears
// and disappears, and a watch on a path that does not exist yet watches nothing.
void Backend::watchPendingEntry()
{
    m_runtimeDir = qEnvironmentVariable("XDG_RUNTIME_DIR");
    if (m_runtimeDir.isEmpty()) {
        return;
    }

    const QString path = m_runtimeDir + QStringLiteral("/") + kPendingEntryFile;
    const auto reread = [this, path]() {
        if (QFileInfo::exists(path) && !m_runtimeWatcher.files().contains(path)) {
            m_runtimeWatcher.addPath(path);
        }
        emit pendingEntryChanged();
    };
    connect(&m_runtimeWatcher, &QFileSystemWatcher::directoryChanged, this, reread);
    connect(&m_runtimeWatcher, &QFileSystemWatcher::fileChanged, this, reread);

    m_runtimeWatcher.addPath(m_runtimeDir);
    if (QFileInfo::exists(path)) {
        m_runtimeWatcher.addPath(path);
    }
}

QVariantMap Backend::pendingEntry()
{
    if (m_runtimeDir.isEmpty()) {
        return {};
    }
    QFile file(m_runtimeDir + QStringLiteral("/") + kPendingEntryFile);
    if (!file.open(QIODevice::ReadOnly)) {
        return {};
    }

    const QJsonObject entry = QJsonDocument::fromJson(file.readAll()).object();
    const QDateTime deadline =
        QDateTime::fromString(entry.value(QStringLiteral("deadline")).toString(), Qt::ISODate);
    if (!deadline.isValid()) {
        return {};
    }
    // Seconds left, not the length of the countdown: the announcement may have
    // been written a moment or a minute ago, and a clock that starts over every
    // time the window looks at it is not a countdown.
    const qint64 remaining = QDateTime::currentDateTime().secsTo(deadline);
    if (remaining <= 0) {
        return {};
    }

    return QVariantMap{
        {QStringLiteral("seconds"), static_cast<int>(remaining)},
        {QStringLiteral("trigger"), entry.value(QStringLiteral("trigger")).toString()},
        {QStringLiteral("display"), entry.value(QStringLiteral("display")).toString()},
    };
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
    if (enabled) {
        showTray();
    } else if (m_trayIcon) {
        m_trayIcon->setVisible(false);
    }
    return true;
}

bool Backend::startMinimized() const
{
    return m_configStore->startMinimized();
}

bool Backend::setStartMinimized(bool enabled)
{
    return m_configStore->setStartMinimized(enabled);
}

void Backend::attachWindow(QObject *window)
{
    m_window = qobject_cast<QWindow *>(window);

    // The tray host -- a bar, a shell -- can still be starting while an
    // autostart brings the app up, so the icon is registered when it appears.
    if (backgroundOnClose() || startMinimized()) {
        showTray();
        QTimer::singleShot(2000, this, [this]() { showTray(); });
        QTimer::singleShot(5000, this, [this]() { showTray(); });
        QTimer::singleShot(10000, this, [this]() { showTray(); });
    }

    // Starting minimized hides even without a tray: launching the app again
    // wakes the window up, so there is always a way back.
    if (m_window && startMinimized()) {
        m_window->hide();
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
    // Built lazily: at login the tray host may not be up yet, and a
    // QSystemTrayIcon created then never registers itself later.
    if (!QSystemTrayIcon::isSystemTrayAvailable()) {
        return;
    }
    if (!m_trayIcon) {
        const QIcon icon = trayIcon();
        if (icon.isNull()) {
            return;
        }
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
    if (!m_trayIcon->isVisible()) {
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
    if (ok) {
        emit configChanged();
    }
    return ok ? output : QString();
}

bool Backend::setTv(const QString &connector)
{
    bool ok = false;
    runEngineSync({QStringLiteral("tv"), connector}, &ok);
    if (ok) {
        emit configChanged();
    }
    return ok;
}

bool Backend::setBootMode(const QString &mode)
{
    bool ok = false;
    runEngineSync({QStringLiteral("boot"), mode}, &ok);
    if (ok) {
        emit configChanged();
    }
    return ok;
}

// Written through the engine, like every other console setting. The app used to
// put this in a config.env of its own, which the engine that reads it has never
// looked at: the switch saved, and nothing on the machine was any different.
bool Backend::setEnterOnController(bool enabled)
{
    bool ok = false;
    runEngineSync({QStringLiteral("controller"),
                   enabled ? QStringLiteral("on") : QStringLiteral("off")}, &ok);
    if (ok) {
        emit configChanged();
    }
    return ok;
}

void Backend::copyLogToClipboard()
{
    QGuiApplication::clipboard()->setText(readLog());
}

QString Backend::exportLogToHome()
{
    return exportText(readLog(), QStringLiteral("current"));
}

void Backend::clearLog()
{
    runEngineSync({QStringLiteral("log"), QStringLiteral("--clear")});
}

QVariantList Backend::logHistory()
{
    bool ok = false;
    const QString output = runEngineSync({QStringLiteral("log"), QStringLiteral("--list")}, &ok);
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
    const QString text = readHistoryLog(id);
    if (text.isEmpty()) {
        return false;
    }
    QGuiApplication::clipboard()->setText(text);
    return true;
}

QString Backend::exportHistoryLog(const QString &id)
{
    return exportText(readHistoryLog(id), id);
}

// Writing the file is the application's, not the engine's: by this point the
// text is already here, and asking a command-line tool where a desktop wants to
// put a file is a question it has no way to answer.
QString Backend::exportText(const QString &text, const QString &suffix) const
{
    if (text.isEmpty()) {
        return QString();
    }
    QString directory = QStandardPaths::writableLocation(QStandardPaths::DownloadLocation);
    if (directory.isEmpty()) {
        directory = QDir::homePath();
    }
    const QString path = directory + QStringLiteral("/open-couch-log-") + suffix
        + QStringLiteral(".txt");

    QFile file(path);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Text | QIODevice::Truncate)) {
        return QString();
    }
    QTextStream(&file) << text;
    return file.error() == QFile::NoError ? path : QString();
}

bool Backend::onboardingSeen()
{
    return m_configStore->onboardingSeen();
}

void Backend::setOnboardingSeen(bool seen)
{
    m_configStore->setOnboardingSeen(seen);
}

QString Backend::readHistoryLog(const QString &id)
{
    bool ok = false;
    const QString output =
        runEngineSync({QStringLiteral("log"), QStringLiteral("--session"), id}, &ok);
    return ok ? output : QString();
}

QString Backend::readLog()
{
    bool ok = false;
    const QString output = runEngineSync({QStringLiteral("log")}, &ok);
    return ok ? output : QString();
}