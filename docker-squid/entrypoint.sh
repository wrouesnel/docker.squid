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

if [ "$WG_ENABLE" = "yes" ]; then
    if [ ! -e "$WG_PEER_KEY_PATH" ]; then
        echo "Error: WG_PEER_KEY_PATH ($WG_PEER_KEY_PATH) does not exist or is inaccessible"
        exit 1
    fi
    export WG_PEER_KEY="$(cat "$WG_PEER_KEY_PATH")"
    if [ ! -e "$WG_PEER_PSK_PATH" ]; then
        echo "Error: WG_PEER_PSK_PATH ($WG_PEER_PSK_PATH) does not exist or is inaccessible"
        exit 1
    fi
    export WG_PEER_PSK="$(cat "$WG_PEER_PSK_PATH")"
fi

if [ "$WG_ENABLE" = "yes" ] && [ "$CONFIG_DISABLE" != "yes" ]; then
    if ! GW_DEV="$(ip route | grep ^default | grep -o 'dev .*' | cut -d' ' -f2)" ; then
        echo "Error: could not discover gateway interface"
        exit 1
    fi

    TPROXY_MARK=100
    ip route add local default dev lo table $TPROXY_MARK || exit 1
    ip rule add fwmark $TPROXY_MARK lookup $TPROXY_MARK || exit 1
    # Configure iptables infrastructure on launch
    iptables -t mangle -N DIVERT || exit 1
    # Don't intercept wireguard packets
    iptables -t mangle -A PREROUTING -p udp --dport 51820 -j ACCEPT || exit 1
    # Don't intercept proxy traffic
    read -r -a http_ports <<< "$HTTP_PORT"
    for http_port in "${http_ports[@]}"; do
        iptables -t mangle -A PREROUTING -p tcp --dport "$http_port" -j ACCEPT || exit 1
    done
    # Don't intercept DNS
    iptables -t mangle -A PREROUTING -p tcp --dport 53 -j ACCEPT || exit 1
    iptables -t mangle -A PREROUTING -p udp --dport 53 -j ACCEPT || exit 1

    # If TPROXY is enabled then enable TPROXY
    if [ "$WG_ENABLE_TPROXY" = "yes" ] && [ "$TPROXY_PORT" != "" ]; then
        iptables -t mangle -A PREROUTING -p tcp -j TPROXY --tproxy-mark 100/100 --on-port "$TPROXY_PORT"
    fi

    # Mark packets so they don't go through TPROXY twice
    iptables -t mangle -A DIVERT -j MARK --set-mark $TPROXY_MARK || exit 1
    iptables -t mangle -A DIVERT -j ACCEPT || exit 1
    # Divert all TCP and UDP to get otherwise sent to squid
    iptables -t mangle -A PREROUTING -p tcp -m socket -j DIVERT || exit 1
    iptables -t mangle -A PREROUTING -p udp -m socket -j DIVERT || exit 1
    # NAT outbound traffic
    iptables -t nat -A POSTROUTING -o "${GW_DEV}" -j MASQUERADE

    # In the supported model (what Unifi does) everything is NAT'd coming out of the tunnel
    # with the peer IP address.

    if ! mkdir -p /etc/wireguard ; then
        echo "Could not create /etc/wireguard"
        exit 1
    fi
    if [ ! -e "$WG_PRIVATE_KEY_PATH" ]; then
        if [ "$WG_PRIVATE_KEY_GENERATE" = "yes" ]; then
            umask 077
            if ! wg genkey > "$WG_PRIVATE_KEY_PATH"; then
                echo "Could not generate wireguard private key"
                exit 1
            fi
            
            if ! wg pubkey < "${WG_PRIVATE_KEY_PATH}" > "${WG_PRIVATE_KEY_PATH%%.*}.pub"; then
                echo "Could not generate the wireguard public key at $WG_PUBLIC_KEY_PATH"
                exit 1
            fi
            WG_PUBLIC_KEY_PATH="${WG_PRIVATE_KEY_PATH%%.*}.pub"
            if ! wg pubkey < "${WG_PRIVATE_KEY_PATH}" > "${WG_PRIVATE_KEY_PATH%%.*}.pub"; then
                echo "Could not generate the wireguard public key at $WG_PUBLIC_KEY_PATH"
                exit 1
            fi
            echo "Wrote public key to $WG_PUBLIC_KEY_PATH"
            WG_PUBLIC_KEY="$(cat "$WG_PUBLIC_KEY_PATH")"
        else
            echo "ERROR: no wireguard private key provided at $WG_PRIVATE_KEY_PATH and WG_PRIVATE_KEY_GENERATE is not yes"
            exit 1
        fi
    else
        if ! WG_PUBLIC_KEY="$(wg pubkey < "${WG_PRIVATE_KEY_PATH}")"; then
            echo "ERROR: could not read private key from $WG_PRIVATE_KEY_PATH"
            exit 1
        fi
        
    fi
    export WG_PUBLIC_KEY
    echo "Public Key: $WG_PUBLIC_KEY"
    export WG_PRIVATE_KEY="$(cat "$WG_PRIVATE_KEY_PATH")"
    if ! p2 -t /wg0.conf.p2 > /etc/wireguard/wg0.conf; then
        echo "Failed to template /etc/wireguard/wg0.conf"
        exit 1
    fi
else
    echo "/etc/wireguard/wg0.conf : CONFIGURATION TEMPLATING IS DISABLED"
fi

# Build the configuration directories if needed
squid -z -N

if [ "$WG_ENABLE" = "yes" ]; then
    echo "100 tproxy" >> /etc/iproute2/rt_tables
    if ! wg-quick up "/etc/wireguard/wg0.conf"; then
        echo "Error: could not bring up the wireguard interface. Is the container capable of NET_ADMIN,SYS_MODULE,NET_RAW ?"
        exit 1
    fi
fi

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
