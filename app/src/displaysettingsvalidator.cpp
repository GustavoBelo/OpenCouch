#include "displaysettingsvalidator.h"

#include <QStringList>

namespace {
bool isPositiveDouble(const QString &text, double *value)
{
    bool ok = false;
    const double parsed = text.toDouble(&ok);
    if (!ok || parsed <= 0.0) {
        return false;
    }
    if (value) {
        *value = parsed;
    }
    return true;
}
}

bool DisplaySettingsValidator::validate(const QVariantMap &config, QString *error)
{
    const QString deskOutput = config.value(QStringLiteral("DESK_OUTPUT")).toString().trimmed();
    const QString tvOutput = config.value(QStringLiteral("TV_OUTPUT")).toString().trimmed();

    if (deskOutput.isEmpty()) {
        if (error) {
            *error = QStringLiteral("Selecione o monitor do desktop.");
        }
        return false;
    }

    if (tvOutput.isEmpty()) {
        if (error) {
            *error = QStringLiteral("Selecione o monitor da TV/sala.");
        }
        return false;
    }

    if (deskOutput == tvOutput) {
        if (error) {
            *error = QStringLiteral("Os monitores do desktop e da sala devem ser diferentes.");
        }
        return false;
    }

    if (!parsePositiveDouble(config.value(QStringLiteral("FALLBACK_DESK_SCALE")),
                            QStringLiteral("FALLBACK_DESK_SCALE"), nullptr)) {
        if (error) {
            *error = QStringLiteral("A escala do desktop deve ser um número maior que zero.");
        }
        return false;
    }

    if (!parsePositiveDouble(config.value(QStringLiteral("FALLBACK_TV_SCALE")),
                            QStringLiteral("FALLBACK_TV_SCALE"), nullptr)) {
        if (error) {
            *error = QStringLiteral("A escala da TV deve ser um número maior que zero.");
        }
        return false;
    }

    const QString deskPos = config.value(QStringLiteral("FALLBACK_DESK_POS")).toString().trimmed();
    if (!deskPos.isEmpty() && !DisplaySettingsValidator::isValidPosition(deskPos)) {
        if (error) {
            *error = QStringLiteral("A posição do desktop deve seguir o formato: x,y");
        }
        return false;
    }

    const QString tvPos = config.value(QStringLiteral("FALLBACK_TV_POS")).toString().trimmed();
    if (!tvPos.isEmpty() && !DisplaySettingsValidator::isValidPosition(tvPos)) {
        if (error) {
            *error = QStringLiteral("A posição da TV deve seguir o formato: x,y");
        }
        return false;
    }

    return true;
}

bool DisplaySettingsValidator::isValidPosition(const QString &value)
{
    const QStringList parts = value.split(',', Qt::SkipEmptyParts);
    if (parts.size() != 2) {
        return false;
    }

    bool okX = false;
    bool okY = false;
    const double x = parts.at(0).trimmed().toDouble(&okX);
    const double y = parts.at(1).trimmed().toDouble(&okY);
    Q_UNUSED(x);
    Q_UNUSED(y);
    return okX && okY;
}

bool DisplaySettingsValidator::parsePositiveDouble(const QVariant &value, const QString &key, QString *error)
{
    Q_UNUSED(key);
    double parsed = 0.0;
    if (!isPositiveDouble(value.toString(), &parsed)) {
        if (error) {
            *error = QStringLiteral("O valor de %1 deve ser um número maior que zero.").arg(key);
        }
        return false;
    }
    return true;
}
