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
#include <QRegularExpression>
#include <QTimeZone>
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

// "claude-fable-5-1" -> "Fable 5.1", "claude-opus-4-5-20251101" -> "Opus 4.5", "gpt-5.3-codex" -> "Gpt 5.3 codex"
static QString friendlyModel(const QString &id)
{
    QStringList parts = id.split('-', Qt::SkipEmptyParts);
    if (!parts.isEmpty() && parts.first() == "claude") parts.removeFirst();
    if (parts.isEmpty()) return id;
    QString name = parts.takeFirst(); name[0] = name[0].toUpper();
    if (name.compare("gpt", Qt::CaseInsensitive) == 0) name = "GPT";
    QString version; QStringList rest;
    for (const QString &p : parts) {
        bool num = false; p.toInt(&num);
        if (num && p.size() == 8) continue;                       // release date suffix
        if (num) { version += (version.isEmpty() ? "" : ".") + p; continue; }
        rest << p;
    }
    if (!version.isEmpty()) name += " " + version;
    for (QString r : rest) { r[0] = r[0].toUpper(); name += " " + r; }
    return name;
}

static QVariantList modelRowsNamed(const QMap<QString, qint64> &byModel)
{
    QMap<QString, qint64> named;
    for (auto it = byModel.begin(); it != byModel.end(); ++it) {
        if (it.value() <= 0 || it.key().startsWith('<')) continue;   // "<synthetic>" placeholder rows
        named[friendlyModel(it.key())] += it.value();
    }
    return modelRows(named);
}

// "default_claude_max_5x" -> "MAX 5X", otherwise the subscription type ("pro" -> "PRO"), like Omarchy's plan_label.
static QString planLabel(const QJsonObject &oauth)
{
    const QString tier = oauth["rateLimitTier"].toString();
    static const QRegularExpression re("max_(\\d+x)", QRegularExpression::CaseInsensitiveOption);
    const auto m = re.match(tier);
    if (m.hasMatch()) return "MAX " + m.captured(1).toUpper();
    return oauth["subscriptionType"].toString().toUpper();
}

// Claude Code keeps aggregate counters in stats-cache.json; used when no transcripts are on disk (Omarchy does the same).
static bool statsCacheFallback(const QString &dir, QMap<QString, qint64> &byDay, QMap<QString, qint64> &byModel)
{
    QFile f(dir + "/stats-cache.json");
    if (!f.open(QIODevice::ReadOnly)) return false;
    const QJsonObject d = QJsonDocument::fromJson(f.readAll()).object();
    const QDate cutoff = QDate::currentDate().addDays(-7);
    for (const QJsonValue &v : d["dailyModelTokens"].toArray()) {
        const QJsonObject e = v.toObject();
        const QDate day = QDate::fromString(e["date"].toString(), Qt::ISODate);
        if (!day.isValid() || day < cutoff) continue;
        const QJsonObject tm = e["tokensByModel"].toObject();
        for (auto it = tm.begin(); it != tm.end(); ++it) {
            const qint64 t = it.value().toDouble();
            byDay[day.toString(Qt::ISODate)] += t; byModel[it.key()] += t;
        }
    }
    if (byModel.isEmpty()) {                                        // older caches: all-time totals per model
        const QJsonObject mu = d["modelUsage"].toObject();
        for (auto it = mu.begin(); it != mu.end(); ++it) {
            const QJsonObject u = it.value().toObject();
            byModel[it.key()] += u["inputTokens"].toDouble() + u["outputTokens"].toDouble()
                               + u["cacheReadInputTokens"].toDouble() + u["cacheCreationInputTokens"].toDouble();
        }
    }
    return !byModel.isEmpty();
}

void AgentUsage::scanClaude()
{
    QMap<QString, qint64> byDay, byModel;
    QSet<QString> seen;
    const QDate cutoff = QDate::currentDate().addDays(-7);
    const QString dir = home() + "/.claude";
    QDirIterator it(dir + "/projects", {"*.jsonl"}, QDir::Files, QDirIterator::Subdirectories);
    int files = 0;
    while (it.hasNext()) {
        QFile f(it.next()); if (!f.open(QIODevice::ReadOnly)) continue; ++files;
        while (!f.atEnd()) {
            const QByteArray line = f.readLine();
            if (!line.contains("\"usage\"")) continue;
            const QJsonObject d = QJsonDocument::fromJson(line).object();
            const QJsonObject m = d["message"].toObject();
            if (d["type"].toString() != "assistant" && m["role"].toString() != "assistant") continue;
            const QJsonObject u = m["usage"].toObject();
            if (u.isEmpty()) continue;
            const QString id = m["id"].toString() + "/" + d["requestId"].toString();
            if (!id.startsWith("/") && seen.contains(id)) continue;   // streamed duplicates
            seen.insert(id);
            const QDate day = QDateTime::fromString(d["timestamp"].toString(), Qt::ISODateWithMs).toLocalTime().date();
            if (!day.isValid() || day < cutoff) continue;
            const qint64 t = u["input_tokens"].toDouble() + u["output_tokens"].toDouble()
                           + u["cache_creation_input_tokens"].toDouble() + u["cache_read_input_tokens"].toDouble();
            if (t <= 0) continue;
            byDay[day.toString(Qt::ISODate)] += t;
            QString model = m["model"].toString(); if (model.isEmpty()) model = "claude";
            byModel[model] += t;
        }
    }
    bool fromCache = false;
    if (byModel.isEmpty()) fromCache = statsCacheFallback(dir, byDay, byModel);
    QVariantMap c = m_claude;
    c["installed"] = QFileInfo(home() + "/.local/bin/claude").exists() || QFileInfo(dir).isDir();
    c["days"] = dayRows(byDay);
    c["models"] = modelRowsNamed(byModel);
    c["files"] = files;
    c["fromCache"] = fromCache;
    // plan name and sign-in state from the credentials file (no secrets copied out)
    QFile cred(dir + "/.credentials.json");
    if (cred.open(QIODevice::ReadOnly)) {
        const QJsonObject o = QJsonDocument::fromJson(cred.readAll()).object()["claudeAiOauth"].toObject();
        c["plan"] = planLabel(o);
        c["signedIn"] = !o["accessToken"].toString().isEmpty();
    } else { c["plan"] = ""; c["signedIn"] = false; }
    m_claude = c;
}

// The endpoint reports percentages (37.0) today; older payloads used fractions (0.37). Any value >= 1 in the
// payload means percent scale, so 1.0 renders as 1%, not 100% (same rule as Omarchy's collector).
static double normalizeUtil(const QJsonValue &v, bool percentScale)
{
    double n = v.isString() ? v.toString().remove('%').trimmed().toDouble() : v.toDouble(-1);
    if (!(n >= 0)) return -1;
    if (percentScale || n > 1) return std::min(1.0, n / 100.0);
    return std::min(1.0, n);
}
static QString normalizeResetAt(const QJsonValue &v)
{
    if (v.isDouble()) { double ts = v.toDouble(); if (ts < 1e12) ts *= 1000; return QDateTime::fromMSecsSinceEpoch(qint64(ts), QTimeZone::utc()).toString(Qt::ISODate); }
    return v.toString();
}
static QString scopedWindow(const QString &kind)
{
    const QString k = kind.toLower();
    if (k.contains("month")) return "Monthly";
    if (k.contains("week") || k.contains("day")) return "Weekly";
    if (k.contains("hour") || k.contains("session")) return "Session";
    return "";
}

static QVariantList parseClaudeLimits(const QJsonObject &o)
{
    // flat buckets: five_hour, seven_day (or seven_day_oauth_apps); model-scoped windows live in the "limits" array
    const QJsonObject session = o["five_hour"].toObject();
    const QJsonObject weekly = o.contains("seven_day_oauth_apps") && o["seven_day_oauth_apps"].isObject()
                             ? o["seven_day_oauth_apps"].toObject() : o["seven_day"].toObject();
    const QJsonArray entries = o["limits"].toArray();
    bool percentScale = false;
    auto sample = [&](const QJsonValue &v) { if (v.isDouble() && v.toDouble() >= 1) percentScale = true; if (v.isString() && v.toString().remove('%').toDouble() >= 1) percentScale = true; };
    sample(session["utilization"]); sample(weekly["utilization"]);
    for (const QJsonValue &e : entries) sample(e.toObject()["percent"]);

    QVariantList lim;
    auto add = [&](const QString &label, double pct, const QJsonValue &resets) {
        if (pct < 0) return;
        QVariantMap l; l["label"] = label; l["pct"] = pct; l["resetsAt"] = normalizeResetAt(resets); lim << l;
    };
    if (!session.isEmpty()) add("Session", normalizeUtil(session["utilization"], percentScale), session["resets_at"]);
    if (!weekly.isEmpty()) add("Weekly", normalizeUtil(weekly["utilization"], percentScale), weekly["resets_at"]);
    QSet<QString> seenScoped;
    for (const QJsonValue &v : entries) {
        const QJsonObject e = v.toObject();
        const QJsonObject model = e["scope"].toObject()["model"].toObject();
        if (model.isEmpty()) continue;
        QString name = model["display_name"].toString(); if (name.isEmpty()) name = model["id"].toString();
        const QString kind = e["kind"].toString();
        if (name.isEmpty() || seenScoped.contains(name + "|" + kind)) continue;
        seenScoped.insert(name + "|" + kind);
        const QString w = scopedWindow(kind);
        add(w.isEmpty() ? name : name + " " + w, normalizeUtil(e["percent"], percentScale), e["resets_at"]);
    }
    // legacy per-model buckets, only when the array did not already cover them
    if (seenScoped.isEmpty()) {
        for (const auto &pair : { qMakePair(QString("seven_day_opus"), QString("Opus Weekly")), qMakePair(QString("seven_day_sonnet"), QString("Sonnet Weekly")) }) {
            const QJsonObject w = o[pair.first].toObject();
            if (!w.isEmpty()) add(pair.second, normalizeUtil(w["utilization"], percentScale), w["resets_at"]);
        }
    }
    return lim;
}

void AgentUsage::fetchClaudeLimits()
{
    QFile cred(home() + "/.claude/.credentials.json");
    if (!cred.open(QIODevice::ReadOnly)) return;
    const QJsonObject o = QJsonDocument::fromJson(cred.readAll()).object()["claudeAiOauth"].toObject();
    const QString token = o["accessToken"].toString();
    if (token.isEmpty()) return;
    const double expiresAt = o["expiresAt"].toDouble();
    if (expiresAt > 0 && expiresAt <= QDateTime::currentMSecsSinceEpoch()) {
        QVariantMap c = m_claude; c["limitsError"] = "Claude Code's saved sign-in expired. Start claude in a terminal to refresh it."; m_claude = c; emit changed();
        return;
    }
    // absorb repeated panel opens: reuse a probe younger than 15 s
    if (m_lastClaudeProbe.isValid() && m_lastClaudeProbe.secsTo(QDateTime::currentDateTimeUtc()) < 15 && !m_claude["limits"].toList().isEmpty()) return;
    QNetworkRequest req(QUrl("https://api.anthropic.com/api/oauth/usage"));
    req.setRawHeader("Authorization", ("Bearer " + token).toUtf8());
    req.setRawHeader("anthropic-beta", "oauth-2025-04-20");
    req.setRawHeader("Accept", "application/json");
    req.setTransferTimeout(10000);
    m_busy = true; emit changed();
    QNetworkReply *r = m_net.get(req);
    connect(r, &QNetworkReply::finished, this, [this, r] {
        m_busy = false;
        QVariantMap c = m_claude;
        const int status = r->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (r->error() == QNetworkReply::NoError) {
            const QVariantList lim = parseClaudeLimits(QJsonDocument::fromJson(r->readAll()).object());
            if (lim.isEmpty()) c["limitsError"] = "Anthropic's usage endpoint returned no limits.";
            else { c["limits"] = lim; c["limitsError"] = ""; m_lastClaudeProbe = QDateTime::currentDateTimeUtc(); }
        } else if (status == 429) {
            c["limitsError"] = "Anthropic's usage endpoint is rate limiting checks right now.";
        } else if (status > 0) {
            c["limitsError"] = QString("Anthropic's usage endpoint returned status %1.").arg(status);
        } else {
            c["limitsError"] = "Couldn't reach Anthropic's usage endpoint (" + r->errorString() + ").";
        }
        // keep the last known limits while their windows are still open
        QVariantList kept;
        for (const QVariant &v : c["limits"].toList()) {
            const QDateTime resets = QDateTime::fromString(v.toMap()["resetsAt"].toString(), Qt::ISODate);
            if (!resets.isValid() || resets > QDateTime::currentDateTimeUtc()) kept << v;
        }
        c["limits"] = kept;
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
