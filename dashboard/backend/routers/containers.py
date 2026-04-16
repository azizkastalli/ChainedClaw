"""
Container management router.
"""
from fastapi import APIRouter, HTTPException, WebSocket, WebSocketDisconnect
from typing import List
import sys
import os
import json as _json
import re

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


@router.post("/{name}/start", response_model=SuccessResponse)
async def start_container(name: str):
    """Start a specific container."""
    try:
        result = docker_service.start_container(name)
        return SuccessResponse(message=result['message'])
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/{name}/stop", response_model=SuccessResponse)
async def stop_container(name: str):
    """Stop a specific container."""
    try:
        result = docker_service.stop_container(name)
        return SuccessResponse(message=result['message'])
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/{name}/restart", response_model=SuccessResponse)
async def restart_container(name: str):
    """Restart a specific container."""
    try:
        result = docker_service.restart_container(name)
        return SuccessResponse(message=result['message'])
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


_CONTAINER_NAME_RE = re.compile(r'^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$')


@router.websocket("/{name}/logs/stream")
async def stream_logs(websocket: WebSocket, name: str):
    """Stream container logs via WebSocket."""
    await websocket.accept()
    if not _CONTAINER_NAME_RE.match(name):
        await websocket.send_text("Error: Invalid container name\r\n")
        await websocket.close(code=1008)
        return
    try:
        for line in docker_service.stream_logs(name):
            await websocket.send_text(line)
    except WebSocketDisconnect:
        pass
    except Exception as e:
        await websocket.send_text(f"Error: {str(e)}")
    finally:
        await websocket.close()


@router.websocket("/{name}/shell")
async def container_shell(websocket: WebSocket, name: str):
    """Interactive shell via WebSocket using docker exec."""
    import docker
    import docker.errors
    import asyncio
    
    await websocket.accept()

    if not _CONTAINER_NAME_RE.match(name):
        await websocket.send_text("Error: Invalid container name\r\n")
        await websocket.close(code=1008)
        return

    try:
        client = docker.from_env()
        container = client.containers.get(name)
        
        # Send welcome message
        await websocket.send_text(f"\r\nConnected to {name}\r\n")
        await websocket.send_text(f"Type 'exit' to disconnect\r\n\r\n")
        
        # Simple command execution loop
        while True:
            try:
                # Show prompt
                await websocket.send_text("$ ")
                
                # Wait for command
                cmd = await websocket.receive_text()

                # Guard: ignore JSON control messages (e.g. resize events from xterm.js)
                try:
                    msg = _json.loads(cmd)
                    if isinstance(msg, dict):
                        continue  # silently ignore all JSON control messages
                except _json.JSONDecodeError:
                    pass  # plain text command — fall through

                if cmd.strip().lower() == 'exit':
                    await websocket.send_text("\r\nDisconnected.\r\n")
                    break

                if not cmd.strip():
                    continue
                
                # Execute command
                result = docker_service.exec_in_container(name, ["/bin/bash", "-c", cmd])
                
                if result['success']:
                    output = result['output']
                    if output:
                        await websocket.send_text(output)
                        if not output.endswith('\n'):
                            await websocket.send_text("\r\n")
                else:
                    await websocket.send_text(f"Error: {result['output']}\r\n")
                    
            except WebSocketDisconnect:
                break
            except Exception as e:
                await websocket.send_text(f"Error: {str(e)}\r\n")
                
    except docker.errors.NotFound:
        await websocket.send_text(f"Error: Container '{name}' not found\r\n")
    except Exception as e:
        await websocket.send_text(f"Error: {str(e)}\r\n")
    finally:
        await websocket.close()
