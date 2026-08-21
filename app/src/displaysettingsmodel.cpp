#include "displaysettingsmodel.h"

#include "displaysettingsvalidator.h"

#include <QMetaObject>
#include <QMetaMethod>
#include <QVariant>

namespace {
QVariantMap backendConfig(QObject *backend)
{
    QVariantMap value;
    if (!backend) {
        return value;
    }

    QMetaObject::invokeMethod(backend, "loadConfig", Qt::DirectConnection,
                              Q_RETURN_ARG(QVariantMap, value));
    return value;
}

QVariantList backendOutputs(QObject *backend)
{
    QVariantList value;
    if (!backend) {
        return value;
    }

    QMetaObject::invokeMethod(backend, "listOutputs", Qt::DirectConnection,
                              Q_RETURN_ARG(QVariantList, value));
    return value;
}

bool backendBool(QObject *backend, const char *methodName, bool defaultValue = false)
{
    if (!backend) {
        return defaultValue;
    }

    bool result = defaultValue;
    QMetaObject::invokeMethod(backend, methodName, Qt::DirectConnection,
                              Q_RETURN_ARG(bool, result));
    return result;
}
}

DisplaySettingsModel::DisplaySettingsModel(QObject *parent)
    : QObject(parent)
{
    m_desktopScale = QStringLiteral("1");
    m_tvScale = QStringLiteral("1.7");
    m_tvPosition = QStringLiteral("1920,0");
}

QVariantList DisplaySettingsModel::outputs() const
{
    return m_outputs;
}

QString DisplaySettingsModel::desktopOutput() const
{
    return m_desktopOutput;
}

QString DisplaySettingsModel::tvOutput() const
{
    return m_tvOutput;
}

QString DisplaySettingsModel::desktopMode() const
{
    return m_desktopMode;
}

QString DisplaySettingsModel::tvMode() const
{
    return m_tvMode;
}

QString DisplaySettingsModel::tvPosition() const
{
    return m_tvPosition;
}

QString DisplaySettingsModel::desktopScale() const
{
    return m_desktopScale;
}

QString DisplaySettingsModel::tvScale() const
{
    return m_tvScale;
}

bool DisplaySettingsModel::keepDeskEnabled() const
{
    return m_keepDeskEnabled;
}

bool DisplaySettingsModel::mirrorDeskToTv() const
{
    return m_mirrorDeskToTv;
}

bool DisplaySettingsModel::watchBigPicture() const
{
    return m_watchBigPicture;
}

bool DisplaySettingsModel::exitOnControllersOff() const
{
    return m_exitOnControllersOff;
}

bool DisplaySettingsModel::autostart() const
{
    return m_autostart;
}

bool DisplaySettingsModel::backgroundOnClose() const
{
    return m_backgroundOnClose;
}

QString DisplaySettingsModel::lastError() const
{
    return m_lastError;
}

void DisplaySettingsModel::setDesktopOutput(const QString &value)
{
    if (m_desktopOutput == value) {
        return;
    }
    m_desktopOutput = value;
    emit desktopOutputChanged();
}

void DisplaySettingsModel::setTvOutput(const QString &value)
{
    if (m_tvOutput == value) {
        return;
    }
    m_tvOutput = value;
    emit tvOutputChanged();
}

void DisplaySettingsModel::setDesktopMode(const QString &value)
{
    if (m_desktopMode == value) {
        return;
    }
    m_desktopMode = value;
    emit desktopModeChanged();
}

void DisplaySettingsModel::setTvMode(const QString &value)
{
    if (m_tvMode == value) {
        return;
    }
    m_tvMode = value;
    emit tvModeChanged();
}

void DisplaySettingsModel::setTvPosition(const QString &value)
{
    if (m_tvPosition == value) {
        return;
    }
    m_tvPosition = value;
    emit tvPositionChanged();
}

void DisplaySettingsModel::setDesktopScale(const QString &value)
{
    if (m_desktopScale == value) {
        return;
    }
    m_desktopScale = value;
    emit desktopScaleChanged();
}

void DisplaySettingsModel::setTvScale(const QString &value)
{
    if (m_tvScale == value) {
        return;
    }
    m_tvScale = value;
    emit tvScaleChanged();
}

void DisplaySettingsModel::setKeepDeskEnabled(bool value)
{
    if (m_keepDeskEnabled == value) {
        return;
    }
    m_keepDeskEnabled = value;
    emit keepDeskEnabledChanged();
}

void DisplaySettingsModel::setMirrorDeskToTv(bool value)
{
    if (m_mirrorDeskToTv == value) {
        return;
    }
    m_mirrorDeskToTv = value;
    emit mirrorDeskToTvChanged();
}

void DisplaySettingsModel::setWatchBigPicture(bool value)
{
    if (m_watchBigPicture == value) {
        return;
    }
    m_watchBigPicture = value;
    emit watchBigPictureChanged();
}

void DisplaySettingsModel::setExitOnControllersOff(bool value)
{
    if (m_exitOnControllersOff == value) {
        return;
    }
    m_exitOnControllersOff = value;
    emit exitOnControllersOffChanged();
}

void DisplaySettingsModel::setAutostart(bool value)
{
    if (m_autostart == value) {
        return;
    }
    m_autostart = value;
    emit autostartChanged();
}

void DisplaySettingsModel::setBackgroundOnClose(bool value)
{
    if (m_backgroundOnClose == value) {
        return;
    }
    m_backgroundOnClose = value;
    emit backgroundOnCloseChanged();
}

void DisplaySettingsModel::bindBackend(QObject *backend)
{
    m_backend = backend;
    load();
}

void DisplaySettingsModel::load()
{
    m_lastError.clear();
    emit lastErrorChanged();

    const QVariantMap config = backendConfig(m_backend);
    if (config.contains(QStringLiteral("DESK_OUTPUT"))) {
        setDesktopOutput(config.value(QStringLiteral("DESK_OUTPUT")).toString());
    }
    if (config.contains(QStringLiteral("TV_OUTPUT"))) {
        setTvOutput(config.value(QStringLiteral("TV_OUTPUT")).toString());
    }
    if (config.contains(QStringLiteral("FALLBACK_DESK_MODE"))) {
        setDesktopMode(config.value(QStringLiteral("FALLBACK_DESK_MODE")).toString());
    }
    if (config.contains(QStringLiteral("FALLBACK_TV_MODE"))) {
        setTvMode(config.value(QStringLiteral("FALLBACK_TV_MODE")).toString());
    }
    if (config.contains(QStringLiteral("FALLBACK_DESK_SCALE"))) {
        setDesktopScale(config.value(QStringLiteral("FALLBACK_DESK_SCALE")).toString());
    }
    if (config.contains(QStringLiteral("FALLBACK_TV_SCALE"))) {
        setTvScale(config.value(QStringLiteral("FALLBACK_TV_SCALE")).toString());
    }
    if (config.contains(QStringLiteral("FALLBACK_TV_POS"))) {
        setTvPosition(config.value(QStringLiteral("FALLBACK_TV_POS")).toString());
    }
    setKeepDeskEnabled(config.value(QStringLiteral("KEEP_DESK_ENABLED")).toString() == QLatin1String("true"));
    setMirrorDeskToTv(config.value(QStringLiteral("MIRROR_DESK_TO_TV")).toString() == QLatin1String("true"));
    setWatchBigPicture(config.value(QStringLiteral("WATCH_BIG_PICTURE")).toString() == QLatin1String("true"));
    setExitOnControllersOff(config.value(QStringLiteral("EXIT_ON_ALL_CONTROLLERS_OFF")).toString() == QLatin1String("true"));
    setAutostart(backendBool(m_backend, "autostartEnabled"));
    setBackgroundOnClose(backendBool(m_backend, "backgroundOnClose"));
}

void DisplaySettingsModel::refreshOutputs()
{
    m_outputs = backendOutputs(m_backend);
    if (m_outputs.isEmpty()) {
        updateLastError(qtTrId("settings.error.no_outputs"));
    } else {
        m_lastError.clear();
        emit lastErrorChanged();
    }

    emit outputsChanged();

    if (m_outputs.size() >= 2 && m_desktopOutput.isEmpty()) {
        for (const QVariant &entry : m_outputs) {
            const QVariantMap output = entry.toMap();
            if (output.value(QStringLiteral("enabled")).toBool() && !m_desktopOutput.isEmpty()) {
                continue;
            }
            if (!output.value(QStringLiteral("enabled")).toBool() && !m_tvOutput.isEmpty()) {
                continue;
            }
            if (output.value(QStringLiteral("enabled")).toBool() && m_desktopOutput.isEmpty()) {
                setDesktopOutput(output.value(QStringLiteral("name")).toString());
                if (output.contains(QStringLiteral("currentMode"))) {
                    setDesktopMode(output.value(QStringLiteral("currentMode")).toString());
                }
            } else if (!output.value(QStringLiteral("enabled")).toBool() && m_tvOutput.isEmpty()) {
                setTvOutput(output.value(QStringLiteral("name")).toString());
                if (output.contains(QStringLiteral("currentMode"))) {
                    setTvMode(output.value(QStringLiteral("currentMode")).toString());
                }
            }
        }
    }
}

QVariantList DisplaySettingsModel::outputModes(const QString &name) const
{
    for (const QVariant &entry : m_outputs) {
        const QVariantMap output = entry.toMap();
        if (output.value(QStringLiteral("name")).toString() == name) {
            return output.value(QStringLiteral("modes")).toList();
        }
    }
    return {};
}

QString DisplaySettingsModel::validate() const
{
    QVariantMap config = toConfigMap();
    QString error;
    return DisplaySettingsValidator::validate(config, &error) ? QString() : error;
}

bool DisplaySettingsModel::save()
{
    const QVariantMap config = toConfigMap();
    QString error;
    if (!DisplaySettingsValidator::validate(config, &error)) {
        updateLastError(error);
        return false;
    }

    bool configSaved = false;
    bool autostartSaved = false;
    bool backgroundSaved = false;

    QMetaObject::invokeMethod(m_backend, "saveConfig",
                              Qt::DirectConnection,
                              Q_RETURN_ARG(bool, configSaved),
                              Q_ARG(QVariantMap, config));
    autostartSaved = setBackendBoolean("setAutostart", m_autostart);
    backgroundSaved = setBackendBoolean("setBackgroundOnClose", m_backgroundOnClose);

    if (!configSaved || !autostartSaved || !backgroundSaved) {
        updateLastError(qtTrId("settings.error.save_failed"));
        return false;
    }

    m_lastError.clear();
    emit lastErrorChanged();
    return true;
}

QVariantMap DisplaySettingsModel::toConfigMap() const
{
    QVariantMap config;
    config.insert(QStringLiteral("DESK_OUTPUT"), m_desktopOutput);
    config.insert(QStringLiteral("TV_OUTPUT"), m_tvOutput);
    config.insert(QStringLiteral("FALLBACK_DESK_MODE"), m_desktopMode);
    config.insert(QStringLiteral("FALLBACK_TV_MODE"), m_tvMode);
    config.insert(QStringLiteral("FALLBACK_DESK_SCALE"), m_desktopScale);
    config.insert(QStringLiteral("FALLBACK_TV_SCALE"), m_tvScale);
    config.insert(QStringLiteral("FALLBACK_TV_POS"), m_tvPosition);
    config.insert(QStringLiteral("FALLBACK_DESK_POS"), QStringLiteral("0,0"));
    config.insert(QStringLiteral("FALLBACK_DESK_PRIORITY"), QStringLiteral("1"));
    config.insert(QStringLiteral("FALLBACK_TV_PRIORITY"), QStringLiteral("2"));
    config.insert(QStringLiteral("KEEP_DESK_ENABLED"), m_keepDeskEnabled ? QStringLiteral("true") : QStringLiteral("false"));
    config.insert(QStringLiteral("MIRROR_DESK_TO_TV"), m_mirrorDeskToTv ? QStringLiteral("true") : QStringLiteral("false"));
    config.insert(QStringLiteral("WATCH_BIG_PICTURE"), m_watchBigPicture ? QStringLiteral("true") : QStringLiteral("false"));
    config.insert(QStringLiteral("EXIT_ON_ALL_CONTROLLERS_OFF"), m_exitOnControllersOff ? QStringLiteral("true") : QStringLiteral("false"));
    config.insert(QStringLiteral("AUTOSTART"), m_autostart ? QStringLiteral("true") : QStringLiteral("false"));
    return config;
}

void DisplaySettingsModel::updateLastError(const QString &message)
{
    if (m_lastError == message) {
        return;
    }
    m_lastError = message;
    emit lastErrorChanged();
}

bool DisplaySettingsModel::setBackendBoolean(const char *methodName, bool value) const
{
    return invokeBackendBool(methodName, value);
}

bool DisplaySettingsModel::invokeBackendBool(const char *methodName, bool value) const
{
    if (!m_backend) {
        return false;
    }

    bool result = false;
    QMetaObject::invokeMethod(m_backend, methodName, Qt::DirectConnection,
                              Q_RETURN_ARG(bool, result),
                              Q_ARG(bool, value));
    return result;
}

bool DisplaySettingsModel::invokeBackendConfig(const QVariantMap &config) const
{
    if (!m_backend) {
        return false;
    }

    bool result = false;
    QMetaObject::invokeMethod(m_backend, "saveConfig", Qt::DirectConnection,
                              Q_RETURN_ARG(bool, result),
                              Q_ARG(QVariantMap, config));
    return result;
}
