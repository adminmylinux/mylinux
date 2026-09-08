#include "agentusage.h"
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QDateTime>
#include <QNetworkRequest>
#include <QNetworkReply>
#include <QSet>
#include <QDebug>
#include <algorithm>

static const char *kAppsHome = "/mnt/apps/root";

AgentUsage::AgentUsage(QObject *parent) : QObject(parent) {}

QString AgentUsage::home() const
{
    return QFileInfo(kAppsHome).isDir() ? QString::fromLatin1(kAppsHome) : QDir::homePath();
}

static QVariantList dayRows(const QMap<QString, qint64> &byDay)
{
    // last 7 days, oldest first, labelled Mon..Sun / Today
    QVariantList rows;
    const QDate today = QDate::currentDate();
    for (int i = 6; i >= 0; --i) {
        const QDate d = today.addDays(-i);
        QVariantMap r;
        r["label"] = i == 0 ? QStringLiteral("Today") : d.toString("ddd");
        r["tokens"] = byDay.value(d.toString(Qt::ISODate), 0);
        rows << r;
    }
    return rows;
}
static QVariantList modelRows(const QMap<QString, qint64> &byModel)
{
    QList<QPair<QString, qint64>> v;
    for (auto it = byModel.begin(); it != byModel.end(); ++it) v << qMakePair(it.key(), it.value());
    std::sort(v.begin(), v.end(), [](auto &a, auto &b) { return a.second > b.second; });
    QVariantList rows;
    for (auto &p : v) {
        if (p.second <= 0 || p.first.startsWith('<')) continue;     // "<synthetic>" placeholder rows
        QVariantMap r; r["name"] = p.first; r["tokens"] = p.second; rows << r;
    }
    return rows;
}

void AgentUsage::scanClaude()
{
    QMap<QString, qint64> byDay, byModel;
    QSet<QString> seen;
    const QDate cutoff = QDate::currentDate().addDays(-7);
    QDirIterator it(home() + "/.claude/projects", {"*.jsonl"}, QDir::Files, QDirIterator::Subdirectories);
    int files = 0;
    while (it.hasNext()) {
        QFile f(it.next()); if (!f.open(QIODevice::ReadOnly)) continue; ++files;
        while (!f.atEnd()) {
            const QByteArray line = f.readLine();
            if (!line.contains("\"usage\"")) continue;
            const QJsonObject d = QJsonDocument::fromJson(line).object();
            const QJsonObject m = d["message"].toObject();
            const QJsonObject u = m["usage"].toObject();
            if (u.isEmpty()) continue;
            const QString id = m["id"].toString() + "/" + d["requestId"].toString();
            if (!id.startsWith("/") && seen.contains(id)) continue;   // streamed duplicates
            seen.insert(id);
            const QDate day = QDateTime::fromString(d["timestamp"].toString(), Qt::ISODateWithMs).toLocalTime().date();
            if (!day.isValid() || day < cutoff) continue;
            const qint64 t = u["input_tokens"].toDouble() + u["output_tokens"].toDouble()
                           + u["cache_creation_input_tokens"].toDouble() + u["cache_read_input_tokens"].toDouble();
            byDay[day.toString(Qt::ISODate)] += t;
            QString model = m["model"].toString(); if (model.isEmpty()) model = "unknown";
            byModel[model] += t;
        }
    }
    QVariantMap c = m_claude;
    c["installed"] = QFileInfo(home() + "/.local/bin/claude").exists() || QFileInfo(home() + "/.claude").isDir();
    c["days"] = dayRows(byDay);
    c["models"] = modelRows(byModel);
    c["files"] = files;
    // plan name from the credentials file (no secrets copied out)
    QFile cred(home() + "/.claude/.credentials.json");
    if (cred.open(QIODevice::ReadOnly)) {
        const QJsonObject o = QJsonDocument::fromJson(cred.readAll()).object()["claudeAiOauth"].toObject();
        QString plan = o["subscriptionType"].toString().toUpper();
        if (o.contains("rateLimitTier")) plan += " " + o["rateLimitTier"].toString().toUpper();
        c["plan"] = plan.trimmed();
        c["signedIn"] = !o["accessToken"].toString().isEmpty();
    } else { c["plan"] = ""; c["signedIn"] = false; }
    m_claude = c;
}

void AgentUsage::fetchClaudeLimits()
{
    QFile cred(home() + "/.claude/.credentials.json");
    if (!cred.open(QIODevice::ReadOnly)) return;
    const QString token = QJsonDocument::fromJson(cred.readAll()).object()["claudeAiOauth"].toObject()["accessToken"].toString();
    if (token.isEmpty()) return;
    QNetworkRequest req(QUrl("https://api.anthropic.com/api/oauth/usage"));
    req.setRawHeader("Authorization", ("Bearer " + token).toUtf8());
    req.setRawHeader("anthropic-beta", "oauth-2025-04-20");
    req.setRawHeader("Accept", "application/json");
    m_busy = true; emit changed();
    QNetworkReply *r = m_net.get(req);
    connect(r, &QNetworkReply::finished, this, [this, r] {
        m_busy = false;
        QVariantMap c = m_claude;
        if (r->error() == QNetworkReply::NoError) {
            const QJsonObject o = QJsonDocument::fromJson(r->readAll()).object();
            QVariantList lim;
            auto add = [&](const char *key, const QString &label) {
                if (!o.contains(key)) return;
                const QJsonObject w = o[key].toObject();
                QVariantMap l; l["label"] = label; l["pct"] = w["utilization"].toDouble(); l["resetsAt"] = w["resets_at"].toString();
                lim << l;
            };
            add("five_hour", "Session"); add("seven_day", "Weekly"); add("seven_day_opus", "Opus Weekly"); add("seven_day_sonnet", "Sonnet Weekly");
            c["limits"] = lim; c["limitsError"] = "";
        } else {
            c["limitsError"] = r->errorString();
        }
        m_claude = c; r->deleteLater(); emit changed();
    });
}

void AgentUsage::scanCodex()
{
    QMap<QString, qint64> byDay, byModel;
    QVariantList limits; QString lastLimitsStamp;
    const QDate cutoff = QDate::currentDate().addDays(-7);
    QDirIterator it(home() + "/.codex/sessions", {"*.jsonl"}, QDir::Files, QDirIterator::Subdirectories);
    int files = 0;
    while (it.hasNext()) {
        QFile f(it.next()); if (!f.open(QIODevice::ReadOnly)) continue; ++files;
        QString model = "codex";
        while (!f.atEnd()) {
            const QByteArray line = f.readLine();
            if (!line.contains("token_count") && !line.contains("turn_context")) continue;
            const QJsonObject d = QJsonDocument::fromJson(line).object();
            const QJsonObject p = d["payload"].toObject();
            if (p["type"].toString() == "turn_context" || p.contains("model")) { const QString m = p["model"].toString(); if (!m.isEmpty()) model = m; continue; }
            if (p["type"].toString() != "token_count") continue;
            const QDate day = QDateTime::fromString(d["timestamp"].toString(), Qt::ISODateWithMs).toLocalTime().date();
            const QJsonObject last = p["info"].toObject()["last_token_usage"].toObject();
            const qint64 t = last["input_tokens"].toDouble() + last["output_tokens"].toDouble() + last["cached_input_tokens"].toDouble();
            if (day.isValid() && day >= cutoff) { byDay[day.toString(Qt::ISODate)] += t; byModel[model] += t; }
            const QJsonObject rl = p["rate_limits"].toObject();
            if (!rl.isEmpty() && d["timestamp"].toString() > lastLimitsStamp) {
                lastLimitsStamp = d["timestamp"].toString(); limits.clear();
                auto add = [&](const char *key, const QString &label) {
                    if (!rl.contains(key)) return;
                    const QJsonObject w = rl[key].toObject();
                    QVariantMap l; l["label"] = label; l["pct"] = w["used_percent"].toDouble() / 100.0;
                    const qint64 secs = w["resets_in_seconds"].toDouble();
                    l["resetsAt"] = secs > 0 ? QDateTime::currentDateTimeUtc().addSecs(secs).toString(Qt::ISODate) : w["resets_at"].toString();
                    limits << l;
                };
                add("primary", "Session"); add("secondary", "Weekly");
            }
        }
    }
    QVariantMap c;
    c["installed"] = QFileInfo(home() + "/.local/bin/codex").exists() || QFileInfo(home() + "/.codex").isDir();
    c["signedIn"] = QFileInfo(home() + "/.codex/auth.json").exists();
    c["days"] = dayRows(byDay); c["models"] = modelRows(byModel); c["limits"] = limits; c["files"] = files; c["plan"] = "";
    m_codex = c;
}

void AgentUsage::refresh()
{
    scanClaude(); scanCodex(); emit changed();
    fetchClaudeLimits();
}
