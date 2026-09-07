#pragma once

#include <QObject>

class ConfigStore : public QObject
{
    Q_OBJECT

public:
    explicit ConfigStore(QObject *parent = nullptr);

    bool autostartEnabled() const;
    bool setAutostart(bool enabled) const;

    bool backgroundOnClose() const;
    bool setBackgroundOnClose(bool enabled) const;

    bool startMinimized() const;
    bool setStartMinimized(bool enabled) const;

    bool onboardingSeen() const;
    void setOnboardingSeen(bool seen) const;

private:
    bool requestBackgroundPortal(bool enabled) const;
};
