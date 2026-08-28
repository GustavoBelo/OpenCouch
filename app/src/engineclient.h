#pragma once

#include <QJsonObject>
#include <QObject>
#include <QStringList>

class EngineClient : public QObject
{
    Q_OBJECT

public:
    explicit EngineClient(QObject *parent = nullptr);

    QString engineName() const;
    QStringList commandLine(const QStringList &args) const;
    QString runSync(const QStringList &args, bool *ok = nullptr) const;
    bool engineAvailable() const;
    QString engineVersion() const;
    bool engineNeedsUpdate() const;
    QString detectCompositor() const;
    QJsonObject capabilities() const;

    static bool canAutoInstall();
    bool installBundledEngine(QString *errorMessage = nullptr) const;

private:
    static bool runningInFlatpakSandbox();
};
