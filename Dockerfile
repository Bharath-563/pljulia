FROM postgres:14

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       build-essential \
       ca-certificates \
       curl \
       patchelf \
       postgresql-server-dev-14 \
    && apt-get clean -y \
    && rm -rf /var/lib/apt/lists/* /tmp/*

# Julia Versions:
ARG JULIA_MAJOR=1.10
ARG JULIA_VERSION=1.10.10
ARG JULIA_SHA256=6a78a03a71c7ab792e8673dc5cedb918e037f081ceb58b50971dfb7c64c5bf81
ARG PLJULIA_PACKAGES="CpuId,Primes"

# Install Julia
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
    && cd /tmp  \
    && curl -fL -o julia.tar.gz https://julialang-s3.julialang.org/bin/linux/x64/${JULIA_MAJOR}/julia-${JULIA_VERSION}-linux-x86_64.tar.gz \
    && echo "$JULIA_SHA256 *julia.tar.gz" | sha256sum -c - \
    && tar xzf julia.tar.gz -C ${JULIA_DIR} --strip-components=1 \
    && rm /tmp/julia.tar.gz \
    && ln -fs ${JULIA_DIR}/bin/julia /usr/local/bin/julia \
    && patchelf --clear-execstack ${JULIA_DIR}/lib/julia/libopenlibm.so

# Add julia packages from ENV["PLJULIA_PACKAGES"]
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
    fi

ENV PLJULIA_REGRESSION=YES

COPY . /pljulia
WORKDIR /pljulia

RUN make USE_PGXS=1 && make USE_PGXS=1 install