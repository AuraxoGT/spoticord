# Build Stage
FROM --platform=linux/amd64 rust:1.80.1-slim AS builder
WORKDIR /app

# Install build dependencies
RUN apt-get update && apt-get install -yqq \
    cmake gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu \
    libpq-dev curl bzip2 pkg-config libssl-dev

# Set up environment variables for cross-compilation
ENV PGVER=16.4 \
    RUST_BACKTRACE=1 \
    CARGO_NET_GIT_FETCH_WITH_CLI=true

# Download and compile PostgreSQL for cross-platform support
RUN curl -o postgresql.tar.bz2 https://ftp.postgresql.org/pub/source/v${PGVER}/postgresql-${PGVER}.tar.bz2 && \
    tar xjf postgresql.tar.bz2 && \
    cd postgresql-${PGVER} && \
    ./configure --host=aarch64-linux-gnu --enable-shared --disable-static \
    --without-readline --without-zlib --without-icu && \
    cd src/interfaces/libpq && \
    make

# Add Rust targets for cross-compilation
RUN rustup target add x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu

# Copy project files
COPY . .

# Cache dependencies and build the application
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/app/target \
    cargo build --release --target=x86_64-unknown-linux-gnu && \
    RUSTFLAGS="-L /app/postgresql-${PGVER}/src/interfaces/libpq -C linker=aarch64-linux-gnu-gcc" \
    cargo build --release --target=aarch64-unknown-linux-gnu && \
    cp /app/target/x86_64-unknown-linux-gnu/release/spoticord /app/x86_64 && \
    cp /app/target/aarch64-unknown-linux-gnu/release/spoticord /app/aarch64

# Runtime Stage
FROM debian:bookworm-slim AS runtime
ARG TARGETPLATFORM
ENV TARGETPLATFORM=${TARGETPLATFORM}

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    ca-certificates libpq-dev libssl3 && \
    rm -rf /var/lib/apt/lists/*

# Copy built binaries
COPY --from=builder /app/x86_64 /tmp/x86_64
COPY --from=builder /app/aarch64 /tmp/aarch64

# Select appropriate binary based on target platform
RUN set -eux; \
    case "${TARGETPLATFORM}" in \
      "linux/amd64") \
        cp /tmp/x86_64 /usr/local/bin/spoticord; \
        ;; \
      "linux/arm64") \
        cp /tmp/aarch64 /usr/local/bin/spoticord; \
        ;; \
      *) \
        echo "Unsupported platform: ${TARGETPLATFORM}"; \
        exit 1; \
        ;; \
    esac; \
    chmod +x /usr/local/bin/spoticord; \
    rm -rf /tmp/x86_64 /tmp/aarch64

# Set default environment variables
ENV PORT=8080 \
    DATABASE_URL="postgresql://mielamalonu_user:mDli5LNTbUK2BEYYR94TiWi2uwO7i0zT@dpg-cvgrtaogph6c73d9kuq0-a/mielamalonu"

# Expose the application port
EXPOSE ${PORT}

# Add healthcheck
HEALTHCHECK --interval=30s --timeout=30s --start-period=5s --retries=3 \
  CMD curl -f http://localhost:${PORT}/health || exit 1

# Run the application
USER nobody
ENTRYPOINT ["/usr/local/bin/spoticord"]
