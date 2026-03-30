# Multi-stage Dockerfile for Payment Command Center
#
# Stage 1: Build React frontend
# Stage 2: Python backend with embedded static assets

# ===========================================================================
# Stage 1 — Frontend build
# ===========================================================================
FROM node:18-alpine AS frontend-builder

WORKDIR /frontend

COPY frontend/package.json ./
RUN npm install --frozen-lockfile

COPY frontend/ ./
RUN npm run build

# ===========================================================================
# Stage 2 — Python backend runtime
# ===========================================================================
FROM python:3.11-slim AS runtime

WORKDIR /app

# Install backend dependencies
COPY backend/requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# Copy backend source
COPY backend/ ./

# Copy built frontend into static dir (served by FastAPI StaticFiles)
COPY --from=frontend-builder /frontend/dist ./frontend/dist

EXPOSE 8080

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
