# syntax=docker/dockerfile:1

# ------------------------------------------------------------------
# Dependency-caching build stage using cargo-chef
# ------------------------------------------------------------------
FROM rust:1-bookworm AS chef
WORKDIR /app
# Keep local/resource-constrained builds from spawning too many compiler jobs.
ENV CARGO_BUILD_JOBS=1
ENV CARGO_PROFILE_DEV_DEBUG=0
RUN cargo install cargo-chef --locked

# ------------------------------------------------------------------
# Planner: generate a recipe.json from the workspace manifests
# ------------------------------------------------------------------
FROM chef AS planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

# ------------------------------------------------------------------
# Builder: compile dependencies (cached layer) then the binaries
# ------------------------------------------------------------------
FROM chef AS builder

COPY --from=planner /app/recipe.json recipe.json
# Build & cache dependencies. This layer is invalidated only when
# Cargo.toml / Cargo.lock / recipe.json change.
RUN cargo chef cook --recipe-path recipe.json

# Copy full source tree and build the Ursula server binary.
# Local/resource-constrained builds use the default dev profile to avoid
# heavy release-mode compiler memory usage inside small Docker VMs.
COPY . .
RUN cargo build --bin ursula

# ------------------------------------------------------------------
# Runtime: minimal Debian image with CA certs and the Ursula server binary
# ------------------------------------------------------------------
FROM debian:bookworm-slim AS runtime
WORKDIR /app

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates \
  && rm -rf /var/lib/apt/lists/*

COPY --from=builder /app/target/debug/ursula /usr/local/bin/ursula

# Default HTTP port for the Ursula server
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/ursula"]
