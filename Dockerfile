FROM ubuntu:26.04

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    clang-18 \
    cmake \
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

COPY ci/build-mariadb.sh ci/with-build-lock.rb ci/mariadb-ref ci/mariadb-source.sha256 /opt/kiln-toolchain/ci/
RUN KILN_MARIADB_PREFIX=/opt/kiln-mariadb /opt/kiln-toolchain/ci/build-mariadb.sh

COPY ci/build-spinel.sh ci/spinel-cc.sh ci/spinel-ref /opt/kiln-toolchain/ci/
COPY patches/spinel/ /opt/kiln-toolchain/patches/spinel/
RUN KILN_SPINEL_PREFIX=/opt/spinel /opt/kiln-toolchain/ci/build-spinel.sh

ENV KILN_SPINEL_PREFIX=/opt/spinel \
    KILN_MARIADB_PREFIX=/opt/kiln-mariadb \
    PATH=/opt/spinel/bin:$PATH \
    SPINEL=/opt/spinel/bin/spinel \
    SPINEL_WORKERS=1 \
    HOME=/tmp

WORKDIR /src
CMD ["ci/run.sh"]
