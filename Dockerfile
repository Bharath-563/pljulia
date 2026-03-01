ARG BASE_IMAGE_VERSION=postgres:14
FROM $BASE_IMAGE_VERSION AS builder

# 1. Install dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential ca-certificates curl postgresql-server-dev-14 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

ARG JULIA_MAJOR=1.10
ARG JULIA_VERSION=1.10.4
ENV JULIA_DIR=/usr/local/julia

# 2. Install Intel Julia
RUN set -eux; \
    mkdir ${JULIA_DIR} && cd /tmp && \
    curl -fL -o julia.tar.gz https://julialang-s3.julialang.org/bin/linux/x64/${JULIA_MAJOR}/julia-${JULIA_VERSION}-linux-x86_64.tar.gz && \
    tar xzf julia.tar.gz -C ${JULIA_DIR} --strip-components=1 && \
    rm /tmp/julia.tar.gz && \
    ln -fs ${JULIA_DIR}/bin/julia /usr/local/bin/julia

ADD . /pljulia
WORKDIR /pljulia

# 3. FIX: Only set CPATH for headers. Do NOT set LD_LIBRARY_PATH here 
# to avoid breaking the compiler (clang-19).
ENV USE_PGXS=1
ENV CPATH="/usr/local/julia/include/julia"
ENV SHLIB_LINK="-L${JULIA_DIR}/lib -L${JULIA_DIR}/lib/julia -ljulia"

# 4. Build - 'make' will now work because clang will use system libs
RUN make clean && make && make install

# 5. Run tests - We set LD_LIBRARY_PATH ONLY for the test execution
RUN set -eux; \
    mkdir /tempdb && chown -R postgres:postgres /tempdb && \
    su postgres -c 'pg_ctl -D /tempdb init' && \
    su postgres -c 'export LD_LIBRARY_PATH=/usr/local/julia/lib:/usr/local/julia/lib/julia; pg_ctl -D /tempdb start' && \
    export LD_LIBRARY_PATH=/usr/local/julia/lib:/usr/local/julia/lib/julia && \
    make installcheck PGUSER=postgres || (cat regression.diffs && exit 1) && \
    su postgres -c 'pg_ctl -D /tempdb --mode=immediate stop' && \
    rm -rf /tempdb
