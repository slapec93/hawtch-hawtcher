# Both probes ship in one image; the compose service picks the entrypoint.
# They share config parsing, postage handling and the run loop, so splitting them
# into separate images would duplicate the build for no gain.

FROM node:22-alpine AS build
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
RUN npm run build

FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production
COPY package.json package-lock.json* ./
RUN npm ci --omit=dev && npm cache clean --force
COPY --from=build /app/dist ./dist

# Run unprivileged. The probes need no filesystem access beyond their own code.
USER node

# Overridden per service: `node dist/latency.js` or `node dist/beefeeder.js`.
CMD ["node", "dist/latency.js"]
