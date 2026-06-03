FROM node:20-slim
WORKDIR /app
# better-sqlite3 precisa de toolchain para compilar o binario nativo
RUN apt-get update && apt-get install -y --no-install-recommends python3 make g++ && rm -rf /var/lib/apt/lists/*
COPY package.json ./
RUN npm install --omit=dev
COPY . .
EXPOSE 3000
CMD ["node", "src/server.js"]
