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

} // namespace

int main(int argc, char *argv[])
{
    QLocalSocket socket;
    socket.connectToServer(QStringLiteral("OpenCouchInstance"));
    if (socket.waitForConnected(500)) {
        socket.write("WAKEUP");
        socket.flush();
        socket.waitForBytesWritten(500);
        return 0;
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
    server.removeServer(QStringLiteral("OpenCouchInstance"));
    server.listen(QStringLiteral("OpenCouchInstance"));

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
