FROM node:20-alpine
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev
COPY server.js ./
EXPOSE 8787
ENV PORT=8787
CMD ["node", "server.js"]
