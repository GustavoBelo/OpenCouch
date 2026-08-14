#pragma once

#include <QObject>
#include <QVariantList>

class DisplaySettingsModel : public QObject
{
    Q_OBJECT

    Q_PROPERTY(QVariantList outputs READ outputs NOTIFY outputsChanged)
    Q_PROPERTY(QString desktopOutput READ desktopOutput WRITE setDesktopOutput NOTIFY desktopOutputChanged)
    Q_PROPERTY(QString tvOutput READ tvOutput WRITE setTvOutput NOTIFY tvOutputChanged)
    Q_PROPERTY(QString desktopMode READ desktopMode WRITE setDesktopMode NOTIFY desktopModeChanged)
    Q_PROPERTY(QString tvMode READ tvMode WRITE setTvMode NOTIFY tvModeChanged)
    Q_PROPERTY(QString tvPosition READ tvPosition WRITE setTvPosition NOTIFY tvPositionChanged)
    Q_PROPERTY(QString desktopScale READ desktopScale WRITE setDesktopScale NOTIFY desktopScaleChanged)
    Q_PROPERTY(QString tvScale READ tvScale WRITE setTvScale NOTIFY tvScaleChanged)
    Q_PROPERTY(bool keepDeskEnabled READ keepDeskEnabled WRITE setKeepDeskEnabled NOTIFY keepDeskEnabledChanged)
    Q_PROPERTY(bool mirrorDeskToTv READ mirrorDeskToTv WRITE setMirrorDeskToTv NOTIFY mirrorDeskToTvChanged)
    Q_PROPERTY(bool watchBigPicture READ watchBigPicture WRITE setWatchBigPicture NOTIFY watchBigPictureChanged)
    Q_PROPERTY(bool autostart READ autostart WRITE setAutostart NOTIFY autostartChanged)
    Q_PROPERTY(bool backgroundOnClose READ backgroundOnClose WRITE setBackgroundOnClose NOTIFY backgroundOnCloseChanged)
    Q_PROPERTY(QString lastError READ lastError NOTIFY lastErrorChanged)

public:
    explicit DisplaySettingsModel(QObject *parent = nullptr);

    QVariantList outputs() const;
    QString desktopOutput() const;
    QString tvOutput() const;
    QString desktopMode() const;
    QString tvMode() const;
    QString tvPosition() const;
    QString desktopScale() const;
    QString tvScale() const;
    bool keepDeskEnabled() const;
    bool mirrorDeskToTv() const;
    bool watchBigPicture() const;
    bool autostart() const;
    bool backgroundOnClose() const;
    QString lastError() const;

    void setDesktopOutput(const QString &value);
    void setTvOutput(const QString &value);
    void setDesktopMode(const QString &value);
    void setTvMode(const QString &value);
    void setTvPosition(const QString &value);
    void setDesktopScale(const QString &value);
    void setTvScale(const QString &value);
    void setKeepDeskEnabled(bool value);
    void setMirrorDeskToTv(bool value);
    void setWatchBigPicture(bool value);
    void setAutostart(bool value);
    void setBackgroundOnClose(bool value);

    Q_INVOKABLE void bindBackend(QObject *backend);
    Q_INVOKABLE void load();
    Q_INVOKABLE void refreshOutputs();
    Q_INVOKABLE QVariantList outputModes(const QString &name) const;
    Q_INVOKABLE QString validate() const;
    Q_INVOKABLE bool save();

signals:
    void outputsChanged();
    void desktopOutputChanged();
    void tvOutputChanged();
    void desktopModeChanged();
    void tvModeChanged();
    void tvPositionChanged();
    void desktopScaleChanged();
    void tvScaleChanged();
    void keepDeskEnabledChanged();
    void mirrorDeskToTvChanged();
    void watchBigPictureChanged();
    void autostartChanged();
    void backgroundOnCloseChanged();
    void lastErrorChanged();

private:
    QVariantMap toConfigMap() const;
    void updateLastError(const QString &message);
    bool setBackendBoolean(const char *methodName, bool value) const;
    bool invokeBackendBool(const char *methodName, bool value) const;
    bool invokeBackendConfig(const QVariantMap &config) const;

    QObject *m_backend = nullptr;
    QVariantList m_outputs;
    QString m_desktopOutput;
    QString m_tvOutput;
    QString m_desktopMode;
    QString m_tvMode;
    QString m_tvPosition;
    QString m_desktopScale;
    QString m_tvScale;
    bool m_keepDeskEnabled = false;
    bool m_mirrorDeskToTv = false;
    bool m_watchBigPicture = false;
    bool m_autostart = false;
    bool m_backgroundOnClose = true;
    QString m_lastError;
};
