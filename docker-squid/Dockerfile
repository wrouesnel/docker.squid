ARG DOCKER_PREFIX=

FROM ${DOCKER_PREFIX}ubuntu:jammy

ARG TRUST_CERT=

ARG BUILD_PREFIX=/opt/squid

ARG http_proxy=
ARG https_proxy=
ARG no_proxy=

RUN if [ ! -z "$TRUST_CERT" ]; then \
        echo "$TRUST_CERT" > /usr/local/share/ca-certificates/build-trust.crt ; \
        update-ca-certificates ; \
    fi

# Normalize apt sources
RUN cat /etc/apt/sources.list | grep -v '^#' | sed /^$/d > sources.tmp.1 && \
    cat /etc/apt/sources.list | sed s/deb\ /deb-src\ /g | grep -v '^#' | sed /^$/d > sources.tmp.2 && \
    cat sources.tmp.1 sources.tmp.2 | sort -u > /etc/apt/sources.list && \
    rm -f sources.tmp.1 sources.tmp.2

RUN export http_proxy=${http_proxy} ; \
    export https_proxy=${https_proxy} ; \
    apt-get update && \
    # install build tools
    DEBIAN_FRONTEND=noninteractive apt -y install squid

# Download p2cli dependency
RUN export http_proxy=${http_proxy} ; \
    export https_proxy=${https_proxy} ; \
    wget -O /usr/local/bin/p2 \
    https://github.com/wrouesnel/p2cli/releases/download/r13/p2-linux-x86_64 && \
    chmod +x /usr/local/bin/p2

# Clone and build proxychains-ng for SSL upstream proxying
ARG PROXYCHAINS_COMMITTISH=2cc014995e9ad038e2553a455ed914d1ad32fe49

RUN export http_proxy=${http_proxy} ; \
    export https_proxy=${https_proxy} ; \
    apt install -y git && \
    git clone https://github.com/rofl0r/proxychains-ng.git /src/proxychains-ng && \
    cd /src/proxychains-ng && \
    git checkout $PROXYCHAINS_COMMITTISH && \
    ./configure --prefix=/usr --sysconfdir=/etc && \
    make -j$CONCURRENCY && make install && \
    apt remove --purge git

ARG URL_DOH=https://github.com/wrouesnel/dns-over-https-proxy/releases/download/v0.0.2/dns-over-https-proxy_v0.0.2_linux-amd64.tar.gz

RUN wget -O /tmp/doh.tgz \
    $URL_DOH && \
    tar -xvvf /tmp/doh.tgz --strip-components=1 -C /usr/local/bin/ && \
    chmod +x /usr/local/bin/dns-over-https-proxy

COPY squid.conf.p2 /squid.conf.p2
COPY entrypoint.sh /entrypoint.sh

# Configuration environment
ENV HTTP_PORT=3128 \
    ICP_PORT= \
    HTCP_PORT= \
    MITM_PROXY= \
    MITM_CERT= \
    MITM_KEY= \
    VISIBLE_HOSTNAME=squid \
    MAX_CACHE_SIZE=40000 \
    MAX_OBJECT_SIZE="1536 MB" \
    MEM_CACHE_SIZE="128 MB" \
    DNS_OVER_HTTPS_LISTEN_ADDR="127.0.0.153:53" \
    DNS_OVER_HTTPS_SERVER="https://dns.google.com/resolve" \
    DNS_OVER_HTTPS_NO_FALLTHROUGH="" \
    DNS_OVER_HTTPS_FALLTHROUGH_STATUSES=NXDOMAIN \
    DNS_OVER_HTTPS_PREFIX_SERVER= \
    DNS_OVER_HTTPS_SUFFIX_SERVER=

EXPOSE 3128

ENTRYPOINT [ "/entrypoint.sh" ]
