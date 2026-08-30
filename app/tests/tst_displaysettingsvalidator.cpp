#include <QTest>
#include <QVariantMap>

#include "displaysettingsvalidator.h"

// The validator is what stands between a typo in Setup and a display
// configuration that blanks the screen the user is looking at.
class TestDisplaySettingsValidator : public QObject
{
    Q_OBJECT

private:
    static QVariantMap validConfig()
    {
        QVariantMap config;
        config[QStringLiteral("DESK_OUTPUT")] = QStringLiteral("DP-1");
        config[QStringLiteral("TV_OUTPUT")] = QStringLiteral("HDMI-A-1");
        config[QStringLiteral("FALLBACK_DESK_SCALE")] = QStringLiteral("1");
        config[QStringLiteral("FALLBACK_TV_SCALE")] = QStringLiteral("1.7");
        config[QStringLiteral("FALLBACK_DESK_POS")] = QStringLiteral("0,0");
        config[QStringLiteral("FALLBACK_TV_POS")] = QStringLiteral("1920,0");
        return config;
    }

private slots:
    void acceptsACompleteConfig()
    {
        QString error;
        QVERIFY2(DisplaySettingsValidator::validate(validConfig(), &error),
                 qPrintable(error));
        QVERIFY(error.isEmpty());
    }

    void rejectsMissingOutputs()
    {
        QVariantMap config = validConfig();
        config[QStringLiteral("DESK_OUTPUT")] = QString();
        QVERIFY(!DisplaySettingsValidator::validate(config, nullptr));

        config = validConfig();
        config[QStringLiteral("TV_OUTPUT")] = QStringLiteral("   ");
        QVERIFY(!DisplaySettingsValidator::validate(config, nullptr));
    }

    void rejectsTheSameOutputForBothRoles()
    {
        // Picking the desk display as the TV would switch off the screen the
        // user is looking at and leave no way back.
        QVariantMap config = validConfig();
        config[QStringLiteral("TV_OUTPUT")] = QStringLiteral("DP-1");
        QString error;
        QVERIFY(!DisplaySettingsValidator::validate(config, &error));
        QVERIFY(!error.isEmpty());
    }

    void rejectsNonPositiveScales_data()
    {
        QTest::addColumn<QString>("key");
        QTest::addColumn<QString>("value");

        QTest::newRow("desk zero") << "FALLBACK_DESK_SCALE" << "0";
        QTest::newRow("desk negative") << "FALLBACK_DESK_SCALE" << "-1";
        QTest::newRow("desk empty") << "FALLBACK_DESK_SCALE" << "";
        QTest::newRow("desk text") << "FALLBACK_DESK_SCALE" << "abc";
        QTest::newRow("tv zero") << "FALLBACK_TV_SCALE" << "0";
        QTest::newRow("tv text") << "FALLBACK_TV_SCALE" << "1,7";
    }

    void rejectsNonPositiveScales()
    {
        QFETCH(QString, key);
        QFETCH(QString, value);

        QVariantMap config = validConfig();
        config[key] = value;
        QVERIFY(!DisplaySettingsValidator::validate(config, nullptr));
    }

    void isValidPosition_data()
    {
        QTest::addColumn<QString>("value");
        QTest::addColumn<bool>("expected");

        QTest::newRow("origin") << "0,0" << true;
        QTest::newRow("offset") << "1920,0" << true;
        QTest::newRow("negative") << "-1920,120" << true;
        QTest::newRow("spaces") << " 1920 , 0 " << true;
        QTest::newRow("single value") << "1920" << false;
        QTest::newRow("three values") << "1,2,3" << false;
        QTest::newRow("hyprland form") << "1920x0" << false;
        QTest::newRow("text") << "left,top" << false;
        QTest::newRow("empty") << "" << false;
    }

    void isValidPosition()
    {
        QFETCH(QString, value);
        QFETCH(bool, expected);
        QCOMPARE(DisplaySettingsValidator::isValidPosition(value), expected);
    }

    void acceptsAnEmptyPositionAsUnset()
    {
        QVariantMap config = validConfig();
        config[QStringLiteral("FALLBACK_DESK_POS")] = QString();
        config[QStringLiteral("FALLBACK_TV_POS")] = QString();
        QVERIFY(DisplaySettingsValidator::validate(config, nullptr));
    }

    void rejectsAMalformedPosition()
    {
        QVariantMap config = validConfig();
        config[QStringLiteral("FALLBACK_TV_POS")] = QStringLiteral("1920x0");
        QVERIFY(!DisplaySettingsValidator::validate(config, nullptr));
    }
};

QTEST_GUILESS_MAIN(TestDisplaySettingsValidator)
#include "tst_displaysettingsvalidator.moc"
