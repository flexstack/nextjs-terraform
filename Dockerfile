# The VERSION arg is used to specify the version of Node.js to use. You can change
# this at build time by passing the --build-arg flag to the docker build command.
ARG VERSION=lts
FROM node:${VERSION}-slim AS base
# Enables pnpm and yarn
RUN corepack enable
# Install Bun if a lockfile is present
WORKDIR /app
COPY bun.lockb* ./
RUN if [ -f bun.lockb ]; then npm install -g bun; fi

# Install the necessary dependencies for the application. This is done in a separate
# stage so that the dependencies are cached and not re-installed on every build.
FROM base AS build-deps
WORKDIR /app
COPY package.json yarn.lock* package-lock.json* pnpm-lock.yaml* bun.lockb* ./

# Set the NPM_MIRROR build argument to use a custom npm registry mirror.
ARG NPM_MIRROR=
RUN if [ ! -z "${NPM_MIRROR}" ]; then npm config set registry ${NPM_MIRROR}; fi
RUN if [ -f yarn.lock ]; then yarn --frozen-lockfile; \
  elif [ -f package-lock.json ]; then npm ci; \
  elif [ -f pnpm-lock.yaml ]; then pnpm i --frozen-lockfile; \
  elif [ -f bun.lockb ]; then bun install; \
  else echo "Lockfile not found." && exit 1; \
  fi


# Runtime dependencies are installed in a separate stage so that development
# dependencies are not included in the final image. This reduces the size of the
# final image.
FROM base AS runtime-deps
WORKDIR /app
COPY package.json yarn.lock* package-lock.json* pnpm-lock.yaml* bun.lockb* ./

ARG NPM_MIRROR=
RUN if [ ! -z "${NPM_MIRROR}" ]; then npm config set registry ${NPM_MIRROR}; fi
RUN if [ -f yarn.lock ]; then yarn --frozen-lockfile --production; \
  elif [ -f package-lock.json ]; then npm ci --only=production; \
  elif [ -f pnpm-lock.yaml ]; then pnpm i --frozen-lockfile --prod; \
  elif [ -f bun.lockb ]; then bun install --production; \
  else echo "Lockfile not found." && exit 1; \
  fi


# This is the final stage of the build process. It copies the application code
# and builds the application.
FROM base AS builder

ENV NODE_ENV=production
WORKDIR /app
COPY . .
RUN rm -rf node_modules
COPY --from=build-deps /app/node_modules ./node_modules
RUN if [ -f yarn.lock ]; then yarn run build; \
  elif [ -f package-lock.json ]; then npm run build; \
  elif [ -f bun.lockb ]; then bun run build; \
  elif [ -f pnpm-lock.yaml ]; then pnpm run build; \
  elif [ -f bun.lockb ]; then bun run build; \
  else echo "Lockfile not found." && exit 1; \
  fi


# This stage creates the final image that will be used in production. It copies
# the application code and the runtime dependencies from the previous stages.
# Then it sets the user to run the application and the command to start the
# application.
FROM base AS runtime
WORKDIR /app

# Install wget to allow health checks on the container. Then clean up the apt cache to reduce the image size. 
# e.g. `wget -nv -t1 --spider 'http://localhost:8080/health' || exit 1`
RUN apt-get update && apt-get install -y --no-install-recommends wget ca-certificates && apt-get clean && rm -f /var/lib/apt/lists/*_*
RUN update-ca-certificates 2>/dev/null || true
RUN addgroup --system nonroot && adduser --system --ingroup nonroot nonroot
RUN chown -R nonroot:nonroot /app

# Copy the application code and the runtime dependencies from the previous stage.
COPY --from=builder --chown=nonroot:nonroot /app/next.config.* ./
COPY --from=builder --chown=nonroot:nonroot /app/public ./public
COPY --from=builder --chown=nonroot:nonroot /app/.next ./.next
COPY --from=runtime-deps --chown=nonroot:nonroot /app/node_modules ./node_modules

USER nonroot:nonroot

# Set the port that the application will run on
ENV PORT=3000
# Expose the port that the application will run on
EXPOSE ${PORT}
ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1

CMD ["node_modules/.bin/next", "start", "-H", "0.0.0.0"]