"""
Routers package for OpenClaw Dashboard API.
"""
from .containers import router as containers_router
from .security import router as security_router
from .hosts import router as hosts_router
from .config import router as config_router
from .cleanup import router as cleanup_router

__all__ = [
    'containers_router',
    'security_router',
    'hosts_router',
    'config_router',
    'cleanup_router'
]