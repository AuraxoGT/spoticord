# syntax=docker/dockerfile:1.4
# Enable BuildKit features (required for cache mounts)

# --- Build Stage ---
FROM --platform=linux/amd64 rust:1.80.1-slim AS builder
WORKDIR /app

# Install system dependencies
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

# Configure environment
ENV PGVER=16.4
ENV RUST_BACKTRACE=1
ENV CARGO_NET_GIT_FETCH_WITH_CLI=true  # Fixed typo (added missing 'T' in GIT)
ENV CARGO_HOME=/usr/local/cargo

# Build PostgreSQL libpq for ARM64
RUN curl -o postgresql.tar.bz2 https://ftp.postgresql.org/pub/source/v${PGVER}/postgresql-${PGVER}.tar.bz2 \
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

# Add cross-compilation targets
RUN rustup target add x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu

# Copy source files (with .dockerignore support)
COPY . .

# Build both architectures with cache optimization
RUN --mount=type=cache,id=cargo-registry,target=/usr/local/cargo/registry \
    --mount=type=cache,id=rust-build,target=/app/target \
    set -eux; \
    # Build x86_64
    cargo build --release --target=x86_64-unknown-linux-gnu; \
    # Build ARM64 with custom flags
    RUSTFLAGS="-L /app/postgresql-${PGVER}/src/interfaces/libpq -C linker=aarch64-linux-gnu-gcc" \
    cargo build --release --target=aarch64-unknown-linux-gnu; \
    # Prepare final binaries
    cp target/x86_64-unknown-linux-gnu/release/spoticord /app/x86_64; \
    cp target/aarch64-unknown-linux-gnu/release/spoticord /app/aarch64

# --- Runtime Stage ---
FROM debian:bookworm-slim AS runtime
ARG TARGETPLATFORM

# Install runtime dependencies
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        libpq-dev \
        libssl3 \
    && rm -rf /var/lib/apt/lists/*

# Copy appropriate binary
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

# Configure runtime
EXPOSE 8080
ENV PORT=8080 \
    DATABASE_URL="postgresql://mielamalonu_user:mDli5LNTbUK2BEYYR94TiWi2uwO7i0zT@dpg-cvgrtaogph6c73d9kuq0-a/mielamalonu"

HEALTHCHECK --interval=30s --timeout=30s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:${PORT}/health || exit 1

USER nobody
ENTRYPOINT ["/usr/local/bin/spoticord"]
