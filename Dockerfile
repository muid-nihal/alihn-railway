# Build openclaw from source to avoid npm packaging gaps (some dist files are not shipped).
FROM node:22-bookworm AS openclaw-build

# Dependencies needed for openclaw build
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    curl \
    python3 \
    make \
    g++ \
  && rm -rf /var/lib/apt/lists/*

# Install Bun (openclaw build uses it)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

RUN corepack enable

WORKDIR /openclaw

# Pin to a known-good ref (tag/branch). Override in Railway template settings if needed.
# Using a released tag avoids build breakage when `main` temporarily references unpublished packages.
ARG OPENCLAW_GIT_REF=v2026.4.15
RUN git clone --depth 1 --branch "${OPENCLAW_GIT_REF}" https://github.com/openclaw/openclaw.git .

# Patch: relax version requirements for packages that may reference unpublished versions.
# Apply to all extension package.json files to handle workspace protocol (workspace:*).
RUN set -eux; \
  find ./extensions -name 'package.json' -type f | while read -r f; do \
    sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*">=[^"]+"/"openclaw": "*"/g' "$f"; \
    sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*"workspace:[^"]+"/"openclaw": "*"/g' "$f"; \
  done

RUN pnpm install --no-frozen-lockfile
RUN pnpm build
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:install && pnpm ui:build


# Runtime image
FROM node:22-bookworm
ENV NODE_ENV=production

RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    tini \
    python3 \
    python3-venv \
  && rm -rf /var/lib/apt/lists/*

# `openclaw update` expects pnpm. Provide it in the runtime image.
RUN corepack enable && corepack prepare pnpm@10.23.0 --activate

# Persist user-installed tools by default by targeting the Railway volume.
# - npm global installs -> /data/npm
# - pnpm global installs -> /data/pnpm (binaries) + /data/pnpm-store (store)
ENV NPM_CONFIG_PREFIX=/data/npm
ENV NPM_CONFIG_CACHE=/data/npm-cache
ENV PNPM_HOME=/data/pnpm
ENV PNPM_STORE_DIR=/data/pnpm-store
ENV PATH="/data/npm/bin:/data/pnpm:${PATH}"

WORKDIR /app

# Wrapper deps
COPY package.json ./
RUN npm install --omit=dev && npm cache clean --force

# Copy built openclaw
COPY --from=openclaw-build /openclaw /openclaw

# Provide an openclaw executable
RUN printf '%s\n' '#!/usr/bin/env bash' 'exec node /openclaw/dist/entry.js "$@"' > /usr/local/bin/openclaw \
  && chmod +x /usr/local/bin/openclaw

# --- Alihn branding overlay ---
# Replace favicons with Alihn star mark (light + dark variants)
COPY branding/favicon.svg /openclaw/dist/control-ui/favicon.svg
COPY branding/favicon-dark.svg /openclaw/dist/control-ui/favicon-dark.svg
COPY branding/favicon-32.png /openclaw/dist/control-ui/favicon-32.png
COPY branding/favicon-32-dark.png /openclaw/dist/control-ui/favicon-32-dark.png
COPY branding/favicon.ico /openclaw/dist/control-ui/favicon.ico
COPY branding/apple-touch-icon.png /openclaw/dist/control-ui/apple-touch-icon.png

# Neutralize red accent colors across the entire UI (JS + CSS)
# Tailwind reds (ef4444/dc2626) + custom reds (ff5c5c/c41e30/e5243b/ff4d4d/991b1b) -> near-black
RUN find /openclaw/dist/control-ui/assets -type f \( -name 'index-*.js' -o -name 'index-*.css' \) -exec sed -i \
      -e 's/#ef4444/#111111/g' \
      -e 's/#dc2626/#000000/g' \
      -e 's/#ff5c5c/#222222/g' \
      -e 's/#c41e30/#000000/g' \
      -e 's/#e5243b/#000000/g' \
      -e 's/#ff4d4d/#111111/g' \
      -e 's/#991b1b/#000000/g' {} +

# Rebrand HTML page title + add dark-mode favicon link
RUN sed -i \
      -e 's|<title>OpenClaw Control</title>|<title>Alihn</title>|g' \
      -e 's|<link rel="icon" type="image/svg+xml" href="./favicon.svg" />|<link rel="icon" type="image/svg+xml" href="./favicon.svg" media="(prefers-color-scheme: light)" />\n    <link rel="icon" type="image/svg+xml" href="./favicon-dark.svg" media="(prefers-color-scheme: dark)" />|g' \
      -e 's|<link rel="icon" type="image/png" sizes="32x32" href="./favicon-32.png" />|<link rel="icon" type="image/png" sizes="32x32" href="./favicon-32.png" media="(prefers-color-scheme: light)" />\n    <link rel="icon" type="image/png" sizes="32x32" href="./favicon-32-dark.png" media="(prefers-color-scheme: dark)" />|g' \
      /openclaw/dist/control-ui/index.html

# Rebrand wordmark strings: OpenClaw -> Alihn (quoted in minified JS)
RUN find /openclaw/dist/control-ui/assets -name 'index-*.js' -type f -exec sed -i \
      -e 's|"OpenClaw"|"Alihn"|g' \
      -e "s|'OpenClaw'|'Alihn'|g" \
      -e 's|`OpenClaw`|`Alihn`|g' {} +
# --- end Alihn branding overlay ---

COPY src ./src

# The wrapper listens on $PORT.
# IMPORTANT: Do not set a default PORT here.
# Railway injects PORT at runtime and routes traffic to that port.
# If we force a different port, deployments can come up but the domain will route elsewhere.
EXPOSE 8080

# Ensure PID 1 reaps zombies and forwards signals.
ENTRYPOINT ["tini", "--"]
CMD ["node", "src/server.js"]
