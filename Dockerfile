# syntax=docker/dockerfile:1.4
ARG RUST_VERSION=1.80.1

# --- Build Stage ---
FROM rust:${RUST_VERSION}-slim AS builder

WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -yqq \
    pkg-config \
    libssl-dev \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Copy source files
COPY . .

# Build the application
RUN cargo build --release

# --- Runtime Stage ---
FROM debian:bookworm-slim

# Runtime dependencies
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        libssl3 \
        libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy the built binary
COPY --from=builder /app/target/release/spoticord /usr/local/bin/spoticord

# Runtime configuration
EXPOSE 8080

ENV PORT=8080

# Make the binary executable
RUN chmod +x /usr/local/bin/spoticord

# Default healthcheck (modify as needed)
HEALTHCHECK --interval=30s --timeout=30s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:${PORT}/health || exit 1

# Run the application
CMD ["/usr/local/bin/spoticord"]
