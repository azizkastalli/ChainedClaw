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
    """Interactive shell via WebSocket using docker exec with TTY."""
    import docker
    import docker.errors
    import asyncio
    import threading
    import queue
    
    await websocket.accept()

    if not _CONTAINER_NAME_RE.match(name):
        await websocket.send_text("Error: Invalid container name\r\n")
        await websocket.close(code=1008)
        return

    try:
        client = docker.from_env()
        container = client.containers.get(name)
        
        # Create exec instance with TTY enabled
        exec_instance = client.api.exec_create(
            container.id,
            "/bin/bash",
            stdin=True,
            stdout=True,
            stderr=True,
            tty=True,
            privileged=False,
            workdir=None
        )
        exec_id = exec_instance['Id']
        
        # Start exec and get socket for bidirectional communication
        sock = client.api.exec_start(exec_id, detach=False, tty=True, stream=True, socket=True)
        
        # Use the raw socket from the response
        raw_sock = sock._sock if hasattr(sock, '_sock') else sock
        
        # Queue for output from container
        output_queue = queue.Queue()
        running = True
        
        def read_output():
            """Read output from container in background thread."""
            try:
                while running:
                    try:
                        data = raw_sock.recv(4096)
                        if not data:
                            break
                        output_queue.put(data)
                    except Exception:
                        break
            finally:
                output_queue.put(None)  # Signal end
        
        # Start background reader thread
        reader = threading.Thread(target=read_output, daemon=True)
        reader.start()
        
        # Send initial message
        await websocket.send_text(f"\r\nConnected to {name}\r\n")
        
        async def send_output():
            """Send queued output to websocket."""
            while running:
                try:
                    data = output_queue.get(timeout=0.1)
                    if data is None:
                        return False
                    # Decode and send
                    try:
                        text = data.decode('utf-8', errors='replace')
                        await websocket.send_text(text)
                    except:
                        pass
                except queue.Empty:
                    pass
                except Exception:
                    pass
            return True
        
        # Main loop: handle input from websocket
        while running:
            try:
                # Check for output (non-blocking)
                while not output_queue.empty():
                    data = output_queue.get_nowait()
                    if data is None:
                        running = False
                        break
                    try:
                        text = data.decode('utf-8', errors='replace')
                        await websocket.send_text(text)
                    except:
                        pass
                
                # Wait for input with timeout
                try:
                    msg = await asyncio.wait_for(websocket.receive_text(), timeout=0.05)
                    
                    # Ignore JSON control messages
                    try:
                        parsed = _json.loads(msg)
                        if isinstance(parsed, dict):
                            continue
                    except _json.JSONDecodeError:
                        pass
                    
                    # Send input to container
                    raw_sock.send(msg.encode('utf-8'))
                    
                except asyncio.TimeoutError:
                    continue
                except WebSocketDisconnect:
                    break
                    
            except Exception as e:
                break
        
        # Cleanup
        running = False
        try:
            raw_sock.close()
        except:
            pass
                    
    except docker.errors.NotFound:
        await websocket.send_text(f"Error: Container '{name}' not found\r\n")
    except Exception as e:
        try:
            await websocket.send_text(f"Error: {str(e)}\r\n")
        except:
            pass
    finally:
        try:
            await websocket.close()
        except:
            pass
