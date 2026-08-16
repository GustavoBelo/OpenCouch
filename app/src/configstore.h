#pragma once

#include <QObject>
#include <QVariantMap>

class ConfigStore : public QObject
{
    Q_OBJECT

public:
    explicit ConfigStore(QObject *parent = nullptr);

    QVariantMap loadConfig() const;
    bool saveConfig(const QVariantMap &config) const;

    bool autostartEnabled() const;
    bool setAutostart(bool enabled) const;

    bool backgroundOnClose() const;
    bool setBackgroundOnClose(bool enabled) const;

    bool onboardingSeen() const;
    void setOnboardingSeen(bool seen) const;

    static QString configFilePath();
    
private:
    bool requestBackgroundPortal(bool enabled) const;
};
