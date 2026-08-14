#pragma once

#include <QVariantMap>
#include <QString>

class DisplaySettingsValidator
{
public:
    static bool validate(const QVariantMap &config, QString *error = nullptr);
    static bool isValidPosition(const QString &value);

private:
    static bool parsePositiveDouble(const QVariant &value, const QString &key, QString *error);
};
