FROM ubuntu:26.04

ARG DEBIAN_FRONTEND=noninteractive
ARG SPINEL_REF=9d10403754b91db4df7555b482c7c1436b0ddb52

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    clang-18 \
    curl \
    git \
    libclang-rt-18-dev \
    libffi-dev \
    libmariadb-dev \
    libpq-dev \
    libssl-dev \
    pkg-config \
    ruby \
    ruby-dev \
    llvm-18 \
    wrk \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

RUN gem install prism -v 1.9.0 --no-document \
    && git clone --filter=blob:none https://github.com/matz/spinel.git /tmp/spinel \
    && git -C /tmp/spinel checkout "$SPINEL_REF" \
    && make -C /tmp/spinel deps \
    && make -C /tmp/spinel -j1 \
    && make -C /tmp/spinel install PREFIX=/opt/spinel \
    && rm -rf /tmp/spinel

ENV SPINEL_REF=$SPINEL_REF \
    PATH=/opt/spinel/bin:$PATH \
    SPINEL=/opt/spinel/bin/spinel \
    SPINEL_WORKERS=1 \
    HOME=/tmp

WORKDIR /src
CMD ["ci/run.sh"]
