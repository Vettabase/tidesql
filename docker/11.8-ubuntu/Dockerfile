FROM ubuntu:24.04

# ── Build-time arguments ────────────────────────────────────────────────────
# Override with --build-arg KEY=VALUE at docker build time.
ARG MARIADB_VERSION=11.8
ARG TIDESDB_VERSION=v8.8.0
ARG TIDESDB_PREFIX=/usr/local
ARG MARIADB_PREFIX=/usr/local/mariadb
# Set WITH_TESTS=1 to include the MariaDB + TidesDB test suite in the image.
ARG WITH_TESTS=0

# Persist key paths as environment variables so they are available in every
# RUN step and at container runtime.
ENV TIDESDB_PREFIX=${TIDESDB_PREFIX} \
    MARIADB_PREFIX=${MARIADB_PREFIX} \
    DEBIAN_FRONTEND=noninteractive
ENV PATH="${MARIADB_PREFIX}/bin:${PATH}"

# ── 1. Install system dependencies ─────────────────────────────────────────
RUN apt-get update -qq && \
    apt-get install -y -qq \
        build-essential cmake ninja-build bison flex \
        libzstd-dev liblz4-dev libsnappy-dev \
        libncurses-dev libssl-dev libxml2-dev \
        libevent-dev libcurl4-openssl-dev \
        pkg-config git gnutls-dev && \
    rm -rf /var/lib/apt/lists/*

# ── 2. Copy TidesDB storage engine plugin and test suite from this repo ────
# The build context must be the repository root (see docker/README).
COPY tidesdb                        /opt/tidesql/tidesdb
COPY mysql-test/suite/tidesdb       /opt/tidesql/mysql-test/suite/tidesdb

# ── 3. Build and install TidesDB library ───────────────────────────────────
RUN git clone --depth 1 --branch "${TIDESDB_VERSION}" \
        https://github.com/tidesdb/tidesdb.git /tmp/tidesql-build/tidesdb-lib && \
    cmake \
        -S /tmp/tidesql-build/tidesdb-lib \
        -B /tmp/tidesql-build/tidesdb-lib/build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${TIDESDB_PREFIX}" \
        -DTIDESDB_BUILD_TESTS=OFF \
        -DBUILD_SHARED_LIBS=ON && \
    cmake --build /tmp/tidesql-build/tidesdb-lib/build \
        --config Release --parallel "$(nproc)" && \
    cmake --install /tmp/tidesql-build/tidesdb-lib/build --config Release && \
    ldconfig && \
    rm -rf /tmp/tidesql-build/tidesdb-lib

# ── 4. Clone MariaDB source and inject TidesDB storage engine plugin ────────
RUN git clone --depth 1 --branch "${MARIADB_VERSION}" \
        https://github.com/MariaDB/server.git /tmp/tidesql-build/mariadb-server && \
    cd /tmp/tidesql-build/mariadb-server && \
    git submodule update --init --recursive --force && \
    cp -r /opt/tidesql/tidesdb storage/ && \
    if [ "${WITH_TESTS}" = "1" ]; then \
        cp -r /opt/tidesql/mysql-test/suite/tidesdb mysql-test/suite/; \
    fi

# ── 5. Configure, build, and install MariaDB ───────────────────────────────
ARG WITH_TESTS
RUN export TIDESDB_ROOT="${TIDESDB_PREFIX}" && \
    TEST_DIR_FLAG=$([ "${WITH_TESTS:-0}" = "1" ] || echo "-DINSTALL_MYSQLTESTDIR=OFF") && \
    cmake \
        -S /tmp/tidesql-build/mariadb-server \
        -B /tmp/tidesql-build/mariadb-server/build \
        -DCMAKE_INSTALL_PREFIX="${MARIADB_PREFIX}" \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DWITH_MARIABACKUP=ON \
        -DWITH_UNIT_TESTS=OFF \
        -DCMAKE_PREFIX_PATH="${TIDESDB_PREFIX}" \
        ${TEST_DIR_FLAG} && \
    cmake --build /tmp/tidesql-build/mariadb-server/build \
        --config RelWithDebInfo --parallel "$(nproc)" && \
    cmake --install /tmp/tidesql-build/mariadb-server/build \
        --config RelWithDebInfo && \
    if [ "${WITH_TESTS:-0}" != "1" ]; then \
        rm -rf "${MARIADB_PREFIX}/mysql-test" "${MARIADB_PREFIX}/mariadb-test"; \
    fi && \
    rm -rf /tmp/tidesql-build

# ── 6. Create mysql system user and prepare data directory ──────────────────
RUN useradd -r -s /bin/false -d "${MARIADB_PREFIX}/data" mysql && \
    mkdir -p "${MARIADB_PREFIX}/data"

# bind-address is set to 0.0.0.0 so the port is reachable from the Docker host.
COPY docker/11.8-ubuntu/conf/ /etc/mysql/
RUN chown -R mysql:mysql /etc/mysql

# ── 7. Install entrypoint ──────────────────────────────────────────────────
COPY docker/11.8-ubuntu/entrypoint.sh /usr/local/bin/tidesql-entrypoint.sh
RUN chmod +x /usr/local/bin/tidesql-entrypoint.sh

VOLUME /etc/mysql
VOLUME /usr/local/mariadb/data

EXPOSE 3306

ENTRYPOINT ["/usr/local/bin/tidesql-entrypoint.sh"]
