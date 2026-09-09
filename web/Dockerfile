FROM oven/bun:1.3 AS build
WORKDIR /app
COPY package.json bun.lock tsconfig.json build.ts ./
RUN bun install --frozen-lockfile
COPY src ./src
RUN bun run build.ts

FROM oven/bun:1.3-slim
WORKDIR /app
COPY --from=build /app/dist ./dist
ENV NODE_ENV=production
EXPOSE 3000
# bundled asset paths resolve relative to cwd, so run from dist/
WORKDIR /app/dist
CMD ["bun", "index.js"]
