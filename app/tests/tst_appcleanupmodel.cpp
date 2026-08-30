#include <QTemporaryDir>
#include <QTest>
#include <QVariantList>

#include "appcleanupmodel.h"

// The resource-control list is built by scanning .desktop files. Two things
// matter: hidden entries stay hidden, and no session component can ever be
// offered for closing -- on Hyprland that once meant offering to kill the
// compositor itself.
class TestAppCleanupModel : public QObject
{
    Q_OBJECT

private:
    QTemporaryDir m_home;

    static QVariantMap findApp(const QVariantList &apps, const QString &processName)
    {
        for (const QVariant &entry : apps) {
            const QVariantMap map = entry.toMap();
            if (map.value(QStringLiteral("processName")).toString() == processName) {
                return map;
            }
        }
        return {};
    }

    static bool contains(const QVariantList &apps, const QString &processName)
    {
        return !findApp(apps, processName).isEmpty();
    }

private slots:
    void initTestCase()
    {
        QVERIFY(m_home.isValid());
        // Only the fixture directory may be scanned: pointing XDG_DATA_DIRS at
        // a path that does not exist keeps the host's real applications out.
        qputenv("HOME", m_home.path().toLocal8Bit());
        qputenv("XDG_DATA_HOME", QByteArray(OPENCOUCH_TEST_FIXTURES));
        qputenv("XDG_DATA_DIRS", (m_home.path() + "/no-such-dir").toLocal8Bit());
        qputenv("XDG_CONFIG_HOME", (m_home.path() + "/config").toLocal8Bit());
    }

    void listsARegularApplication()
    {
        AppCleanupModel model;
        const QVariantList apps = model.installedApplications();
        QVERIFY(!apps.isEmpty());

        const QVariantMap chromium = findApp(apps, QStringLiteral("chromium"));
        QVERIFY(!chromium.isEmpty());
        QCOMPARE(chromium.value(QStringLiteral("displayName")).toString(),
                 QStringLiteral("Chromium"));
    }

    void skipsTheFieldCodesInExec()
    {
        AppCleanupModel model;
        const QVariantList apps = model.installedApplications();
        // Exec=/usr/bin/gimp-2.10 %U  ->  gimp-2.10, not "%U".
        QVERIFY(contains(apps, QStringLiteral("gimp-2.10")));
        QVERIFY(!contains(apps, QStringLiteral("%U")));
    }

    void skipsEnvironmentPrefixesInExec()
    {
        AppCleanupModel model;
        // Exec=env GDK_BACKEND=wayland /usr/bin/inkscape %f
        QVERIFY(contains(model.installedApplications(), QStringLiteral("inkscape")));
    }

    void hidesNoDisplayAndHiddenEntries()
    {
        AppCleanupModel model;
        const QVariantList apps = model.installedApplications();
        QVERIFY(!contains(apps, QStringLiteral("nodisplay-app")));
        QVERIFY(!contains(apps, QStringLiteral("hidden-app")));
    }

    void ignoresEntriesThatAreNotApplications()
    {
        AppCleanupModel model;
        QVERIFY(!contains(model.installedApplications(), QStringLiteral("some-link")));
    }

    void neverOffersASessionComponent()
    {
        AppCleanupModel model;
        const QVariantList apps = model.installedApplications();
        for (const QString &protectedName : {QStringLiteral("plasmashell"),
                                             QStringLiteral("Hyprland"),
                                             QStringLiteral("waybar")}) {
            QVERIFY2(!contains(apps, protectedName), qPrintable(protectedName));
        }
    }
};

QTEST_GUILESS_MAIN(TestAppCleanupModel)
#include "tst_appcleanupmodel.moc"
