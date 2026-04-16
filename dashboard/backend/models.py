"""
Pydantic models for the OpenClaw Dashboard API.
"""
from typing import Optional, List, Dict, Any
from pydantic import BaseModel
from enum import Enum


class AgentType(str, Enum):
    OPENCLAW = "openclaw"
    CLAUDECODE = "claudecode"


class ContainerStatus(str, Enum):
    RUNNING = "running"
    STOPPED = "stopped"
    PAUSED = "paused"
    RESTARTING = "restarting"
    UNKNOWN = "unknown"


# Container Models
class ContainerInfo(BaseModel):
    name: str
    status: ContainerStatus
    image: str
    created: str
    ports: List[Dict[str, Any]] = []
    health: Optional[str] = None


class ContainerAction(BaseModel):
    agent: AgentType


class ContainerBuild(BaseModel):
    agent: AgentType


# Security Models
class SecurityLayerStatus(BaseModel):
    name: str
    status: str  # "ok", "fail", "warn"
    message: str
    details: Optional[str] = None


class SecurityStatus(BaseModel):
    seccomp: SecurityLayerStatus
    firewall: SecurityLayerStatus
    container: SecurityLayerStatus
    capabilities: SecurityLayerStatus
    overall: str  # "ok", "warn", "fail"


# SSH Host Models
class SSHHost(BaseModel):
    name: str
    hostname: str
    port: int
    user: str
    strict_host_key_checking: bool = True
    isolation: str = "chroot"
    chroot_egress_filter: bool = True
    docker_access: bool = False
    project_paths: List[str] = []
    forward_ports: List[int] = []


class SSHHostStatus(BaseModel):
    name: str
    hostname: str
    port: int
    connected: bool
    message: str
    chroot_exists: Optional[bool] = None
    key_installed: Optional[bool] = None


class SSHHostSetup(BaseModel):
    host: str


class SSHHostTest(BaseModel):
    host: str


class RemoteSetup(BaseModel):
    host: str
    remote_key: str
    remote_user: Optional[str] = None


# Config Models
class ConfigUpdate(BaseModel):
    config: Dict[str, Any]


class EnvUpdate(BaseModel):
    env: Dict[str, str]


class EnvInfo(BaseModel):
    key: str
    value: str
    description: Optional[str] = None


# Cleanup Models
class CleanupConfirm(BaseModel):
    confirm: str  # Must be "yes" to confirm


# Auth Models
class AuthStatus(BaseModel):
    htpasswd_exists: bool
    htpasswd_path: str


class AuthReset(BaseModel):
    password: str


# API Response Models
class SuccessResponse(BaseModel):
    success: bool = True
    message: str


class ErrorResponse(BaseModel):
    success: bool = False
    error: str
    details: Optional[str] = None


class LogsResponse(BaseModel):
    logs: str
    container: str