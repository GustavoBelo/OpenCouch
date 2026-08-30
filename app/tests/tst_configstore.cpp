#include <QDir>
#include <QFile>
#include <QTemporaryDir>
#include <QTest>
#include <QTextStream>

#include "configstore.h"

// ConfigStore owns config.env, the file the engine reads. Anything it drops or
// mangles here shows up as a layout that does not match what Setup displayed.
class TestConfigStore : public QObject
{
    Q_OBJECT

private:
    QTemporaryDir m_home;

    QString configPath() const
    {
        return ConfigStore::configFilePath();
    }

    void writeRawConfig(const QString &contents)
    {
        QFile file(configPath());
        QVERIFY(QDir().mkpath(QFileInfo(file).absolutePath()));
        QVERIFY(file.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text));
        QTextStream(&file) << contents;
        file.close();
    }

private slots:
    void initTestCase()
    {
        QVERIFY(m_home.isValid());
        // Everything ConfigStore writes must land inside the temp dir, never in
        // the developer's real configuration.
        qputenv("HOME", m_home.path().toLocal8Bit());
        qputenv("XDG_CONFIG_HOME", (m_home.path() + "/config").toLocal8Bit());
        qputenv("XDG_STATE_HOME", (m_home.path() + "/state").toLocal8Bit());
        QVERIFY(configPath().startsWith(m_home.path()));
    }

    void cleanup()
    {
        QFile::remove(configPath());
    }

    void savesAndReadsBackTheDisplayConfiguration()
    {
        QVariantMap config;
        config[QStringLiteral("DESK_OUTPUT")] = QStringLiteral("DP-1");
        config[QStringLiteral("TV_OUTPUT")] = QStringLiteral("HDMI-A-1");
        config[QStringLiteral("FALLBACK_TV_MODE")] = QStringLiteral("3840x2160@120");
        config[QStringLiteral("FALLBACK_TV_SCALE")] = QStringLiteral("1.7");
        config[QStringLiteral("FALLBACK_TV_POS")] = QStringLiteral("1920,0");

        ConfigStore store;
        QVERIFY(store.saveConfig(config));

        const QVariantMap loaded = ConfigStore().loadConfig();
        QCOMPARE(loaded.value(QStringLiteral("DESK_OUTPUT")).toString(), QStringLiteral("DP-1"));
        QCOMPARE(loaded.value(QStringLiteral("TV_OUTPUT")).toString(), QStringLiteral("HDMI-A-1"));
        QCOMPARE(loaded.value(QStringLiteral("FALLBACK_TV_MODE")).toString(),
                 QStringLiteral("3840x2160@120"));
        QCOMPARE(loaded.value(QStringLiteral("FALLBACK_TV_POS")).toString(),
                 QStringLiteral("1920,0"));
    }

    void writesAFileTheShellEngineCanSource()
    {
        QVariantMap config;
        config[QStringLiteral("DESK_OUTPUT")] = QStringLiteral("DP-1");
        config[QStringLiteral("TV_OUTPUT")] = QStringLiteral("HDMI-A-1");
        ConfigStore().saveConfig(config);

        QFile file(configPath());
        QVERIFY(file.open(QIODevice::ReadOnly | QIODevice::Text));
        const QString text = QString::fromUtf8(file.readAll());
        // The engine does `source config.env`, so every line must be KEY=value.
        const QStringList lines = text.split(QLatin1Char('\n'), Qt::SkipEmptyParts);
        QVERIFY(!lines.isEmpty());
        for (const QString &line : lines) {
            if (line.trimmed().startsWith(QLatin1Char('#'))) {
                continue;
            }
            QVERIFY2(line.contains(QLatin1Char('=')), qPrintable(line));
        }
    }

    void readsValuesWrittenByTheEngineWithQuotes()
    {
        // The engine writes with printf %q, so values arrive quoted.
        writeRawConfig(QStringLiteral(
            "DESK_OUTPUT='DP-1'\n"
            "TV_OUTPUT='HDMI-A-1'\n"
            "FALLBACK_TV_SCALE='1.7'\n"));

        const QVariantMap loaded = ConfigStore().loadConfig();
        QCOMPARE(loaded.value(QStringLiteral("DESK_OUTPUT")).toString(), QStringLiteral("DP-1"));
        QCOMPARE(loaded.value(QStringLiteral("FALLBACK_TV_SCALE")).toString(),
                 QStringLiteral("1.7"));
    }

    void anAbsentConfigLoadsAsEmptyRatherThanFailing()
    {
        QVERIFY(!QFile::exists(configPath()));
        QVERIFY(ConfigStore().loadConfig().isEmpty());
    }

    void roundTripsTheAppCleanupKeys()
    {
        ConfigStore store;
        QVERIFY(store.setCloseAppsEnabled(true));
        QVERIFY(store.setCloseAppsWaitSeconds(12));
        QVERIFY(store.setAppsToClose({QStringLiteral("chromium"), QStringLiteral("firefox")}));

        ConfigStore reader;
        QVERIFY(reader.closeAppsEnabled());
        QCOMPARE(reader.closeAppsWaitSeconds(), 12);
        QCOMPARE(reader.appsToClose(),
                 QStringList({QStringLiteral("chromium"), QStringLiteral("firefox")}));
    }

    void appCleanupKeysSurviveADisplayConfigSave()
    {
        // Setup and the resource-control page write the same file; one must not
        // wipe the other's keys.
        ConfigStore store;
        store.setAppsToClose({QStringLiteral("chromium")});

        QVariantMap config;
        config[QStringLiteral("DESK_OUTPUT")] = QStringLiteral("DP-1");
        config[QStringLiteral("TV_OUTPUT")] = QStringLiteral("HDMI-A-1");
        store.saveConfig(config);

        QCOMPARE(ConfigStore().appsToClose(), QStringList({QStringLiteral("chromium")}));
    }
};

QTEST_GUILESS_MAIN(TestConfigStore)
#include "tst_configstore.moc"
