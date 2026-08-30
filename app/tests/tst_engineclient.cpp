#include <QDir>
#include <QFile>
#include <QJsonObject>
#include <QTemporaryDir>
#include <QTest>

#include "engineclient.h"

// EngineClient is the seam between the app and the engine: it builds the
// command line and decides whether the installed engine is new enough.
class TestEngineClient : public QObject
{
    Q_OBJECT

private:
    QTemporaryDir m_bin;
    QByteArray m_originalPath;

    // Writes a stand-in engine that answers `version`, `detect` and
    // `capabilities` the way the real one does.
    void installFakeEngine(const QString &version,
                           const QString &compositor = QStringLiteral("kde"),
                           int exitCode = 0)
    {
        const QString path = m_bin.filePath(QStringLiteral("open-couch-engine"));
        QFile script(path);
        QVERIFY(script.open(QIODevice::WriteOnly | QIODevice::Truncate));
        script.write(QStringLiteral(
            "#!/usr/bin/env bash\n"
            "case \"$1\" in\n"
            "  version) printf '%1\\n' ;;\n"
            "  detect) printf '%2\\n' ;;\n"
            "  capabilities) printf '{\"compositor\":\"%2\",\"display\":{\"primary_output\":true}}\\n' ;;\n"
            "esac\n"
            "exit %3\n")
            .arg(version, compositor)
            .arg(exitCode)
            .toUtf8());
        script.close();
        QVERIFY(script.setPermissions(QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner));
    }

private slots:
    void initTestCase()
    {
        QVERIFY(m_bin.isValid());
        m_originalPath = qgetenv("PATH");
        qputenv("PATH", m_bin.path().toLocal8Bit() + ":" + m_originalPath);
    }

    void cleanupTestCase()
    {
        qputenv("PATH", m_originalPath);
    }

    void buildsThePlainHostCommandLine()
    {
        EngineClient client;
        QCOMPARE(client.engineName(), QStringLiteral("open-couch-engine"));
        // Not inside Flatpak here, so no flatpak-spawn wrapper.
        const QStringList command = client.commandLine({QStringLiteral("status")});
        QCOMPARE(command, QStringList({QStringLiteral("open-couch-engine"),
                                       QStringLiteral("status")}));
    }

    void passesEveryArgumentThrough()
    {
        EngineClient client;
        const QStringList command =
            client.commandLine({QStringLiteral("append-log"), QStringLiteral("a b c")});
        QCOMPARE(command.size(), 3);
        QCOMPARE(command.last(), QStringLiteral("a b c"));
    }

    void readsTheEngineVersion()
    {
        installFakeEngine(QStringLiteral("1.7.0"));
        EngineClient client;
        QCOMPARE(client.engineVersion(), QStringLiteral("1.7.0"));
    }

    void anEngineAtTheMinimumIsNotOutdated()
    {
        // kMinEngineVersion is 1.7.0 today; read it from the source so this
        // test follows a bump instead of pinning yesterday's value.
        installFakeEngine(minimumEngineVersion());
        EngineClient client;
        QVERIFY(!client.engineNeedsUpdate());
    }

    void anOlderEngineNeedsAnUpdate()
    {
        installFakeEngine(QStringLiteral("0.9.9"));
        EngineClient client;
        QVERIFY(client.engineNeedsUpdate());
    }

    void aNewerEngineIsAccepted()
    {
        installFakeEngine(QStringLiteral("99.0.0"));
        EngineClient client;
        QVERIFY(!client.engineNeedsUpdate());
    }

    void anEngineThatCannotReportItsVersionNeedsAnUpdate()
    {
        // An engine so old it does not know the `version` command, or one that
        // is broken, must not be treated as good enough.
        installFakeEngine(QString(), QStringLiteral("kde"), 1);
        EngineClient client;
        QVERIFY(client.engineNeedsUpdate());
    }

    void readsTheDetectedCompositor()
    {
        installFakeEngine(QStringLiteral("1.7.0"), QStringLiteral("hyprland"));
        EngineClient client;
        QCOMPARE(client.detectCompositor(), QStringLiteral("hyprland"));
    }

    void parsesTheCapabilitiesDocument()
    {
        installFakeEngine(QStringLiteral("1.7.0"), QStringLiteral("hyprland"));
        EngineClient client;
        const QJsonObject caps = client.capabilities();
        QCOMPARE(caps.value(QStringLiteral("compositor")).toString(),
                 QStringLiteral("hyprland"));
    }

    void capabilitiesAreEmptyWhenTheEngineFails()
    {
        installFakeEngine(QStringLiteral("1.7.0"), QStringLiteral("kde"), 2);
        EngineClient client;
        QVERIFY(client.capabilities().isEmpty());
    }

private:
    // kMinEngineVersion is a file-local constant in engineclient.cpp; reading it
    // from the source keeps this test honest when it is bumped for a release.
    static QString minimumEngineVersion()
    {
        QFile source(QStringLiteral(OPENCOUCH_TEST_FIXTURES "/../../src/engineclient.cpp"));
        if (!source.open(QIODevice::ReadOnly | QIODevice::Text)) {
            return QStringLiteral("1.7.0");
        }
        const QString text = QString::fromUtf8(source.readAll());
        const int marker = text.indexOf(QStringLiteral("kMinEngineVersion"));
        if (marker < 0) {
            return QStringLiteral("1.7.0");
        }
        const int open = text.indexOf(QLatin1Char('"'), marker);
        const int close = text.indexOf(QLatin1Char('"'), open + 1);
        return text.mid(open + 1, close - open - 1);
    }
};

QTEST_GUILESS_MAIN(TestEngineClient)
#include "tst_engineclient.moc"
