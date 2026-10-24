FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG SPINEL_REF=2e5295be4f1010dda79e88e6d4417081ab29f2cc

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    clang-18 \
    curl \
    git \
    libclang-rt-18-dev \
    libffi-dev \
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

ENV PATH=/opt/spinel/bin:$PATH \
    SPINEL=/opt/spinel/bin/spinel \
    SPINEL_WORKERS=1 \
    HOME=/tmp

WORKDIR /src
CMD ["ci/run.sh"]
