# Docker image for PL/Julia.
#
# Build on top of an official Debian-based PostgreSQL image and keep the
# resulting image as close as practical to the upstream postgres image.
# In particular, avoid changing inherited defaults such as the working
# directory unless there is a clear need.
#
# Supported base images:
#   https://hub.docker.com/_/postgres
#   Example tags: postgres:14 .. postgres:18, and Debian-based variants.
#
# Key build arguments:
#   BASE_IMAGE_VERSION   Base PostgreSQL image tag.
#   JULIA_MAJOR          Julia major.minor path component.
#   JULIA_VERSION        Full Julia version to install.
#   JULIA_SHA256         Archive checksum for the selected Julia tarball.
#   PLJULIA_REGRESSION   If YES, run installcheck during build.
#   PLJULIA_PACKAGES     Comma-separated Julia packages to preinstall.
#
# Julia support policy:
#   Only Julia 1.10 and newer are supported.
#

ARG BASE_IMAGE_VERSION=postgres:14
FROM $BASE_IMAGE_VERSION AS builder

# Install build dependencies
RUN    apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        postgresql-server-dev-$PG_MAJOR \
        patchelf \
    && apt-get clean -y \
    && rm -rf /var/lib/apt/lists/* /tmp/*

# Julia version configuration. : https://julialang.org/downloads/manual-downloads/
ARG JULIA_VERSION=1.10.11
ARG JULIA_SHA256=""
ARG PLJULIA_PACKAGES="CpuId,Primes"

# Export Julia-related environment variables.
# Export Julia-related environment variables.
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    \
    JULIA_VERSION=$JULIA_VERSION \
    PLJULIA_PACKAGES=$PLJULIA_PACKAGES \
    \
    JULIA_DIR=/usr/local/julia \
    JULIA_PATH=/usr/local/julia \
    JULIA_DEPOT_PATH=/usr/local/julia-depot

# Install Julia for the target runtime architecture.
RUN set -eux; \
    arch="$(uname -m)"; \
    case "${arch}" in \
        x86_64)  julia_arch_dir="x64";    julia_arch_pkg="x86_64" ;; \
        aarch64) julia_arch_dir="aarch64"; julia_arch_pkg="aarch64" ;; \
        *) echo "Unsupported architecture: ${arch}" >&2; exit 1 ;; \
    esac; \
    # Dynamically determine JULIA_MAJOR (e.g., 1.10.11 -> 1.10)
    JULIA_MAJOR=$(echo ${JULIA_VERSION} | cut -d. -f1,2); \
    \
    mkdir -p ${JULIA_DIR} ${JULIA_DEPOT_PATH}; \
    cd /tmp; \
    \
    # If SHA256 is not provided, fetch it from the official Julia server
    if [ -z "$JULIA_SHA256" ]; then \
        curl -fL -o julia_hashes.txt "https://julialang.org/bin/checksums/julia-${JULIA_VERSION}.sha256"; \
        JULIA_SHA256=$(grep "julia-${JULIA_VERSION}-linux-${julia_arch_pkg}.tar.gz" julia_hashes.txt | cut -d' ' -f1); \
    fi; \
    \
    curl -fL -o julia.tar.gz "https://julialang-s3.julialang.org/bin/linux/${julia_arch_dir}/${JULIA_MAJOR}/julia-${JULIA_VERSION}-linux-${julia_arch_pkg}.tar.gz"; \
    echo "$JULIA_SHA256 julia.tar.gz" | sha256sum -c -; \
    tar xzf julia.tar.gz -C ${JULIA_DIR} --strip-components=1; \
    rm /tmp/julia.tar.gz /tmp/julia_hashes.txt; \
    ln -fs ${JULIA_DIR}/bin/julia /usr/local/bin/julia; \
    patchelf --clear-execstack ${JULIA_DIR}/lib/julia/libopenlibm.so

# Install Julia packages listed in ENV["PLJULIA_PACKAGES"].
# - this is a comma-separated list of package names
RUN set -eux; \
    julia -e 'using Pkg, InteractiveUtils; \
              packages = filter(!isempty, strip.(split(get(ENV, "PLJULIA_PACKAGES", ""), ","))); \
              if !isempty(packages) \
                println("install: ", join(packages, ",")); \
                for (index, package_name) in enumerate(packages) \
                  println("$(index) $(package_name)"); \
                  Pkg.add(package_name); \
                end; \
                Pkg.precompile(strict=true); \
                for package_name in packages \
                  @eval using $(Symbol(package_name)); \
                end; \
              end; \
              Pkg.status(); \
              versioninfo(); \
              if "CpuId" in packages \
                println(CpuId.cpuinfo()); \
              end;'; \
    chown -R postgres:postgres ${JULIA_DEPOT_PATH}; \
    rm -rf ${JULIA_DEPOT_PATH}/registries/General

# Add the local extension source tree to the build image.
ADD .   /pljulia

# -------- Build & Install ----------
ENV USE_PGXS=1
RUN set -eux; \
    cd /pljulia \
        && make clean \
        && make \
        && make install

# Run regression tests during the image build when enabled.
ARG PLJULIA_REGRESSION=YES
ENV PLJULIA_REGRESSION=${PLJULIA_REGRESSION}

RUN set -eux; \
    if [ "$PLJULIA_REGRESSION" = "YES" ]; then  \
           cd /pljulia \
        && mkdir /tempdb \
        && chown -R postgres:postgres /tempdb \
        && su postgres -c 'pg_ctl -D /tempdb init' \
        && su postgres -c 'pg_ctl -D /tempdb start' \
        && printf '%s\n' \
           'CREATE EXTENSION pljulia;' \
           'SELECT version() AS postgresql_full_version;' \
           'DO $$' \
           'using Pkg' \
           'arch_name = Sys.ARCH === :x86_64 ? "amd64/x86_64" : string(Sys.ARCH)' \
           'elog("INFO", "ARCH = " * arch_name)' \
           'elog("INFO", "JULIA_VERSION = " * string(VERSION))' \
           'elog("INFO", "SYS_BINDIR = " * Sys.BINDIR)' \
           'elog("INFO", "HOMEDIR = " * homedir())' \
           'elog("INFO", "PWD = " * pwd())' \
           'elog("INFO", "DEPOT_PATH = " * join(DEPOT_PATH, " | "))' \
           'elog("INFO", "LOAD_PATH = " * join(LOAD_PATH, " | "))' \
           'elog("INFO", "ACTIVE_PROJECT = " * string(Base.active_project()))' \
           'depot_writable = try; mktemp(DEPOT_PATH[1]) do path, io; end; true; catch; false; end' \
           'elog("INFO", "DEPOT_WRITABLE = " * string(depot_writable))' \
           'elog("INFO", "DEPENDENCIES = " * repr(collect(keys(Pkg.project().dependencies))))' \
           '$$ LANGUAGE pljulia;' \
           > /tmp/pljulia_env.sql \
        && chown postgres:postgres /tmp/pljulia_env.sql \
        && su postgres -c 'psql -v ON_ERROR_STOP=1 -f /tmp/pljulia_env.sql postgres' \
        && rm -f /tmp/pljulia_env.sql \
        && make installcheck PGUSER=postgres \
        && su postgres -c 'pg_ctl -D /tempdb --mode=immediate stop' \
        && rm -rf /tempdb ; \
    fi
# -----------------------------
