ARG BASE_IMAGE_VERSION=postgres:14
FROM $BASE_IMAGE_VERSION AS builder

# 1. Dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential ca-certificates curl postgresql-server-dev-14 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

ARG JULIA_MAJOR=1.10
ARG JULIA_VERSION=1.10.4
ENV JULIA_DIR=/usr/local/julia

# 2. Intel Julia
RUN set -eux; \
    mkdir ${JULIA_DIR} && cd /tmp && \
    curl -fL -o julia.tar.gz https://julialang-s3.julialang.org/bin/linux/x64/${JULIA_MAJOR}/julia-${JULIA_VERSION}-linux-x86_64.tar.gz && \
    tar xzf julia.tar.gz -C ${JULIA_DIR} --strip-components=1 && \
    rm /tmp/julia.tar.gz && \
    ln -fs ${JULIA_DIR}/bin/julia /usr/local/bin/julia

ADD . /pljulia
WORKDIR /pljulia

# 3. Build with RPATH (This embeds the Julia path directly into the .so file)
ENV USE_PGXS=1
ENV CPATH="/usr/local/julia/include/julia"
ENV SHLIB_LINK="-L${JULIA_DIR}/lib -L${JULIA_DIR}/lib/julia -Wl,-rpath,${JULIA_DIR}/lib:${JULIA_DIR}/lib/julia -ljulia"

RUN make clean && make && make install

# 4. Run tests with Extension pre-loaded
RUN set -eux; \
    mkdir /tempdb && chown -R postgres:postgres /tempdb && \
    su postgres -c 'pg_ctl -D /tempdb init' && \
    su postgres -c 'pg_ctl -D /tempdb -o "-c shared_preload_libraries=pljulia" start' && \
    su postgres -c 'psql -d postgres -c "CREATE EXTENSION pljulia;"' && \
    make installcheck PGUSER=postgres || (cat regression.diffs && exit 1) && \
    su postgres -c 'pg_ctl -D /tempdb --mode=immediate stop' && \
    rm -rf /tempdb
