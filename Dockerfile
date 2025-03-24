# Build Stage
FROM --platform=linux/amd64 rust:1.80.1-slim AS builder

WORKDIR /app

# Install build dependencies
RUN apt-get update && apt-get install -yqq \
    cmake gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu libpq-dev curl bzip2

# Manually compile an arm64 build of libpq
ENV PGVER=16.4
RUN curl -o postgresql.tar.bz2 https://ftp.postgresql.org/pub/source/v${PGVER}/postgresql-${PGVER}.tar.bz2 && \
    tar xjf postgresql.tar.bz2 && \
    cd postgresql-${PGVER} && \
    ./configure --host=aarch64-linux-gnu --enable-shared --disable-static --without-readline --without-zlib --without-icu && \
    cd src/interfaces/libpq && \
    make

# Add Rust targets for cross-compilation
RUN rustup target add x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu

# Copy the source code
COPY . .

# Build the application for both targets (amd64 and arm64)
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/app/target \
    cargo build --release --target=x86_64-unknown-linux-gnu && \
    RUSTFLAGS="-L /app/postgresql-${PGVER}/src/interfaces/libpq -C linker=aarch64-linux-gnu-gcc" cargo build --release --target=aarch64-unknown-linux-gnu && \
    # Copy the executables outside of /target as it'll get unmounted after this RUN command
    cp /app/target/x86_64-unknown-linux-gnu/release/spoticord /app/x86_64 && \
    cp /app/target/aarch64-unknown-linux-gnu/release/spoticord /app/aarch64

# Runtime Stage
FROM debian:bookworm-slim

ARG TARGETPLATFORM
ENV TARGETPLATFORM=${TARGETPLATFORM}

# Install runtime dependencies (libpq-dev for PostgreSQL support)
RUN apt-get update && apt-get install -y ca-certificates libpq-dev

# Copy the built binaries from the builder stage
COPY --from=builder /app/x86_64 /tmp/x86_64
COPY --from=builder /app/aarch64 /tmp/aarch64

# Select the appropriate binary based on the target architecture
RUN if [ "${TARGETPLATFORM}" = "linux/amd64" ]; then \
    cp /tmp/x86_64 /usr/local/bin/spoticord; \
    elif [ "${TARGETPLATFORM}" = "linux/arm64" ]; then \
    cp /tmp/aarch64 /usr/local/bin/spoticord; \
    fi

# Clean up unnecessary binaries
RUN rm -rvf /tmp/x86_64 /tmp/aarch64

# Expose the application port (assuming the app listens on port 8080)
EXPOSE 8080

# Set the entrypoint for the container
ENTRYPOINT ["/usr/local/bin/spoticord"]

# Optional: Add environment variables for the database URL (adjust this based on how your app reads it)
ENV DATABASE_URL="postgresql://<username>:<password>@<host>:<port>/spoticord"

