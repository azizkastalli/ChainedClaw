"""
SSH hosts management router.
"""
from fastapi import APIRouter, HTTPException
from typing import List
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from models import SSHHost, SSHHostStatus, SSHHostSetup, RemoteSetup, SuccessResponse
from services import StatusService, ScriptService

router = APIRouter(prefix="/hosts", tags=["hosts"])

status_service = StatusService()
script_service = ScriptService()


@router.get("", response_model=List[dict])
async def list_hosts():
    """List all SSH hosts from config."""
    try:
        hosts = status_service.get_ssh_hosts()
        return hosts
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/status", response_model=List[SSHHostStatus])
async def get_hosts_status():
    """Get status for all configured hosts."""
    try:
        hosts = status_service.get_all_hosts_status()
        return [SSHHostStatus(**h) for h in hosts]
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/{name}/status", response_model=SSHHostStatus)
async def get_host_status(name: str):
    """Get status for a specific host."""
    try:
        hosts = status_service.get_ssh_hosts()
        host_config = next((h for h in hosts if h.get('name') == name), None)
        if not host_config:
            raise HTTPException(status_code=404, detail=f"Host {name} not found in config")
        
        status = status_service.get_host_status(host_config)
        return SSHHostStatus(**status)
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/{name}/test")
async def test_host_connection(name: str):
    """Test SSH connection to a host."""
    try:
        result = status_service.test_ssh_connection(name)
        return {
            "host": name,
            "connected": result['connected'],
            "message": result['message']
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/{name}/setup", response_model=SuccessResponse)
async def setup_host(name: str):
    """Full host setup: chroot + SSH key."""
    try:
        result = script_service.full_host_setup(name)
        if result['success']:
            return SuccessResponse(message=result['message'])
        else:
            raise HTTPException(status_code=500, detail=result.get('message', 'Setup failed'))
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/{name}/chroot", response_model=SuccessResponse)
async def setup_chroot(name: str):
    """Set up chroot jail for a host."""
    try:
        result = script_service.setup_chroot(name)
        if result['success']:
            return SuccessResponse(message=f"Chroot created for {name}")
        else:
            raise HTTPException(status_code=500, detail=result['stderr'])
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.delete("/{name}/chroot", response_model=SuccessResponse)
async def remove_chroot(name: str):
    """Remove chroot jail for a host."""
    try:
        result = script_service.remove_chroot(name)
        if result['success']:
            return SuccessResponse(message=f"Chroot removed for {name}")
        else:
            raise HTTPException(status_code=500, detail=result['stderr'])
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/{name}/key", response_model=SuccessResponse)
async def install_key(name: str):
    """Install SSH key for a host."""
    try:
        result = script_service.add_ssh_key(name)
        if result['success']:
            return SuccessResponse(message=f"SSH key installed for {name}")
        else:
            raise HTTPException(status_code=500, detail=result['stderr'])
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.delete("/{name}/key", response_model=SuccessResponse)
async def remove_key(name: str):
    """Remove SSH key for a host."""
    try:
        result = script_service.remove_ssh_key(name)
        if result['success']:
            return SuccessResponse(message=f"SSH key removed for {name}")
        else:
            raise HTTPException(status_code=500, detail=result['stderr'])
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/{name}/remote-setup", response_model=SuccessResponse)
async def setup_remote_host(name: str, setup: RemoteSetup):
    """Set up chroot on a remote host."""
    try:
        result = script_service.setup_remote_host(
            name, 
            setup.remote_key, 
            setup.remote_user
        )
        if result['success']:
            return SuccessResponse(message=f"Remote setup completed for {name}")
        else:
            raise HTTPException(status_code=500, detail=result['stderr'])
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/{name}/remote-clean", response_model=SuccessResponse)
async def cleanup_remote_host(name: str, setup: RemoteSetup):
    """Clean up chroot on a remote host."""
    try:
        result = script_service.cleanup_remote_host(
            name, 
            setup.remote_key, 
            setup.remote_user
        )
        if result['success']:
            return SuccessResponse(message=f"Remote cleanup completed for {name}")
        else:
            raise HTTPException(status_code=500, detail=result['stderr'])
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))