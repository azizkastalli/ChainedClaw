"""
Container management router.
"""
from fastapi import APIRouter, HTTPException, WebSocket, WebSocketDisconnect
from typing import List
import sys
import os

# Add parent directory to path for imports
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from models import ContainerInfo, ContainerAction, ContainerBuild, SuccessResponse, ErrorResponse
from services import DockerService

router = APIRouter(prefix="/containers", tags=["containers"])

# Service instance
docker_service = DockerService()


@router.get("", response_model=List[ContainerInfo])
async def list_containers():
    """List all OpenClaw containers."""
    try:
        containers = docker_service.get_containers()
        return containers
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/{name}", response_model=ContainerInfo)
async def get_container(name: str):
    """Get a specific container by name."""
    container = docker_service.get_container(name)
    if not container:
        raise HTTPException(status_code=404, detail=f"Container {name} not found")
    return container


@router.post("/up", response_model=SuccessResponse)
async def start_containers(action: ContainerAction):
    """Start containers for an agent profile."""
    try:
        result = docker_service.start_containers(action.agent.value)
        return SuccessResponse(message=result['message'])
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/down", response_model=SuccessResponse)
async def stop_containers():
    """Stop all OpenClaw containers."""
    try:
        result = docker_service.stop_containers()
        return SuccessResponse(message=result['message'])
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/restart", response_model=SuccessResponse)
async def restart_containers(action: ContainerAction):
    """Restart containers for an agent profile."""
    try:
        result = docker_service.restart_containers(action.agent.value)
        return SuccessResponse(message=result['message'])
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/build", response_model=SuccessResponse)
async def build_image(action: ContainerBuild):
    """Build container image for an agent profile."""
    try:
        result = docker_service.build_image(action.agent.value)
        return SuccessResponse(message=result['message'])
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/{name}/logs")
async def get_logs(name: str, tail: int = 100):
    """Get container logs."""
    try:
        logs = docker_service.get_logs(name, tail)
        return {"logs": logs, "container": name}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.websocket("/{name}/logs/stream")
async def stream_logs(websocket: WebSocket, name: str):
    """Stream container logs via WebSocket."""
    await websocket.accept()
    try:
        for line in docker_service.stream_logs(name):
            await websocket.send_text(line)
    except WebSocketDisconnect:
        pass
    except Exception as e:
        await websocket.send_text(f"Error: {str(e)}")
    finally:
        await websocket.close()