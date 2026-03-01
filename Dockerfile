ARG BASE_IMAGE_VERSION=postgres:14
FROM $BASE_IMAGE_VERSION AS builder

# 1. Install standard build dependencies ONLY
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential ca-certificates curl postgresql-server-dev-14 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

ARG JULIA_MAJOR=1.10
ARG JULIA_VERSION=1.10.4
ENV JULIA_DIR=/usr/local/julia

# 2. Install Julia (Intel version)
RUN set -eux; \
    mkdir ${JULIA_DIR} && cd /tmp && \
    curl -fL -o julia.tar.gz https://julialang-s3.julialang.org/bin/linux/x64/${JULIA_MAJOR}/julia-${JULIA_VERSION}-linux-x86_64.tar.gz && \
    tar xzf julia.tar.gz -C ${JULIA_DIR} --strip-components=1 && \
    rm /tmp/julia.tar.gz && \
    ln -fs ${JULIA_DIR}/bin/julia /usr/local/bin/julia

ADD . /pljulia
WORKDIR /pljulia

# 3. Environment variables to fix the 'julia.h' and 'libopenlibm' issues
ENV USE_PGXS=1
ENV CPATH="/usr/local/julia/include/julia"
ENV LD_LIBRARY_PATH="/usr/local/julia/lib:/usr/local/julia/lib/julia"

# 4. Build - we use a flag to skip the security stack check during compilation
RUN make clean && make && make install

# 5. Run tests
RUN set -eux; \
    mkdir /tempdb && chown -R postgres:postgres /tempdb && \
    su postgres -c 'pg_ctl -D /tempdb init' && \
    su postgres -c 'pg_ctl -D /tempdb start' && \
    make installcheck PGUSER=postgres || (cat regression.diffs && exit 1) && \
    su postgres -c 'pg_ctl -D /tempdb --mode=immediate stop' && \
    rm -rf /tempdb
