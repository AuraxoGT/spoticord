# syntax=docker/dockerfile:1.6
ARG RUST_VERSION=1.80.1
ARG PG_VERSION=16.4
ARG CACHE_NAMESPACE=spoticord

# --- Build Stage ---
FROM --platform=linux/amd64 rust:${RUST_VERSION}-slim AS builder
ARG CACHE_NAMESPACE
ARG PG_VERSION
ARG RUST_VERSION

WORKDIR /app

# System dependencies
RUN apt-get update && apt-get install -yqq \
    cmake \
    gcc-aarch64-linux-gnu \
    binutils-aarch64-linux-gnu \
    libpq-dev \
    curl \
    bzip2 \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Environment configuration
ENV PGVER=${PG_VERSION} \
    RUST_BACKTRACE=1 \
    CARGO_NET_GIT_FETCH_WITH_CLI=true \
    CARGO_HOME=/usr/local/cargo

# Build PostgreSQL libpq
RUN curl -L -o postgresql.tar.bz2 https://ftp.postgresql.org/pub/source/v${PGVER}/postgresql-${PGVER}.tar.bz2 \
    && tar xjf postgresql.tar.bz2 \
    && cd postgresql-${PGVER} \
    && ./configure \
        --host=aarch64-linux-gnu \
        --enable-shared \
        --disable-static \
        --without-readline \
        --without-zlib \
        --without-icu \
    && cd src/interfaces/libpq \
    && make

# Cross-compilation setup
RUN rustup target add x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu

# Copy source files
COPY . .

# Improved cache mounting with explicit prefixing
RUN --mount=type=cache,sharing=locked,id=cache:${CACHE_NAMESPACE}-cargo-registry-v${RUST_VERSION},target=/usr/local/cargo/registry \
    --mount=type=cache,sharing=locked,id=cache:${CACHE_NAMESPACE}-rust-target-v${RUST_VERSION},target=/app/target \
    set -eux; \
    # x86_64 build
    cargo build --release --target=x86_64-unknown-linux-gnu; \
    # ARM64 build
    RUSTFLAGS="-L /app/postgresql-${PGVER}/src/interfaces/libpq -C linker=aarch64-linux-gnu-gcc" \
    cargo build --release --target=aarch64-unknown-linux-gnu; \
    # Prepare artifacts
    cp target/x86_64-unknown-linux-gnu/release/spoticord /app/x86_64; \
    cp target/aarch64-unknown-linux-gnu/release/spoticord /app/aarch64

# --- Runtime Stage ---
FROM debian:bookworm-slim AS runtime
ARG TARGETPLATFORM

# Runtime dependencies
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        libpq-dev \
        libssl3 \
        curl \
    && rm -rf /var/lib/apt/lists/*

# Binary selection
COPY --from=builder /app/x86_64 /tmp/x86_64
COPY --from=builder /app/aarch64 /tmp/aarch64

RUN set -eux; \
    case "${TARGETPLATFORM}" in \
        "linux/amd64") mv /tmp/x86_64 /usr/local/bin/spoticord ;; \
        "linux/arm64") mv /tmp/aarch64 /usr/local/bin/spoticord ;; \
        *) echo "Unsupported platform: ${TARGETPLATFORM}"; exit 1 ;; \
    esac; \
    chmod +x /usr/local/bin/spoticord; \
    rm -rf /tmp/x86_64 /tmp/aarch64

# Runtime configuration
EXPOSE 8080
ENV PORT=8080 \
    DATABASE_URL="postgresql://mielamalonu_user:mDli5LNTbUK2BEYYR94TiWi2uwO7i0zT@dpg-cvgrtaogph6c73d9kuq0-a/mielamalonu"

HEALTHCHECK --interval=30s --timeout=30s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:${PORT}/health || exit 1

USER nobody:65534
ENTRYPOINT ["/usr/local/bin/spoticord"]
