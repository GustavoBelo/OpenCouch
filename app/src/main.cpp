#include <QApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QTranslator>
#include <QLocale>
#include <QLocalServer>
#include <QLocalSocket>

#include "appinfomodel.h"
#include "appversion.h"
#include "applicationicon.h"
#include "backend.h"
#include "desktoptheme.h"

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

    // Set before QApplication exists, for two reasons. It is the Wayland app
    // id: without it Qt falls back to the executable's name ("opencouch") while
    // the desktop entry, the icon and every window rule a user could write are
    // named io.github.gustavobelo.opencouch -- nothing matched, so no icon in
    // the switcher and a float rule with nothing to attach to. And
    // QDesktopUnixServices registers the app id with xdg-desktop-portal from
    // its constructor, which runs inside QApplication's: with the name already
    // set it registers once; set afterwards it defers the call *and* arms a
    // service-watcher retry, the two race, and the portal rejects the second
    // with "connection already associated" -- a qt.qpa.services warning on
    // every launch.
    QApplication::setDesktopFileName(QStringLiteral("io.github.gustavobelo.opencouch"));

    QApplication app(argc, argv);
    app.setQuitOnLastWindowClosed(false);
    app.setApplicationName(QStringLiteral("OpenCouch"));
    app.setApplicationVersion(QStringLiteral(OPENCOUCH_VERSION_STRING));
    app.setOrganizationName(QStringLiteral("io.github.gustavobelo"));
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
    // The autostart entry and the portal's commandline both pass --autostart,
    // so the window can come up hidden for that launch alone while a manual one
    // always shows.
    backend.setLaunchedFromAutostart(app.arguments().contains(QStringLiteral("--autostart")));

    DesktopTheme desktopTheme;
    AppInfoModel appInfoModel;

    // Registered as a QML singleton rather than a context property: Colors.qml
    // is itself a singleton, and singletons are created in their own context
    // where context properties do not reach.
    qmlRegisterSingletonInstance("io.github.gustavobelo.opencouch", 1, 0, "DesktopTheme", &desktopTheme);

    QQmlApplicationEngine engine;

    engine.rootContext()->setContextProperty(QStringLiteral("backend"), &backend);
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

    const QUrl url(QStringLiteral("qrc:/qt/qml/io/github/gustavobelo/opencouch/qml/main.qml"));
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed, &app,
                      []() { QCoreApplication::exit(-1); }, Qt::QueuedConnection);
    engine.load(url);

    if (engine.rootObjects().isEmpty()) {
        return -1;
    }

    return app.exec();
}