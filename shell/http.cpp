#include "http.h"
#include <QNetworkRequest>
#include <QNetworkReply>
#include <QJSEngine>
#include <QUrl>

Http::Http(QObject *parent) : QObject(parent) {}

void Http::get(const QString &url, const QVariantMap &headers, const QVariantMap &options, QJSValue callback)
{
    QNetworkRequest req{QUrl(url)};
    req.setTransferTimeout(options.value("timeout", 10000).toInt());
    req.setRawHeader("User-Agent", "myLinux shell");
    for (auto it = headers.begin(); it != headers.end(); ++it) req.setRawHeader(it.key().toUtf8(), it.value().toString().toUtf8());
    QNetworkReply *r = m_net.get(req);
    // The SDK's headers were generated without QT_FEATURE_ssl although the target library has TLS (HTTPS works
    // at run time), so the certificate hook is connected by signature, resolved at run time.
    if (options.value("insecure", false).toBool())
        connect(r, SIGNAL(sslErrors(QList<QSslError>)), r, SLOT(ignoreSslErrors()));
    connect(r, &QNetworkReply::finished, this, [r, callback]() mutable {
        r->deleteLater();
        const int status = r->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const QString body = QString::fromUtf8(r->readAll());
        const QString err = r->error() == QNetworkReply::NoError ? QString() : r->errorString();
        if (callback.isCallable()) callback.call({ QJSValue(status), QJSValue(body), QJSValue(err) });
    });
}
