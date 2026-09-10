#pragma once
#include <QObject>
#include <QQmlEngine>
#include <QVariantMap>
#include <QNetworkAccessManager>
#include <QDateTime>
#include <QHash>
#include <QMap>
#include <QThread>

// Usage of the coding agents on the apps disk (Claude Code, Codex): tokens per day / model from their
// local session logs, rate limits from Codex's logs and from Claude's OAuth usage endpoint.
// Log scanning runs in a worker thread with a per-file cache (path -> mtime/size -> totals), so a refresh
// re-reads only files that changed; refresh() calls while a scan runs are coalesced into one more scan.
struct AgentFileStats {
    qint64 mtime = 0, size = 0;
    QMap<QString, qint64> byDay;          // ISO date -> tokens (unfiltered; the window is applied when combining)
    QMap<QString, qint64> byModel;
    QString limitsStamp;                  // Codex: timestamp of the newest rate_limits entry in this file
    QVariantList limits;                  // Codex: that entry, reset times anchored to the entry's timestamp
};
struct AgentScanResult { QVariantMap claude, codex; QHash<QString, AgentFileStats> cache; };

class AgentUsage : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(QVariantMap claude READ claude NOTIFY changed)
    Q_PROPERTY(QVariantMap codex READ codex NOTIFY changed)
    Q_PROPERTY(bool busy READ busy NOTIFY changed)
public:
    explicit AgentUsage(QObject *parent = nullptr);
    ~AgentUsage() override;
    QVariantMap claude() const { return m_claude; }
    QVariantMap codex() const { return m_codex; }
    bool busy() const { return m_busy || m_scanning; }
    Q_INVOKABLE void refresh();
    // pure, testable: scan the logs under `home` with a file cache (empty on first use)
    static AgentScanResult scan(const QString &home, QHash<QString, AgentFileStats> cache, const QDate &today);
    static QVariantList parseClaudeLimits(const QJsonObject &o);
signals:
    void changed();
private:
    void startScan();
    void scanDone(const AgentScanResult &r);
    void fetchClaudeLimits();
    QString home() const;
    QVariantMap m_claude, m_codex;
    QHash<QString, AgentFileStats> m_cache;
    bool m_busy = false, m_scanning = false, m_pending = false;
    QThread *m_thread = nullptr;
    QNetworkAccessManager m_net;
    QDateTime m_lastClaudeProbe;
};
