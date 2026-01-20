ARG DOCKER_PREFIX=

FROM ${DOCKER_PREFIX}ubuntu:noble

ARG TRUST_CERT=

ARG BUILD_PREFIX=/opt/squid

ARG http_proxy=
ARG https_proxy=
ARG no_proxy=

RUN if [ ! -z "$TRUST_CERT" ]; then \
        echo "$TRUST_CERT" > /usr/local/share/ca-certificates/build-trust.crt ; \
        update-ca-certificates ; \
    fi

RUN if [ -e "/usr/local/share/ca-certificates/host-trust.crt" ]; then \
        mkdir -p /etc/ssl/certs ; \
        cp -f /usr/local/share/ca-certificates/host-trust.crt /etc/ssl/certs/ca-certificates ; \
    fi

# Normalize apt sources
RUN cat /etc/apt/sources.list | grep -v '^#' | sed /^$/d > sources.tmp.1 && \
    cat /etc/apt/sources.list | sed s/deb\ /deb-src\ /g | grep -v '^#' | sed /^$/d > sources.tmp.2 && \
    cat sources.tmp.1 sources.tmp.2 | sort -u > /etc/apt/sources.list && \
    rm -f sources.tmp.1 sources.tmp.2

ARG CONCURRENCY=1

RUN export http_proxy=${http_proxy} ; \
    export https_proxy=${https_proxy} ; \
    apt-get update && \
    # install build tools
    DEBIAN_FRONTEND=noninteractive apt -y install \
        squid-openssl \
        wireguard \
        wireguard-tools \
        iptables \
        iproute2 \
        tcpdump \
        net-tools \
        iputils-ping \
        bind9-dnsutils \
        curl


# Download p2cli dependency
RUN export http_proxy=${http_proxy} ; \
    export https_proxy=${https_proxy} ; \
    apt install -y wget && \
    wget -O /usr/local/bin/p2 \
    https://github.com/wrouesnel/p2cli/releases/download/r13/p2-linux-x86_64 && \
    chmod +x /usr/local/bin/p2 && \
    apt remove -y --purge wget

# Clone and build proxychains-ng for SSL upstream proxying
ARG PROXYCHAINS_COMMITTISH=2cc014995e9ad038e2553a455ed914d1ad32fe49

RUN export http_proxy=${http_proxy} ; \
    export https_proxy=${https_proxy} ; \
    apt install -y git build-essential && \
    git clone https://github.com/rofl0r/proxychains-ng.git /src/proxychains-ng && \
    cd /src/proxychains-ng && \
    git checkout $PROXYCHAINS_COMMITTISH && \
    ./configure --prefix=/usr --sysconfdir=/etc && \
    make -j$CONCURRENCY && make install && \
    apt -y remove --purge git build-essential && \
    apt autoremove --purge -y

ARG URL_DOH=https://github.com/wrouesnel/dns-over-https-proxy/releases/download/v0.0.2/dns-over-https-proxy_v0.0.2_linux-amd64.tar.gz

RUN apt install -y wget && \
    wget -O /tmp/doh.tgz \
    $URL_DOH && \
    tar -xvvf /tmp/doh.tgz --strip-components=1 -C /usr/local/bin/ && \
    chmod +x /usr/local/bin/dns-over-https-proxy && \
    apt remove -y --purge wget

ARG URL_MAKECERTS=https://github.com/wrouesnel/makecerts/releases/download/v0.4/makecerts.x86_64

RUN export http_proxy=${http_proxy} ; \
    export https_proxy=${https_proxy} ; \
    apt install -y wget ; \
    wget -O /usr/local/bin/makecerts $URL_MAKECERTS && \
    chmod +x /usr/local/bin/makecerts && \
    apt remove -y --purge wget


COPY squid.conf.p2 /squid.conf.p2
COPY wg0.conf.p2 /wg0.conf.p2
COPY entrypoint.sh /entrypoint.sh

# Configuration environment
ENV HTTP_PORT=3128 \
    TPROXY_PORT= \
    ICP_PORT= \
    HTCP_PORT= \
    ENABLE_WEBSOCKETS=yes \
    LOGFILE_ROTATE=0 \
    ACCESS_LOG="stdio:/dev/stdout combined" \
    CACHE_LOG="stdio:/dev/stdout" \
    CACHE_STORE_LOG="/dev/stderr" \
    MITM_PROXY= \
    MITM_CERT= \
    MITM_KEY= \
    MITM_DEBUG= \
    VISIBLE_HOSTNAME=squid \
    MAX_CACHE_SIZE=40000 \
    MAX_OBJECT_SIZE="1536 MB" \
    MEM_CACHE_SIZE="128 MB" \
    DNS_OVER_HTTPS_LISTEN_ADDR="127.0.0.153:53" \
    DNS_OVER_HTTPS_SERVER="https://dns.google.com/resolve" \
    DNS_OVER_HTTPS_NO_FALLTHROUGH="" \
    DNS_OVER_HTTPS_FALLTHROUGH_STATUSES=NXDOMAIN \
    DNS_OVER_HTTPS_PREFIX_SERVER= \
    DNS_OVER_HTTPS_SUFFIX_SERVER= \
    WG_ENABLE=no \
    WG_HOST_ADDR="172.17.0.1/32" \
    WG_PEER_ADDR="172.17.0.2/32" \
    WG_PEER_NETWORK="172.17.0.0/24" \
    WG_PEER_KEY_PATH=/etc/wireguard/pub/wg0.peer.pub \
    WG_PEER_PSK_PATH=/etc/wireguard/keys/wg0.peer.psk \
    WG_PRIVATE_KEY_PATH=/etc/wireguard/keys/wg0.key \
    WG_PRIVATE_KEY_GENERATE=yes \
    WG_ENABLE_TPROXY=yes

EXPOSE 3128

ENTRYPOINT [ "/entrypoint.sh" ]
