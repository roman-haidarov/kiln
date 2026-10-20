FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG SPINEL_REF=519280dc9edd136186c0b0767fb73766b6e45aba

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
    llvm-18 \
    wrk \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --filter=blob:none https://github.com/matz/spinel.git /tmp/spinel \
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
