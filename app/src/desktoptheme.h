#pragma once

#include <QColor>
#include <QFileSystemWatcher>
#include <QObject>
#include <QString>

// The desktop's own colours, when the desktop publishes any.
//
// Omarchy writes the active theme to ~/.local/state/omarchy/current/theme/, and
// its quickshell panel reads colors.toml from there. Following the same file
// means this application changes colour with everything else on the machine
// instead of being the one window that ignores the theme.
//
// Everything is optional. A desktop that publishes nothing leaves `available`
// false and the application keeps its own palette, which is the case on most
// machines and is not a degraded one.
class DesktopTheme : public QObject
{
    Q_OBJECT

    Q_PROPERTY(bool available READ available NOTIFY changed)
    Q_PROPERTY(QString name READ name NOTIFY changed)
    Q_PROPERTY(QColor background READ background NOTIFY changed)
    Q_PROPERTY(QColor surface READ surface NOTIFY changed)
    Q_PROPERTY(QColor foreground READ foreground NOTIFY changed)
    Q_PROPERTY(QColor accent READ accent NOTIFY changed)
    Q_PROPERTY(QColor urgent READ urgent NOTIFY changed)

public:
    explicit DesktopTheme(QObject *parent = nullptr);

    bool available() const { return m_available; }
    QString name() const { return m_name; }
    QColor background() const { return m_background; }
    QColor surface() const { return m_surface; }
    QColor foreground() const { return m_foreground; }
    QColor accent() const { return m_accent; }
    QColor urgent() const { return m_urgent; }

signals:
    void changed();

private:
    void reload();
    void rewatch();
    static QString themeDir();

    QFileSystemWatcher m_watcher;
    bool m_available = false;
    QString m_name;
    QColor m_background;
    QColor m_surface;
    QColor m_foreground;
    QColor m_accent;
    QColor m_urgent;
};
