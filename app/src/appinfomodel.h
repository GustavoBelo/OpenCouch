#pragma once

#include <QObject>
#include <QString>

class AppInfoModel : public QObject
{
    Q_OBJECT

    Q_PROPERTY(QString appName READ appName CONSTANT)
    Q_PROPERTY(QString displayName READ displayName CONSTANT)
    Q_PROPERTY(QString version READ version CONSTANT)

public:
    explicit AppInfoModel(QObject *parent = nullptr);

    QString appName() const;
    QString displayName() const;
    QString version() const;

    Q_INVOKABLE QString formattedVersion() const;
};
