#pragma once
#include <QObject>
#include <QQmlEngine>
#include <QNetworkAccessManager>
#include <QTimer>
#include <QDateTime>

// Current weather for the desktop overlay, from Open-Meteo (no API key). The place comes from the
// setting weather/place: a city name, or "auto" (default) which asks ipapi.co for the city behind the
// VM's public address once per boot. Refreshed every 15 minutes; failures keep the last reading and set
// `error`. Units: weather/units = celsius (default) | fahrenheit.
class Weather : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(bool ok READ ok NOTIFY changed)
    Q_PROPERTY(QString error READ error NOTIFY changed)
    Q_PROPERTY(QString city READ city NOTIFY changed)
    Q_PROPERTY(QString condition READ condition NOTIFY changed)
    Q_PROPERTY(int temperature READ temperature NOTIFY changed)     // in the chosen unit, rounded
    Q_PROPERTY(int feelsLike READ feelsLike NOTIFY changed)
    Q_PROPERTY(QString unit READ unit NOTIFY changed)                // "°C" / "°F"
    Q_PROPERTY(bool isDay READ isDay NOTIFY changed)
    Q_PROPERTY(int code READ code NOTIFY changed)                    // WMO weather code
    Q_PROPERTY(QString updatedAt READ updatedAt NOTIFY changed)
public:
    explicit Weather(QObject *parent = nullptr);
    bool ok() const { return m_ok; }
    QString error() const { return m_error; }
    QString city() const { return m_city; }
    QString condition() const { return m_condition; }
    int temperature() const { return m_temp; }
    int feelsLike() const { return m_feels; }
    QString unit() const { return m_fahrenheit ? QStringLiteral("°F") : QStringLiteral("°C"); }
    bool isDay() const { return m_isDay; }
    int code() const { return m_code; }
    QString updatedAt() const { return m_updated; }
    Q_INVOKABLE void refresh();
    Q_INVOKABLE void setPlace(const QString &place);     // city name or "auto"; persisted
    Q_INVOKABLE void setFahrenheit(bool f);
    static QString describe(int code);                   // WMO code -> short text
signals:
    void changed();
private:
    void locate();
    void geocode(const QString &name);
    void fetch(double lat, double lon);
    void fail(const QString &why);
    QNetworkAccessManager m_net;
    QTimer m_timer;
    QString m_place, m_city, m_condition, m_error, m_updated;
    double m_lat = 0, m_lon = 0; bool m_located = false;
    int m_temp = 0, m_feels = 0, m_code = 0; bool m_isDay = true, m_ok = false, m_fahrenheit = false;
};
