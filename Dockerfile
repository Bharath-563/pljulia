ARG BASE_IMAGE_VERSION=postgres:14
FROM $BASE_IMAGE_VERSION AS builder

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    postgresql-server-dev-14 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Julia Versions for Intel CI
ARG JULIA_MAJOR=1.10
ARG JULIA_VERSION=1.10.4
ARG PLJULIA_PACKAGES=""

# Install Intel Julia
ENV JULIA_DIR=/usr/local/julia
RUN set -eux; \
    mkdir ${JULIA_DIR} && cd /tmp && \
    curl -fL -o julia.tar.gz https://julialang-s3.julialang.org/bin/linux/x64/${JULIA_MAJOR}/julia-${JULIA_VERSION}-linux-x86_64.tar.gz && \
    tar xzf julia.tar.gz -C ${JULIA_DIR} --strip-components=1 && \
    rm /tmp/julia.tar.gz && \
    ln -fs ${JULIA_DIR}/bin/julia /usr/local/bin/julia

# Add local code
ADD . /pljulia
WORKDIR /pljulia

# Build & Install
ENV USE_PGXS=1
RUN make clean && make && make install

# Regression tests
RUN set -eux; \
    mkdir /tempdb && chown -R postgres:postgres /tempdb && \
    su postgres -c 'pg_ctl -D /tempdb init' && \
    su postgres -c 'pg_ctl -D /tempdb start' && \
    make installcheck PGUSER=postgres && \
    su postgres -c 'pg_ctl -D /tempdb --mode=immediate stop' && \
    rm -rf /tempdb

echo "# Trigger CI Run: $(date)" >> Dockerfile# Force Trigger Build: Sun Mar  1 11:56:07 IST 2026
