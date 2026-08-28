#include <QApplication>
#include <QDBusInterface>
#include <QDBusMessage>
#include <QDBusVariant>
#include <QDir>
#include <QFileInfo>
#include <QLibraryInfo>
#include <QIcon>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QStyleHints>
#include <QTranslator>
#include <QLocale>
#include <QLocalServer>
#include <QLocalSocket>
#include <QFile>
#include <QTextStream>
#include <QThread>

#include <csignal>
#include <cstdio>

#include "appcleanupmodel.h"
#include "appinfomodel.h"
#include "appversion.h"
#include "applicationicon.h"
#include "backend.h"
#include "displaysettingsmodel.h"

namespace {

// Kirigami picks its platform-theme plugin by the *QtQuick Controls style name*
// (it loads plugins/kf6/kirigami/platform/<style>.so). Only org.kde.desktop
// exists, so with any other style Kirigami falls back to a hardcoded light
// palette that ignores the system entirely.
//
// Plasma exports QT_QUICK_CONTROLS_STYLE into the session, which is why this
// only ever worked on KDE. Everywhere else we have to select the style here,
// before the QML engine is created.
void configureQuickStyle()
{
    if (!qEnvironmentVariableIsEmpty("QT_QUICK_CONTROLS_STYLE")) {
        return; // the session (or the AppImage AppRun) already decided
    }

    QStringList importPaths;
    const QString appDir = QString::fromLocal8Bit(qgetenv("APPDIR"));
    if (!appDir.isEmpty()) {
        importPaths << appDir + QStringLiteral("/usr/qml");
    }
    for (const char *var : {"QML2_IMPORT_PATH", "QML_IMPORT_PATH"}) {
        const QString value = QString::fromLocal8Bit(qgetenv(var));
        if (!value.isEmpty()) {
            importPaths << value.split(QLatin1Char(':'), Qt::SkipEmptyParts);
        }
    }
    importPaths << QLibraryInfo::path(QLibraryInfo::QmlImportsPath);

    for (const QString &importPath : std::as_const(importPaths)) {
        if (QFileInfo::exists(importPath + QStringLiteral("/org/kde/desktop/qmldir"))) {
            QQuickStyle::setStyle(QStringLiteral("org.kde.desktop"));
            return;
        }
    }

    // Basic ignores the palette outright; Fusion at least follows it.
    QQuickStyle::setStyle(QStringLiteral("Fusion"));
}

bool systemPrefersDark(QApplication &app)
{
    QDBusInterface settings(QStringLiteral("org.freedesktop.portal.Desktop"),
                            QStringLiteral("/org/freedesktop/portal/desktop"),
                            QStringLiteral("org.freedesktop.portal.Settings"));
    const QDBusMessage reply = settings.call(QStringLiteral("Read"),
                                             QStringLiteral("org.freedesktop.appearance"),
                                             QStringLiteral("color-scheme"));
    if (reply.type() == QDBusMessage::ReplyMessage && !reply.arguments().isEmpty()) {
        // Settings.Read wraps the value twice (a{sv} of a variant), so a single
        // unwrap leaves another QDBusVariant and toUInt() silently fails.
        QVariant value = reply.arguments().constFirst();
        while (value.metaType() == QMetaType::fromType<QDBusVariant>()) {
            value = value.value<QDBusVariant>().variant();
        }
        bool ok = false;
        const uint scheme = value.toUInt(&ok);
        if (ok && scheme != 0) {
            return scheme == 1;
        }
    }

    return app.styleHints()->colorScheme() == Qt::ColorScheme::Dark;
}

void configureIconTheme(bool dark)
{
    QStringList paths = QIcon::themeSearchPaths();
    const QString appDir = QString::fromLocal8Bit(qgetenv("APPDIR"));
    const QStringList extraPaths = {
        appDir.isEmpty() ? QString() : appDir + QStringLiteral("/usr/share/icons"),
        QStringLiteral("/app/share/icons"),
        QStringLiteral("/usr/local/share/icons"),
        QStringLiteral("/usr/share/icons")
    };
    for (const QString &path : extraPaths) {
        if (!path.isEmpty() && QDir(path).exists() && !paths.contains(path)) {
            paths.prepend(path);
        }
    }
    QIcon::setThemeSearchPaths(paths);
    QIcon::setFallbackThemeName(QStringLiteral("breeze"));

    // The UI uses Breeze icon names throughout. Testing themeName() for
    // emptiness is useless — outside Plasma it is set to whatever the platform
    // theme reports (hicolor, Adwaita, Yaru...), none of which carry names like
    // "overflow-menu" or "help-hint". Probe actual coverage instead.
    if (QIcon::hasThemeIcon(QStringLiteral("overflow-menu"))) {
        return;
    }

    const QStringList preferred = dark
        ? QStringList{QStringLiteral("breeze-dark"), QStringLiteral("breeze")}
        : QStringList{QStringLiteral("breeze"), QStringLiteral("breeze-dark")};
    for (const QString &theme : preferred) {
        for (const QString &path : paths) {
            if (QDir(path + QLatin1Char('/') + theme).exists()) {
                QIcon::setThemeName(theme);
                return;
            }
        }
    }
    qWarning("Breeze icons not found; UI icons will be missing. Install breeze-icons.");
}

// --- Single instance -------------------------------------------------------
//
// The socket lives in QDir::tempPath() (honours TMPDIR). Alongside it we keep a
// small info file naming the process that owns the socket, so a second launch
// can say *who* it is handing over to instead of exiting silently — a silent
// exit is indistinguishable from "my rebuild did not take effect", which is
// exactly how it was misdiagnosed twice.
//
// The info file is deliberately not part of the IPC protocol: reading it works
// even when the running instance is wedged and would not answer on the socket.

const char *const kInstanceName = "OpenCouchInstance";

QString instanceInfoPath()
{
    return QDir::tempPath() + QStringLiteral("/") + QLatin1String(kInstanceName)
        + QStringLiteral(".info");
}

struct InstanceInfo {
    qint64 pid = 0;
    QString executable;   // resolved binary; inside an AppImage this is the extracted copy
    QString appImage;     // $APPIMAGE, i.e. the path the user actually typed

    bool isValid() const { return pid > 0; }
    // What to show the user: the .AppImage path when there is one.
    QString displayPath() const { return appImage.isEmpty() ? executable : appImage; }
};

void writeInstanceInfo()
{
    QFile file(instanceInfoPath());
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text)) {
        return; // purely diagnostic; never block startup over it
    }
    QTextStream out(&file);
    out << QCoreApplication::applicationPid() << "\n"
        << QCoreApplication::applicationFilePath() << "\n"
        << QString::fromLocal8Bit(qgetenv("APPIMAGE")) << "\n";
}

void removeInstanceInfo()
{
    QFile::remove(instanceInfoPath());
}

// Returns the recorded instance only if that process is still alive, so a stale
// file left behind by a crash is treated as "no instance".
InstanceInfo readLiveInstanceInfo()
{
    InstanceInfo info;
    QFile file(instanceInfoPath());
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) {
        return info;
    }
    QTextStream in(&file);
    bool ok = false;
    const qint64 pid = in.readLine().toLongLong(&ok);
    if (!ok || pid <= 0 || ::kill(static_cast<pid_t>(pid), 0) != 0) {
        return info;
    }
    info.pid = pid;
    info.executable = in.readLine();
    info.appImage = in.readLine();
    return info;
}

bool waitForProcessExit(qint64 pid, int milliseconds)
{
    for (int waited = 0; waited < milliseconds; waited += 50) {
        if (::kill(static_cast<pid_t>(pid), 0) != 0) {
            return true;
        }
        QThread::msleep(50);
    }
    return ::kill(static_cast<pid_t>(pid), 0) != 0;
}

// Terminates the running instance so this build can take over. SIGTERM first,
// SIGKILL only if it refuses to go.
bool replaceRunningInstance(const InstanceInfo &info)
{
    if (!info.isValid()) {
        fprintf(stderr,
                "Open Couch: an instance is running but could not be identified "
                "(%s is missing or stale), so --replace cannot terminate it.\n"
                "Close it manually and try again.\n",
                qPrintable(instanceInfoPath()));
        return false;
    }

    fprintf(stderr, "Open Couch: replacing the running instance (pid %lld)...\n",
            static_cast<long long>(info.pid));

    ::kill(static_cast<pid_t>(info.pid), SIGTERM);
    if (!waitForProcessExit(info.pid, 3000)) {
        fprintf(stderr, "Open Couch: it did not exit on SIGTERM; sending SIGKILL.\n");
        ::kill(static_cast<pid_t>(info.pid), SIGKILL);
        if (!waitForProcessExit(info.pid, 2000)) {
            fprintf(stderr, "Open Couch: pid %lld is still alive; giving up.\n",
                    static_cast<long long>(info.pid));
            return false;
        }
    }

    removeInstanceInfo();
    fprintf(stderr, "Open Couch: previous instance stopped.\n");
    return true;
}

// Tells the running instance to show its window, and reports which one that is.
void reportHandoff(const InstanceInfo &info)
{
    if (info.isValid()) {
        fprintf(stderr,
                "Open Couch is already running (pid %lld, %s).\n"
                "Brought the existing window to the front.\n",
                static_cast<long long>(info.pid), qPrintable(info.displayPath()));
    } else {
        fprintf(stderr, "Open Couch is already running.\n"
                        "Brought the existing window to the front.\n");
    }
    fprintf(stderr, "To replace it with this build, run again with --replace.\n");
}

} // namespace

int main(int argc, char *argv[])
{
    // Parsed by hand: this runs before QApplication exists, so there is no
    // QCommandLineParser yet. QApplication ignores the unknown argument later.
    bool replaceRunning = false;
    for (int i = 1; i < argc; ++i) {
        if (qstrcmp(argv[i], "--replace") == 0) {
            replaceRunning = true;
        }
    }

    QLocalSocket socket;
    socket.connectToServer(QLatin1String(kInstanceName));
    if (socket.waitForConnected(500)) {
        const InstanceInfo running = readLiveInstanceInfo();
        if (!replaceRunning) {
            socket.write("WAKEUP");
            socket.flush();
            socket.waitForBytesWritten(500);
            socket.disconnectFromServer();
            reportHandoff(running);
            return 0;
        }
        socket.disconnectFromServer();
        if (!replaceRunningInstance(running)) {
            return 1;
        }
    }

    QApplication app(argc, argv);
    app.setQuitOnLastWindowClosed(false);
    app.setApplicationName(QStringLiteral("OpenCouch"));
    app.setApplicationVersion(QStringLiteral(OPENCOUCH_VERSION_STRING));
    app.setOrganizationName(QStringLiteral("io.github.gustavobelo"));

    // Must run before the QML engine is created: the style decides which
    // Kirigami platform theme is loaded, and therefore whether the UI follows
    // the system colors at all.
    configureQuickStyle();
    configureIconTheme(systemPrefersDark(app));
    app.setWindowIcon(applicationIcon());

    QTranslator enFallback;
    if (enFallback.load(QStringLiteral(":/i18n/opencouch_en.qm"))) {
        app.installTranslator(&enFallback);
    }

    QTranslator translator;
    const QLocale locale = QLocale::system();
    const QString catalogName = QStringLiteral("opencouch_") + locale.name() + QStringLiteral(".qm");
    if (translator.load(QStringLiteral(":/i18n/") + catalogName)
        || translator.load(locale, QStringLiteral("opencouch"), QStringLiteral("_"),
                           QStringLiteral(":/i18n"))
        || translator.load(locale, QStringLiteral("opencouch"), QStringLiteral("_"),
                           QStringLiteral(":/qt/qml/io/github/gustavobelo/opencouch/i18n"))) {
        app.installTranslator(&translator);
    }

    Backend backend;
    DisplaySettingsModel displaySettingsModel;
    AppCleanupModel appCleanupModel;
    AppInfoModel appInfoModel;

    QQmlApplicationEngine engine;

    engine.rootContext()->setContextProperty(QStringLiteral("backend"), &backend);
    engine.rootContext()->setContextProperty(QStringLiteral("displaySettingsModel"), &displaySettingsModel);
    engine.rootContext()->setContextProperty(QStringLiteral("appCleanupModel"), &appCleanupModel);
    engine.rootContext()->setContextProperty(QStringLiteral("appInfo"), &appInfoModel);

    QLocalServer server;
    server.removeServer(QLatin1String(kInstanceName));
    if (server.listen(QLatin1String(kInstanceName))) {
        writeInstanceInfo();
        QObject::connect(&app, &QCoreApplication::aboutToQuit, &app, removeInstanceInfo);
    } else {
        // Not fatal, but it means the single-instance guard is off: a second
        // launch will start a whole second app. Worth saying out loud — the
        // usual cause is a temp path too long for a unix socket (sun_path is
        // limited to ~107 bytes).
        fprintf(stderr,
                "Open Couch: could not listen on the single-instance socket in %s (%s).\n"
                "Multiple instances may run at the same time.\n",
                qPrintable(QDir::tempPath()), qPrintable(server.errorString()));
    }

    QObject::connect(&server, &QLocalServer::newConnection, [&backend, &server]() {
        QLocalSocket *client = server.nextPendingConnection();
        QObject::connect(client, &QLocalSocket::readyRead, [&backend, client]() {
            if (client->readAll() == "WAKEUP") {
                backend.showWindow();
            }
            client->deleteLater();
        });
    });

    QObject::connect(&engine, &QQmlApplicationEngine::warnings, &app, [](const QList<QQmlError> &warnings) {
        for (const QQmlError &error : warnings) {
            fprintf(stderr, "QML warning: %s\n", qPrintable(error.toString()));
        }
    });

    const QUrl url(QStringLiteral("qrc:/io/github/gustavobelo/opencouch/qml/main.qml"));
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed, &app,
                      []() { QCoreApplication::exit(-1); }, Qt::QueuedConnection);
    engine.load(url);

    if (engine.rootObjects().isEmpty()) {
        return -1;
    }

    return app.exec();
}
