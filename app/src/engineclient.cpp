#include "engineclient.h"

#include <QFileInfo>
#include <QProcess>

namespace {
constexpr const char *kEngineName = "open-couch-engine";
}

EngineClient::EngineClient(QObject *parent)
    : QObject(parent)
{
}

QString EngineClient::engineName() const
{
    return QString::fromLatin1(kEngineName);
}

QStringList EngineClient::commandLine(const QStringList &args) const
{
    QStringList command;
    if (runningInFlatpakSandbox()) {
        command << QStringLiteral("flatpak-spawn") << QStringLiteral("--host") << engineName();
    } else {
        command << engineName();
    }
    command.append(args);
    return command;
}

QString EngineClient::runSync(const QStringList &args, bool *ok) const
{
    QProcess proc;
    const QStringList command = commandLine(args);
    proc.start(command.first(), command.mid(1));
    proc.waitForFinished(15000);

    const bool success = proc.exitStatus() == QProcess::NormalExit && proc.exitCode() == 0;
    if (ok) {
        *ok = success;
    }

    return QString::fromUtf8(proc.readAllStandardOutput());
}

bool EngineClient::engineAvailable() const
{
    bool ok = false;
    runSync({QStringLiteral("check")}, &ok);
    return ok;
}

bool EngineClient::runningInFlatpakSandbox()
{
    return QFileInfo::exists(QStringLiteral("/.flatpak-info"));
}
