ARG BASE_IMAGE_VERSION=postgres:14
FROM $BASE_IMAGE_VERSION AS builder

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        execstack \
        postgresql-server-dev-$PG_MAJOR \
    && apt-get clean -y \
    && rm -rf /var/lib/apt/lists/* /tmp/*

ARG JULIA_MAJOR=1.10
ARG JULIA_VERSION=1.10.4
ARG JULIA_SHA256=ae4ae6ade84a103cdf30ce91c8d4035a0ef51c3e2e66f90a0c13abeb4e100fc4
ARG PLJULIA_PACKAGES=""

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    JULIA_MAJOR=$JULIA_MAJOR \
    JULIA_VERSION=$JULIA_VERSION \
    JULIA_SHA256=$JULIA_SHA256 \
    PLJULIA_PACKAGES=$PLJULIA_PACKAGES \
    JULIA_DIR=/usr/local/julia \
    JULIA_PATH=/usr/local/julia

RUN set -eux; \
    mkdir ${JULIA_DIR} \
    && cd /tmp \
    && curl -fL -o julia.tar.gz https://julialang-s3.julialang.org/bin/linux/x64/${JULIA_MAJOR}/julia-${JULIA_VERSION}-linux-x86_64.tar.gz \
    && tar xzf julia.tar.gz -C ${JULIA_DIR} --strip-components=1 \
    && rm /tmp/julia.tar.gz \
    && ln -fs ${JULIA_DIR}/bin/julia /usr/local/bin/julia

RUN find /usr/local/julia/lib/julia -name "*.so" -exec execstack --clear-execstack {} \;

RUN set -eux; \
    if [ ! -z "$PLJULIA_PACKAGES" ]; then \
      echo "install: ${PLJULIA_PACKAGES}"; \
      julia -e 'using Pkg; \
                for (index, package_name) in enumerate( split(ENV["PLJULIA_PACKAGES"],",") ) ; \
                   println("$index $package_name") ; \
                   Pkg.add("$package_name"); \
                end ; \
                Pkg.instantiate(); \
                VERSION >= v"1.6.0" ? Pkg.precompile(strict=true) : Pkg.API.precompile(); \
               '; \
      julia -e "using ${PLJULIA_PACKAGES};" ; \
    fi ; \
    julia -e 'using Pkg, InteractiveUtils; Pkg.status(); versioninfo(); \
              if "CpuId" in split(ENV["PLJULIA_PACKAGES"],",") \
                using CpuId; println(cpuinfo()); \
              end;'; \
    rm -rf "~/.julia/registries/General"

ADD . /pljulia

ENV USE_PGXS=1

RUN set -eux; \
    cd /pljulia \
        && make clean \
        && make \
        && make install

ARG PLJULIA_REGRESSION=YES
ENV PLJULIA_REGRESSION=${PLJULIA_REGRESSION}

RUN set -eux; \
    if [ "$PLJULIA_REGRESSION" = "YES" ]; then \
           cd /pljulia \
        && mkdir /tempdb \
        && chown -R postgres:postgres /tempdb \
        && su postgres -c 'pg_ctl -D /tempdb init' \
        && su postgres -c 'pg_ctl -D /tempdb start' \
        && make installcheck PGUSER=postgres \
        && su postgres -c 'pg_ctl -D /tempdb --mode=immediate stop' \
        && rm -rf /tempdb ; \
    fi