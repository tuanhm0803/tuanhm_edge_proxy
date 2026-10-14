#!/bin/sh
# Entrypoint for the edge-certbot container.
#
# Each cycle: issue a certificate for every domain in $CERT_DOMAINS that
# doesn't have one yet, then renew anything close to expiry. nginx loads
# certificates per-handshake (see nginx.conf), so new and renewed certs are
# picked up without reloading nginx.
#
# Issuance uses the webroot method, so it needs edge-nginx serving port 80.
# If any domain is still missing a cert after a cycle (nginx not up yet, DNS
# not propagated...), retry sooner than the normal 12h. 20 minutes keeps us
# under Let's Encrypt's limit of 5 failed validations per hostname per hour.

trap exit TERM

: "${CERTBOT_EMAIL:?CERTBOT_EMAIL must be set}"

while :; do
    missing=0
    for domain in $CERT_DOMAINS; do
        if [ ! -f "/etc/letsencrypt/live/$domain/fullchain.pem" ]; then
            echo "Issuing certificate for $domain..."
            certbot certonly --webroot -w /var/www/certbot \
                -d "$domain" --email "$CERTBOT_EMAIL" \
                --agree-tos --non-interactive --no-eff-email \
                || missing=1
        fi
    done

    certbot renew --webroot -w /var/www/certbot --quiet

    # Certbot makes live/ and archive/ root-only and keys 0600. nginx loads
    # certs per-handshake in its worker processes, which run as the nginx
    # user (uid/gid 101 in nginx:alpine), so give that group read access.
    if [ -d /etc/letsencrypt/archive ]; then
        chmod 0755 /etc/letsencrypt/live /etc/letsencrypt/archive
        chgrp -R 101 /etc/letsencrypt/archive
        chmod 0640 /etc/letsencrypt/archive/*/privkey*.pem
    fi

    if [ "$missing" -eq 1 ]; then
        sleep 20m & wait $!
    else
        sleep 12h & wait $!
    fi
done
