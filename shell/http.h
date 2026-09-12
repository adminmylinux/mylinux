#pragma once
#include <QObject>
#include <QQmlEngine>
#include <QJSValue>
#include <QNetworkAccessManager>
#include <QVariantMap>

// Small HTTP client for QML bar modules and panels: Http.get(url, headers, options, callback).
// headers: { "Authorization": "..." }; options: { "insecure": true } accepts self-signed certificates (homelab
// boxes such as Proxmox), "timeout": ms (default 10000). callback(status, body, error): status is the HTTP code
// (0 when the request never got an answer), body the response text, error a short message or "".
class Http : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
public:
    explicit Http(QObject *parent = nullptr);
    Q_INVOKABLE void get(const QString &url, const QVariantMap &headers, const QVariantMap &options, QJSValue callback);
private:
    QNetworkAccessManager m_net;
};
