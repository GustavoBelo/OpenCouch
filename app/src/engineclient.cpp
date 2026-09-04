#include "engineclient.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QProcess>

namespace {
    constexpr const char *kEngineName = "open-couch-engine";

    // Bump this when the engine changes in a way that requires users to reinstall
    // Leave it alone for app-only releases (UI, settings, translations, etc.)
    constexpr const char *kMinEngineVersion = "1.7.0";

    // What `check` must print. An exit code alone cannot tell this engine from
    // the bash one it replaced: that one's `check` also succeeds, reports the
    // same version, and then answers `status` with log lines instead of JSON.
    // The app would talk to it, parse nothing, and show "not ready" for ever
    // with nothing to say why -- so identity is checked by content.
    constexpr const char *kCheckIdentity = "open-couch-engine console-mode/1";

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
    // Just the name. The engine is on PATH -- a package puts it in /usr/bin and
    // the installer in ~/.local/bin -- and there is no sandbox left to reach
    // out of.
    QStringList command{engineName()};
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
    const QString output = runSync({QStringLiteral("check")}, &ok);
    return ok && output.trimmed() == QLatin1String(kCheckIdentity);
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
