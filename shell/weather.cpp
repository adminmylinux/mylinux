#include "weather.h"
#include "settings.h"
#include <QNetworkRequest>
#include <QNetworkReply>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QUrl>
#include <QUrlQuery>
#include <QDebug>
#include <cmath>

Weather::Weather(QObject *parent) : QObject(parent)
{
    Settings s;
    m_place = s.value("weather/place", "auto").toString().trimmed();
    if (m_place.isEmpty()) m_place = "auto";
    m_fahrenheit = s.value("weather/units", "celsius").toString() == "fahrenheit";
    m_timer.setInterval(15 * 60 * 1000);
    connect(&m_timer, &QTimer::timeout, this, &Weather::refresh);
    m_timer.start();
    QTimer::singleShot(4000, this, &Weather::refresh);       // after the network is up
}

QString Weather::describe(int c)
{
    if (c == 0) return "Clear";
    if (c == 1) return "Mostly clear";
    if (c == 2) return "Partly cloudy";
    if (c == 3) return "Overcast";
    if (c == 45 || c == 48) return "Fog";
    if (c >= 51 && c <= 57) return "Drizzle";
    if (c >= 61 && c <= 67) return "Rain";
    if (c >= 71 && c <= 77) return "Snow";
    if (c >= 80 && c <= 82) return "Showers";
    if (c == 85 || c == 86) return "Snow showers";
    if (c >= 95) return "Thunderstorm";
    return "Unknown";
}

void Weather::setPlace(const QString &place)
{
    m_place = place.trimmed().isEmpty() ? QStringLiteral("auto") : place.trimmed();
    Settings().set("weather/place", m_place);
    m_located = false; refresh();
}

void Weather::setFahrenheit(bool f)
{
    m_fahrenheit = f; Settings().set("weather/units", f ? "fahrenheit" : "celsius");
    refresh();
}

void Weather::fail(const QString &why)
{
    m_error = why; qWarning() << "weather:" << why; emit changed();
}

void Weather::refresh()
{
    if (m_located) { fetch(m_lat, m_lon); return; }
    if (m_place == "auto") locate(); else geocode(m_place);
}

static QNetworkRequest req(const QUrl &u)
{
    QNetworkRequest r(u); r.setTransferTimeout(10000); r.setRawHeader("User-Agent", "myLinux desktop widget"); return r;
}

void Weather::locate()
{
    QNetworkReply *r = m_net.get(req(QUrl("https://ipapi.co/json/")));
    connect(r, &QNetworkReply::finished, this, [this, r] {
        r->deleteLater();
        if (r->error() != QNetworkReply::NoError) { fail("location lookup failed (" + r->errorString() + ")"); return; }
        const QJsonObject o = QJsonDocument::fromJson(r->readAll()).object();
        if (!o.contains("latitude")) { fail("location lookup gave no position"); return; }
        m_lat = o["latitude"].toDouble(); m_lon = o["longitude"].toDouble(); m_city = o["city"].toString(); m_located = true;
        fetch(m_lat, m_lon);
    });
}

void Weather::geocode(const QString &name)
{
    QUrl u("https://geocoding-api.open-meteo.com/v1/search");
    QUrlQuery q; q.addQueryItem("name", name); q.addQueryItem("count", "1"); u.setQuery(q);
    QNetworkReply *r = m_net.get(req(u));
    connect(r, &QNetworkReply::finished, this, [this, r, name] {
        r->deleteLater();
        if (r->error() != QNetworkReply::NoError) { fail("place lookup failed (" + r->errorString() + ")"); return; }
        const QJsonArray a = QJsonDocument::fromJson(r->readAll()).object()["results"].toArray();
        if (a.isEmpty()) { fail("no place called '" + name + "'"); return; }
        const QJsonObject o = a.first().toObject();
        m_lat = o["latitude"].toDouble(); m_lon = o["longitude"].toDouble(); m_city = o["name"].toString(); m_located = true;
        fetch(m_lat, m_lon);
    });
}

void Weather::fetch(double lat, double lon)
{
    QUrl u("https://api.open-meteo.com/v1/forecast");
    QUrlQuery q;
    q.addQueryItem("latitude", QString::number(lat)); q.addQueryItem("longitude", QString::number(lon));
    q.addQueryItem("current", "temperature_2m,apparent_temperature,weather_code,is_day");
    q.addQueryItem("temperature_unit", m_fahrenheit ? "fahrenheit" : "celsius");
    u.setQuery(q);
    QNetworkReply *r = m_net.get(req(u));
    connect(r, &QNetworkReply::finished, this, [this, r] {
        r->deleteLater();
        if (r->error() != QNetworkReply::NoError) { fail("weather fetch failed (" + r->errorString() + ")"); return; }
        const QJsonObject c = QJsonDocument::fromJson(r->readAll()).object()["current"].toObject();
        if (c.isEmpty()) { fail("weather service returned no current conditions"); return; }
        m_temp = int(std::lround(c["temperature_2m"].toDouble()));
        m_feels = int(std::lround(c["apparent_temperature"].toDouble()));
        m_code = c["weather_code"].toInt(); m_isDay = c["is_day"].toInt() == 1;
        m_condition = describe(m_code);
        m_updated = QDateTime::currentDateTime().toString("HH:mm");
        m_ok = true; m_error.clear(); emit changed();
    });
}
