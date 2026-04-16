"""
Configuration management router.
"""
from fastapi import APIRouter, HTTPException
from typing import Dict, Any
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from models import ConfigUpdate, EnvUpdate, AuthReset, SuccessResponse
from services import ScriptService

router = APIRouter(prefix="/config", tags=["config"])

# Paths
CONFIG_PATH = '/app/config/config.json'
ENV_PATH = '/app/config/.env'

script_service = ScriptService()


@router.get("")
async def get_config():
    """Get current config.json."""
    try:
        if not os.path.exists(CONFIG_PATH):
            raise HTTPException(status_code=404, detail="config.json not found")
        
        with open(CONFIG_PATH, 'r') as f:
            config = json.load(f)
        return config
    except json.JSONDecodeError:
        raise HTTPException(status_code=500, detail="Invalid JSON in config.json")
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.put("", response_model=SuccessResponse)
async def update_config(update: ConfigUpdate):
    """Update config.json."""
    try:
        # Validate JSON
        config = update.config
        
        # Write to file (atomic write via temp file)
        temp_path = CONFIG_PATH + '.tmp'
        with open(temp_path, 'w') as f:
            json.dump(config, f, indent=2)
        
        os.rename(temp_path, CONFIG_PATH)
        
        return SuccessResponse(message="Config updated successfully")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/env")
async def get_env():
    """Get current .env values."""
    try:
        if not os.path.exists(ENV_PATH):
            return {"variables": {}, "exists": False}
        
        env_vars = {}
        with open(ENV_PATH, 'r') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    key, value = line.split('=', 1)
                    env_vars[key.strip()] = value.strip()
        
        return {"variables": env_vars, "exists": True}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.put("/env", response_model=SuccessResponse)
async def update_env(update: EnvUpdate):
    """Update .env file."""
    try:
        # Read existing .env if it exists
        existing = {}
        if os.path.exists(ENV_PATH):
            with open(ENV_PATH, 'r') as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith('#') and '=' in line:
                        key, value = line.split('=', 1)
                        existing[key.strip()] = value.strip()
        
        # Merge with updates
        existing.update(update.env)
        
        # Write back
        with open(ENV_PATH, 'w') as f:
            for key, value in existing.items():
                f.write(f"{key}={value}\n")
        
        return SuccessResponse(message=".env updated successfully")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/reload", response_model=SuccessResponse)
async def reload_config():
    """Trigger config reload (for agents that support hot reload)."""
    try:
        # The OpenClaw agent watches config.json for changes
        # Just touching the file triggers a reload
        os.utime(CONFIG_PATH, None)
        return SuccessResponse(message="Config reload triggered")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/keys", response_model=SuccessResponse)
async def init_keys():
    """Initialize SSH keys."""
    try:
        result = script_service.init_ssh_keys()
        if result['success']:
            return SuccessResponse(message="SSH keys initialized")
        else:
            raise HTTPException(status_code=500, detail=result['stderr'])
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/auth")
async def get_auth_status():
    """Get authentication status."""
    return script_service.check_auth_status()


@router.post("/auth/reset", response_model=SuccessResponse)
async def reset_auth(body: AuthReset):
    """Reset dashboard password."""
    try:
        result = script_service.reset_auth(body.password)
        if result['success']:
            return SuccessResponse(message="Password reset successfully")
        else:
            raise HTTPException(status_code=500, detail=result['stderr'])
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/schema")
async def get_config_schema():
    """Get the config.json schema for the editor."""
    return {
        "type": "object",
        "properties": {
            "allowed_domains": {
                "type": "array",
                "items": {"type": "string"},
                "description": "List of domains the agent can access"
            },
            "ssh_hosts": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "name": {"type": "string", "description": "Host name identifier"},
                        "hostname": {"type": "string", "description": "IP address or hostname"},
                        "port": {"type": "integer", "default": 22, "description": "SSH port"},
                        "user": {"type": "string", "description": "SSH user"},
                        "strict_host_key_checking": {"type": "boolean", "default": true},
                        "isolation": {"type": "string", "enum": ["chroot", "restricted_key"], "default": "chroot"},
                        "chroot_egress_filter": {"type": "boolean", "default": true},
                        "docker_access": {"type": "boolean", "default": false},
                        "project_paths": {"type": "array", "items": {"type": "string"}},
                        "forward_ports": {"type": "array", "items": {"type": "integer"}}
                    },
                    "required": ["name", "hostname", "port", "user"]
                }
            }
        }
    }