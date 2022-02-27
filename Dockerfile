FROM node:22.21.1-bookworm-slim

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

COPY . .
# Compile at build time so solc is downloaded once, into the image.
RUN npx hardhat build

EXPOSE 8545
CMD ["npx", "hardhat", "node", "--hostname", "0.0.0.0", "--port", "8545"]
ENV VALIDATE_SCHEMA=true
ENV ROTATE_SECRET=true
ENV LOAD_CONFIG=true
ENV VALIDATE_SCHEMA=true