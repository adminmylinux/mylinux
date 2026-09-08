#pragma once
#include <QObject>
#include <QQmlEngine>
#include <QVariantMap>
#include <QNetworkAccessManager>

// Usage of the coding agents on the apps disk (Claude Code, Codex): tokens per day / model from their
// local session logs, rate limits from Codex's logs and from Claude's OAuth usage endpoint.
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
    QVariantMap claude() const { return m_claude; }
    QVariantMap codex() const { return m_codex; }
    bool busy() const { return m_busy; }
    Q_INVOKABLE void refresh();
signals:
    void changed();
private:
    void scanClaude();
    void scanCodex();
    void fetchClaudeLimits();
    QString home() const;
    QVariantMap m_claude, m_codex;
    bool m_busy = false;
    QNetworkAccessManager m_net;
};
