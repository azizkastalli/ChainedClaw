"""
OpenClaw Dashboard API - Main Application

This FastAPI application provides a REST API for managing the OpenClaw
infrastructure, including containers, security, SSH hosts, and configuration.
"""
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from contextlib import asynccontextmanager
import uvicorn
import os
import time

from routers import (
    containers_router,
    security_router,
    hosts_router,
    config_router,
    cleanup_router
)
from services import StatusService


# Lifespan context manager for startup/shutdown
@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup
    print("OpenClaw Dashboard API starting...")
    yield
    # Shutdown
    print("OpenClaw Dashboard API shutting down...")


# Create FastAPI app
app = FastAPI(
    title="OpenClaw Dashboard API",
    description="API for managing OpenClaw infrastructure",
    version="1.0.0",
    lifespan=lifespan
)

# Configure CORS for frontend access — origins can be overridden via CORS_ORIGINS env var
_cors_origins_raw = os.getenv(
    "CORS_ORIGINS",
    "http://localhost:8090,http://127.0.0.1:8090,"
    "http://localhost:18789,http://127.0.0.1:18789,"
    "http://localhost:18790,http://127.0.0.1:18790"
)
_cors_origins = [o.strip() for o in _cors_origins_raw.split(",") if o.strip()]

app.add_middleware(
    CORSMiddleware,
    allow_origins=_cors_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# TTL cache for the status endpoint (8 s avoids hammering subprocesses on every poll)
_status_cache: dict = {}
_STATUS_TTL = 8  # seconds

# Include routers
app.include_router(containers_router, prefix="/api")
app.include_router(security_router, prefix="/api")
app.include_router(hosts_router, prefix="/api")
app.include_router(config_router, prefix="/api")
app.include_router(cleanup_router, prefix="/api")


# Root endpoint
@app.get("/")
async def root():
    """API root endpoint."""
    return {
        "name": "OpenClaw Dashboard API",
        "version": "1.0.0",
        "status": "running"
    }


# Health check endpoint
@app.get("/health")
async def health():
    """Health check endpoint."""
    return {"status": "healthy"}


# Overall status endpoint
@app.get("/api/status")
async def get_overall_status():
    """Get overall infrastructure status with TTL caching and parallel SSH checks."""
    now = time.monotonic()
    if _status_cache.get('ts', 0) + _STATUS_TTL > now:
        return _status_cache['data']

    status_service = StatusService()
    try:
        data = await status_service.get_overall_status_async()
        _status_cache.update({'ts': now, 'data': data})
        return data
    except Exception as e:
        return {
            "security": "unknown",
            "containers_running": False,
            "hosts_total": 0,
            "hosts_connected": 0,
            "warnings": [str(e)],
            "issues": ["Failed to get status"]
        }


if __name__ == "__main__":
    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=18790,
        reload=True
    )