#!/bin/bash

# Setup the ssl_cert directory
if [ ! -d /etc/squid/ssl_cert ]; then
    mkdir /etc/squid/ssl_cert
fi

chown -R proxy:proxy /etc/squid
chmod 700 /etc/squid/ssl_cert

# Setup the squid cache directory
if [ ! -d /var/cache/squid ]; then
    mkdir -p /var/cache/squid
fi
chown -R proxy: /var/cache/squid
chmod -R 750 /var/cache/squid

if [ ! -z "$MITM_PROXY" ]; then
    if [ -z "$MITM_CERT" ] || [ -z "$MITM_KEY" ]; then
        if [ "$MITM_DEBUG" = "yes" ]; then
            echo "Generating MITM certificate CA for debugging use" 1>&2
            makecerts < /dev/null
            MITM_CERT=".crt"
            MITM_KEY=".pem"
        else
            echo "Must specify MITM_CERT AND MITM_KEY." 1>&2
            exit 1
        fi
    fi

    if [ ! -z "$MITM_KEY" ]; then
        echo "Copying $MITM_KEY as MITM key..."
        cp "$MITM_KEY" /etc/squid/ssl_cert/mitm.pem
        chown root:proxy /etc/squid/ssl_cert/mitm.pem
    fi

    if [ ! -z "$MITM_CERT" ]; then
        echo "Copying $MITM_CERT as MITM CA..."
        cp "$MITM_CERT" /etc/squid/ssl_cert/mitm.crt
        chown root:proxy /etc/squid/ssl_cert/mitm.crt
    fi
fi

chown proxy: /dev/stdout
chown proxy: /dev/stderr

# Initialize the certificates database
/usr/lib/squid/security_file_certgen -c -s /var/spool/squid/ssl_db -M 4MB
chown -R proxy: /var/spool/squid/ssl_db

#ssl_crtd -c -s
#ssl_db

# Set the configuration
if [ "$CONFIG_DISABLE" != "yes" ]; then
    p2 -t /squid.conf.p2 > /etc/squid/squid.conf

    # Parse the cache peer lines from the environment and add them to the
    # configuration
    echo '# CACHE PEERS FROM DOCKER' >> /etc/squid/squid.conf
    env | grep 'CACHE_PEER' | sort | while read cacheline; do
        echo "# $cacheline " >> /etc/squid/squid.conf
        line=$(echo $cacheline | cut -d'=' -f2-)
        echo "cache_peer $line" >> /etc/squid/squid.conf
    done

    # Parse the extra config lines and append them to the configuration
    echo '# EXTRA CONFIG FROM DOCKER' >> /etc/squid/squid.conf
    env | grep 'EXTRA_CONFIG' | sort | while read extraline; do
        echo "# $extraline " >> /etc/squid/squid.conf
        line=$(echo $extraline | cut -d'=' -f2-)
        echo "$line" >> /etc/squid/squid.conf
    done
else
    echo "/etc/squid/squid.conf: CONFIGURATION TEMPLATING IS DISABLED."
fi

if [ "$DNS_OVER_HTTPS" = "yes" ]; then
    echo "Starting DNS-over-HTTPS proxy..."
    # TODO: find a way to tie this to the proxychains config
    dns-over-https-proxy -default "$DNS_OVER_HTTPS_SERVER" \
        -address "$DNS_OVER_HTTPS_LISTEN_ADDR" \
        -primary-dns "$DNS_OVER_HTTPS_PREFIX_SERVER" \
        -fallback-dns "$DNS_OVER_HTTPS_SUFFIX_SERVER" \
        -no-fallthrough "$(echo $DNS_OVER_HTTPS_NO_FALLTHROUGH | tr -s ' ' ',')" \
        -fallthrough-statuses "$DNS_OVER_HTTPS_FALLTHROUGH_STATUSES" &
    echo "Adding dns_nameservers line to squid.conf..."
    echo "dns_nameservers $(echo $DNS_OVER_HTTPS_LISTEN_ADDR | cut -d':' -f1)" >> /etc/squid/squid.conf
fi

if [ ! -e /etc/squid/squid.conf ]; then
    echo "ERROR: /etc/squid/squid.conf does not exist. Squid will not work."
    exit 1
fi

# If proxychains is requested and config templating is active
if [ "$PROXYCHAIN" = "yes" ] && [ "$CONFIG_DISABLE" != "yes" ]; then
    echo "# PROXYCHAIN CONFIG FROM DOCKER" > /etc/proxychains.conf
    # Enable remote DNS proxy
    if [ ! -z "$PROXYCHAIN_DNS" ]; then
        echo "proxy_dns" >> /etc/proxychains.conf
    fi
    # Configure proxy type
    if [ ! -z "$PROXYCHAIN_TYPE" ]; then
        echo "$PROXYCHAIN_TYPE" >> /etc/proxychains.conf
    else
        echo "strict_chain" >> /etc/proxychains.conf
    fi
    
    echo "[ProxyList]" >> /etc/proxychains.conf
    env | grep 'PROXYCHAIN_PROXY' | sort | while read proxyline; do
        echo "# $proxyline " >> /etc/squid/squid.conf
        line=$(echo $proxyline | cut -d'=' -f2-)
        echo "$line" >> /etc/proxychains.conf
    done
else
    echo "/etc/proxychains.conf : CONFIGURATION TEMPLATING IS DISABLED"
fi

# Build the configuration directories if needed
squid -z -N

if [ "$PROXYCHAIN" = "yes" ]; then
    if [ ! -e /etc/proxychains.conf ]; then
        echo "ERROR: /etc/proxychains.conf does not exist. Squid with proxychains will not work."
        exit 1
    fi 
    # Start squid with proxychains
    proxychains4 -f /etc/proxychains.conf squid -N 2>&1 &
    PID=$!
else
    # Start squid normally
    squid -N 2>&1 &
    PID=$!
fi

# This construct allows signals to kill the container successfully.
trap "kill -TERM $(jobs -p)" INT TERM
wait $PID
wait $PID
exit $?
