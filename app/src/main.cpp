#include <QApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QIcon>
#include <QTranslator>
#include <QLocale>
#include <QLocalServer>
#include <QLocalSocket>

#include "appinfomodel.h"
#include "appversion.h"
#include "backend.h"
#include "displaysettingsmodel.h"

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
    app.setWindowIcon(QIcon::fromTheme(QStringLiteral("io.github.gustavobelo.opencouch")));

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

    QQmlApplicationEngine engine;

    Backend backend;
    DisplaySettingsModel displaySettingsModel;
    AppInfoModel appInfoModel;
    engine.rootContext()->setContextProperty(QStringLiteral("backend"), &backend);
    engine.rootContext()->setContextProperty(QStringLiteral("displaySettingsModel"), &displaySettingsModel);
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