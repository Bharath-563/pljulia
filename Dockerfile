ARG BASE_IMAGE_VERSION=postgres:14
FROM $BASE_IMAGE_VERSION AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential ca-certificates curl postgresql-server-dev-14 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

ARG JULIA_MAJOR=1.10
ARG JULIA_VERSION=1.10.4
ENV JULIA_DIR=/usr/local/julia

RUN set -eux; \
    mkdir ${JULIA_DIR} && cd /tmp && \
    curl -fL -o julia.tar.gz https://julialang-s3.julialang.org/bin/linux/x64/${JULIA_MAJOR}/julia-${JULIA_VERSION}-linux-x86_64.tar.gz && \
    tar xzf julia.tar.gz -C ${JULIA_DIR} --strip-components=1 && \
    rm /tmp/julia.tar.gz && \
    ln -fs ${JULIA_DIR}/bin/julia /usr/local/bin/julia

ADD . /pljulia
WORKDIR /pljulia

ENV USE_PGXS=1
ENV CPATH="/usr/local/julia/include/julia"
# Hardcode the library rpath into the binary so we don't need LD_LIBRARY_PATH hacks
ENV SHLIB_LINK="-Wl,-rpath,${JULIA_DIR}/lib -Wl,-rpath,${JULIA_DIR}/lib/julia -L${JULIA_DIR}/lib -L${JULIA_DIR}/lib/julia -ljulia"

RUN make clean && make && make install

RUN set -eux; \
    mkdir /tempdb && chown -R postgres:postgres /tempdb && \
    su postgres -c '/usr/lib/postgresql/14/bin/initdb -D /tempdb' && \
    su postgres -c '/usr/lib/postgresql/14/bin/pg_ctl -D /tempdb start' && \
    make installcheck PGUSER=postgres || (cat regression.diffs && exit 1) && \
    su postgres -c '/usr/lib/postgresql/14/bin/pg_ctl -D /tempdb --mode=immediate stop' && \
    rm -rf /tempdb
