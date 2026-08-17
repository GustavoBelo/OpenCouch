#include "engineclient.h"

#include <QFileInfo>
#include <QProcess>

namespace {
    constexpr const char *kEngineName = "open-couch-engine";

    // Bump this when the engine script changes in a way that requires users to reinstall
    // Leave it alone for app-only releases (UI, settings, translations, etc.)
    constexpr const char *kMinEngineVersion = "1.6.1";

    // Returns true if version string `a` is semantically less than `b` (X.Y.Z).
    bool versionLessThan(const QString &a, const QString &b)
    {
        const auto ap = a.split(QLatin1Char('.'));
        const auto bp = b.split(QLatin1Char('.'));
        for (int i = 0; i < 3; ++i) {
            const int av = i < ap.size() ? ap.at(i).toInt() : 0;
            const int bv = i < bp.size() ? bp.at(i).toInt() : 0;
            if (av != bv)
                return av < bv;
        }
        return false;
    }
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

QString EngineClient::engineVersion() const
{
    bool ok = false;
    const QString output = runSync({QStringLiteral("version")}, &ok);
    return ok ? output.trimmed() : QString();
}

bool EngineClient::engineNeedsUpdate() const
{
    bool ok = false;
    const QString output = runSync({QStringLiteral("version")}, &ok);
    if (!ok)
        return true; // engine exists but is too old to report version
    const QString engineVer = output.trimmed();
    if (engineVer.isEmpty())
        return true; // engine ran but couldn't report version - it's broken/stripped
    return versionLessThan(engineVer, QString::fromLatin1(kMinEngineVersion));
}

bool EngineClient::runningInFlatpakSandbox()
{
    return QFileInfo::exists(QStringLiteral("/.flatpak-info"));
}
