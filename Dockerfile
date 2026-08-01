# Stage 1: Build Rust backend
FROM rust:1.97-slim-bookworm AS backend-builder
WORKDIR /app/backend

RUN apt-get update && apt-get install -y --no-install-recommends \
    libssl-dev \
    pkg-config \
    libgit2-dev \
    cmake \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY backend/Cargo.toml backend/Cargo.lock* ./
COPY backend/src ./src
RUN cargo build --release

# Stage 2: Build SvelteKit frontend with Bun
FROM oven/bun:1.3.11 AS frontend-builder
WORKDIR /app/frontend

COPY frontend/package.json frontend/bun.lock ./
RUN bun install --frozen-lockfile

COPY frontend/ .
RUN bun run build

# Stage 3: Runtime image
FROM debian:bookworm-slim AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends \
    libgit2-1.5 \
    ca-certificates \
    git \
    && rm -rf /var/lib/apt/lists/*

ARG APP_USER=githree
ARG APP_UID=10001
ARG APP_GID=10001

COPY --from=backend-builder /app/backend/target/release/githree /usr/local/bin/githree
COPY --from=frontend-builder /app/frontend/build /app/static
COPY config/ /app/config/

RUN groupadd --gid "${APP_GID}" "${APP_USER}" \
    && useradd --uid "${APP_UID}" --gid "${APP_GID}" --create-home --home-dir "/home/${APP_USER}" --shell /usr/sbin/nologin "${APP_USER}" \
    && mkdir -p /app/data \
    && chown -R "${APP_UID}:${APP_GID}" /app \
    && chown "${APP_UID}:${APP_GID}" /usr/local/bin/githree

WORKDIR /app
VOLUME ["/app/data"]
EXPOSE 3001
ENV RUST_LOG=info

USER ${APP_UID}:${APP_GID}
CMD ["githree"]
