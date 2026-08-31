# syntax=docker/dockerfile:1

FROM node:22-bookworm-slim

ARG BRIAN_REPO=https://github.com/use-brian/use-brian.git
ARG BRIAN_REF=main
ARG NEXT_PUBLIC_API_URL
ARG NEXT_PUBLIC_DOC_SYNC_URL
ARG NEXT_PUBLIC_USEBRIAN_EDITION=oss

ENV NEXT_PUBLIC_API_URL=${NEXT_PUBLIC_API_URL} \
    NEXT_PUBLIC_DOC_SYNC_URL=${NEXT_PUBLIC_DOC_SYNC_URL} \
    NEXT_PUBLIC_USEBRIAN_EDITION=${NEXT_PUBLIC_USEBRIAN_EDITION} \
    API_URL=${NEXT_PUBLIC_API_URL}

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    ffmpeg \
    fonts-dejavu-core \
    g++ \
    git \
    libreoffice-calc \
    libreoffice-impress \
    libreoffice-writer \
    make \
    python3 \
  && rm -rf /var/lib/apt/lists/* \
  && corepack enable \
  && corepack prepare pnpm@10.33.0 --activate

WORKDIR /app

# Fetch a branch, tag, or reachable commit without carrying credentials from the
# host into the image.
RUN git init \
  && git remote add origin "${BRIAN_REPO}" \
  && git fetch --depth 1 origin "${BRIAN_REF}" \
  && git checkout --detach FETCH_HEAD

RUN pnpm install --frozen-lockfile \
  && pnpm --filter "@use-brian/api-open..." --filter "app-web..." run build

RUN install -d -o node -g node /data /data/files \
  && chown -R node:node /app/apps/app-web/.next

ENV HOME=/data \
    NODE_ENV=production

USER node

EXPOSE 3003 4000
