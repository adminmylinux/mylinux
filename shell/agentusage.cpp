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
static const int kWindowDays = 7;          // the chart shows today and the six days before it

AgentUsage::AgentUsage(QObject *parent) : QObject(parent) {}
AgentUsage::~AgentUsage() { if (m_thread) { m_thread->wait(); delete m_thread; } }

QString AgentUsage::home() const
{
    return QFileInfo(kAppsHome).isDir() ? QString::fromLatin1(kAppsHome) : QDir::homePath();
}

// ---- pure helpers -----------------------------------------------------------------------------------
static QVariantList dayRows(const QMap<QString, qint64> &byDay, const QDate &today)
{
    // last 7 days (today and six before), oldest first, labelled Mon..Sun / Today
    QVariantList rows;
    for (int i = kWindowDays - 1; i >= 0; --i) {
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

// "claude-fable-5-1" -> "Fable 5.1", "claude-opus-4-5-20251101" -> "Opus 4.5", "gpt-5.3-codex" -> "GPT 5.3 codex"
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
        if (it.value() <= 0 || it.key().startsWith('<')) continue;
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

// Claude Code keeps aggregate counters in stats-cache.json; used when no transcripts are on disk (Omarchy does the
// same). dailyModelTokens gives per-day figures inside the window; the older modelUsage block only has all-time
// totals, which are reported as such (allTime = true), never as a seven-day figure.
static bool statsCacheFallback(const QString &dir, const QDate &cutoff, QMap<QString, qint64> &byDay, QMap<QString, qint64> &byModel, bool &allTime)
{
    QFile f(dir + "/stats-cache.json");
    if (!f.open(QIODevice::ReadOnly)) return false;
    const QJsonObject d = QJsonDocument::fromJson(f.readAll()).object();
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
    allTime = false;
    if (byModel.isEmpty()) {
        const QJsonObject mu = d["modelUsage"].toObject();
        for (auto it = mu.begin(); it != mu.end(); ++it) {
            const QJsonObject u = it.value().toObject();
            byModel[it.key()] += u["inputTokens"].toDouble() + u["outputTokens"].toDouble()
                               + u["cacheReadInputTokens"].toDouble() + u["cacheCreationInputTokens"].toDouble();
        }
        allTime = !byModel.isEmpty();
    }
    return !byModel.isEmpty();
}

// One Claude Code transcript (JSONL). Token totals per assistant message: input + output + cache creation +
// cache read (the four counters are distinct buckets in the API's usage object; a message's input_tokens does
// not include its cached input). Streamed duplicates (same message id + request id) count once.
static void parseClaudeFile(const QString &path, AgentFileStats &st)
{
    QFile f(path); if (!f.open(QIODevice::ReadOnly)) return;
    QSet<QString> seen;
    while (!f.atEnd()) {
        const QByteArray line = f.readLine();
        if (!line.contains("\"usage\"")) continue;
        const QJsonObject d = QJsonDocument::fromJson(line).object();
        const QJsonObject m = d["message"].toObject();
        if (d["type"].toString() != "assistant" && m["role"].toString() != "assistant") continue;
        const QJsonObject u = m["usage"].toObject();
        if (u.isEmpty()) continue;
        const QString id = m["id"].toString() + "/" + d["requestId"].toString();
        if (!id.startsWith("/") && seen.contains(id)) continue;
        seen.insert(id);
        const QDate day = QDateTime::fromString(d["timestamp"].toString(), Qt::ISODateWithMs).toLocalTime().date();
        if (!day.isValid()) continue;
        const qint64 t = u["input_tokens"].toDouble() + u["output_tokens"].toDouble()
                       + u["cache_creation_input_tokens"].toDouble() + u["cache_read_input_tokens"].toDouble();
        if (t <= 0) continue;
        st.byDay[day.toString(Qt::ISODate)] += t;
        QString model = m["model"].toString(); if (model.isEmpty()) model = "claude";
        st.byModel[model] += t;
    }
}

// One Codex session (JSONL): token_count events carry the last turn's usage and, sometimes, rate limits whose
// resets_in_seconds is relative to that event's timestamp (not to whenever this runs).
static void parseCodexFile(const QString &path, AgentFileStats &st)
{
    QFile f(path); if (!f.open(QIODevice::ReadOnly)) return;
    QString model = "codex";
    while (!f.atEnd()) {
        const QByteArray line = f.readLine();
        if (!line.contains("token_count") && !line.contains("turn_context")) continue;
        const QJsonObject d = QJsonDocument::fromJson(line).object();
        const QJsonObject p = d["payload"].toObject();
        if (p["type"].toString() == "turn_context" || p.contains("model")) { const QString m = p["model"].toString(); if (!m.isEmpty()) model = m; continue; }
        if (p["type"].toString() != "token_count") continue;
        const QDateTime when = QDateTime::fromString(d["timestamp"].toString(), Qt::ISODateWithMs);
        const QDate day = when.toLocalTime().date();
        const QJsonObject last = p["info"].toObject()["last_token_usage"].toObject();
        const qint64 t = last["input_tokens"].toDouble() + last["output_tokens"].toDouble() + last["cached_input_tokens"].toDouble();
        if (day.isValid()) { st.byDay[day.toString(Qt::ISODate)] += t; st.byModel[model] += t; }
        const QJsonObject rl = p["rate_limits"].toObject();
        if (!rl.isEmpty() && when.isValid() && d["timestamp"].toString() > st.limitsStamp) {
            st.limitsStamp = d["timestamp"].toString(); st.limits.clear();
            auto add = [&](const char *key, const QString &label) {
                if (!rl.contains(key)) return;
                const QJsonObject w = rl[key].toObject();
                QVariantMap l; l["label"] = label;
                l["pct"] = w.contains("used_percent") ? w["used_percent"].toDouble() / 100.0 : -1.0;   // field name says percent
                const qint64 secs = w["resets_in_seconds"].toDouble();
                l["resetsAt"] = secs > 0 ? when.toUTC().addSecs(secs).toString(Qt::ISODate) : w["resets_at"].toString();
                l["observedAt"] = st.limitsStamp;
                st.limits << l;
            };
            add("primary", "Session"); add("secondary", "Weekly");
        }
    }
}

AgentScanResult AgentUsage::scan(const QString &home, QHash<QString, AgentFileStats> cache, const QDate &today)
{
    AgentScanResult r;
    const QDate cutoff = today.addDays(-(kWindowDays - 1));
    QSet<QString> live;
    auto visit = [&](const QString &dir, bool claude, QMap<QString, qint64> &byDay, QMap<QString, qint64> &byModel, int &files, QVariantList *limits, QString *stamp) {
        QDirIterator it(dir, {"*.jsonl"}, QDir::Files, QDirIterator::Subdirectories);
        while (it.hasNext()) {
            const QString path = it.next(); const QFileInfo fi(path);
            live.insert(path); ++files;
            AgentFileStats &st = cache[path];
            const qint64 mt = fi.lastModified().toMSecsSinceEpoch(), sz = fi.size();
            if (st.mtime != mt || st.size != sz) {                       // changed or new: parse again
                st = AgentFileStats(); st.mtime = mt; st.size = sz;
                if (claude) parseClaudeFile(path, st); else parseCodexFile(path, st);
            }
            for (auto d = st.byDay.begin(); d != st.byDay.end(); ++d) {
                const QDate day = QDate::fromString(d.key(), Qt::ISODate);
                if (day.isValid() && day >= cutoff && day <= today) byDay[d.key()] += d.value();
            }
            // model totals follow the same window: files whose days all fall outside it contribute nothing
            bool inWindow = false;
            for (auto d = st.byDay.begin(); d != st.byDay.end(); ++d) { const QDate day = QDate::fromString(d.key(), Qt::ISODate); if (day.isValid() && day >= cutoff && day <= today) { inWindow = true; break; } }
            if (inWindow) for (auto m = st.byModel.begin(); m != st.byModel.end(); ++m) byModel[m.key()] += m.value();
            if (limits && !st.limitsStamp.isEmpty() && st.limitsStamp > *stamp) { *stamp = st.limitsStamp; *limits = st.limits; }
        }
    };
    // Claude
    {
        QMap<QString, qint64> byDay, byModel; int files = 0;
        const QString dir = home + "/.claude";
        visit(dir + "/projects", true, byDay, byModel, files, nullptr, nullptr);
        bool fromCache = false, allTime = false;
        if (byModel.isEmpty()) fromCache = statsCacheFallback(dir, cutoff, byDay, byModel, allTime);
        QVariantMap c;
        c["installed"] = QFileInfo(home + "/.local/bin/claude").exists() || QFileInfo(dir).isDir();
        c["days"] = dayRows(byDay, today);
        c["models"] = modelRowsNamed(byModel);
        c["files"] = files; c["fromCache"] = fromCache; c["allTime"] = allTime;
        QFile cred(dir + "/.credentials.json");            // plan name and sign-in state only; no token copied out
        if (cred.open(QIODevice::ReadOnly)) {
            const QJsonObject o = QJsonDocument::fromJson(cred.readAll()).object()["claudeAiOauth"].toObject();
            c["plan"] = planLabel(o); c["signedIn"] = !o["accessToken"].toString().isEmpty();
        } else { c["plan"] = ""; c["signedIn"] = false; }
        r.claude = c;
    }
    // Codex
    {
        QMap<QString, qint64> byDay, byModel; int files = 0; QVariantList limits; QString stamp;
        visit(home + "/.codex/sessions", false, byDay, byModel, files, &limits, &stamp);
        QVariantMap c;
        c["installed"] = QFileInfo(home + "/.local/bin/codex").exists() || QFileInfo(home + "/.codex").isDir();
        c["signedIn"] = QFileInfo(home + "/.codex/auth.json").exists();
        c["days"] = dayRows(byDay, today); c["models"] = modelRows(byModel); c["limits"] = limits; c["files"] = files; c["plan"] = "";
        c["limitsObservedAt"] = stamp;
        r.codex = c;
    }
    for (auto it = cache.begin(); it != cache.end();) { if (live.contains(it.key())) ++it; else it = cache.erase(it); }
    r.cache = cache;
    return r;
}

// Utilization units come from the field name, never from the magnitude of the numbers: `utilization` and
// `percent` are the endpoint's documented percent fields (37.0 = 37 %). Any other field, or a value that does
// not parse, is "unknown" (pct = -1) and shown as such rather than as 0 % or 100 %.
static double percentField(const QJsonObject &o, const char *field)
{
    if (!o.contains(field)) return -1;
    const QJsonValue v = o[field];
    double n = v.isString() ? v.toString().remove('%').trimmed().toDouble() : v.toDouble(-1);
    if (!(n >= 0)) return -1;
    return std::min(1.0, n / 100.0);
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

QVariantList AgentUsage::parseClaudeLimits(const QJsonObject &o)
{
    // flat buckets: five_hour, seven_day (or seven_day_oauth_apps); model-scoped windows live in the "limits" array
    const QJsonObject session = o["five_hour"].toObject();
    const QJsonObject weekly = o.contains("seven_day_oauth_apps") && o["seven_day_oauth_apps"].isObject()
                             ? o["seven_day_oauth_apps"].toObject() : o["seven_day"].toObject();
    const QJsonArray entries = o["limits"].toArray();
    QVariantList lim;
    auto add = [&](const QString &label, double pct, const QJsonValue &resets) {
        QVariantMap l; l["label"] = label; l["pct"] = pct; l["resetsAt"] = normalizeResetAt(resets); lim << l;
    };
    if (!session.isEmpty()) add("Session", percentField(session, "utilization"), session["resets_at"]);
    if (!weekly.isEmpty()) add("Weekly", percentField(weekly, "utilization"), weekly["resets_at"]);
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
        add(w.isEmpty() ? name : name + " " + w, percentField(e, "percent"), e["resets_at"]);
    }
    if (seenScoped.isEmpty()) {         // legacy per-model buckets, only when the array did not already cover them
        for (const auto &pair : { qMakePair(QString("seven_day_opus"), QString("Opus Weekly")), qMakePair(QString("seven_day_sonnet"), QString("Sonnet Weekly")) }) {
            const QJsonObject w = o[pair.first].toObject();
            if (!w.isEmpty()) add(pair.second, percentField(w, "utilization"), w["resets_at"]);
        }
    }
    return lim;
}

// ---- the object -------------------------------------------------------------------------------------
void AgentUsage::refresh()
{
    if (m_scanning) { m_pending = true; return; }      // coalesced: one more scan after the current one
    startScan();
    fetchClaudeLimits();
}

void AgentUsage::startScan()
{
    m_scanning = true; emit changed();
    if (m_thread) { m_thread->wait(); delete m_thread; m_thread = nullptr; }
    const QString h = home(); const QHash<QString, AgentFileStats> cache = m_cache; const QDate today = QDate::currentDate();
    m_thread = QThread::create([this, h, cache, today] {
        const AgentScanResult r = scan(h, cache, today);
        QMetaObject::invokeMethod(this, [this, r] { scanDone(r); }, Qt::QueuedConnection);
    });
    m_thread->start();
}

void AgentUsage::scanDone(const AgentScanResult &r)
{
    m_cache = r.cache;
    QVariantMap c = r.claude;                                  // keep the network-derived fields
    for (const char *k : {"limits", "limitsError"}) if (m_claude.contains(k)) c[k] = m_claude[k];
    m_claude = c;
    QVariantMap x = r.codex;                                   // stale Codex limits (window already over) are dropped
    QVariantList kept;
    for (const QVariant &v : x["limits"].toList()) {
        const QDateTime resets = QDateTime::fromString(v.toMap()["resetsAt"].toString(), Qt::ISODate);
        if (!resets.isValid() || resets > QDateTime::currentDateTimeUtc()) kept << v;
    }
    x["limits"] = kept; m_codex = x;
    m_scanning = false; emit changed();
    if (m_pending) { m_pending = false; startScan(); }
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
