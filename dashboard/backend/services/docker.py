"""
Docker service for container management operations.
"""
import docker
from typing import List, Optional
from docker.errors import DockerException, NotFound, APIError
from models import ContainerInfo, ContainerStatus


class DockerService:
    """Service for Docker container operations."""
    
    def __init__(self):
        self.client = docker.from_env()
    
    def get_containers(self, name_filter: Optional[str] = None) -> List[ContainerInfo]:
        """List all containers related to OpenClaw."""
        try:
            containers = self.client.containers.list(all=True)
            result = []
            
            for c in containers:
                # Filter for OpenClaw-related containers
                if name_filter and name_filter not in c.name:
                    continue
                if not any(name in c.name for name in ['agent-', 'openclaw', 'claudecode', 'dashboard', 'nginx']):
                    continue
                
                # Determine status
                status = self._parse_status(c.status)
                
                # Get health status if available
                health = None
                if c.attrs.get('State', {}).get('Health'):
                    health = c.attrs['State']['Health']['Status']
                
                # Get ports
                ports = []
                for port_binding in c.attrs.get('NetworkSettings', {}).get('Ports', {}).values():
                    if port_binding:
                        for binding in port_binding:
                            ports.append({
                                'host': binding.get('HostIp', '0.0.0.0'),
                                'host_port': binding.get('HostPort', ''),
                            })
                
                result.append(ContainerInfo(
                    name=c.name,
                    status=status,
                    image=c.image.tags[0] if c.image.tags else c.image.id[:12],
                    created=c.attrs['Created'],
                    ports=ports,
                    health=health
                ))
            
            return result
        except DockerException as e:
            raise Exception(f"Docker error: {str(e)}")
    
    def get_container(self, name: str) -> Optional[ContainerInfo]:
        """Get a specific container by name."""
        try:
            c = self.client.containers.get(name)
            status = self._parse_status(c.status)
            health = None
            if c.attrs.get('State', {}).get('Health'):
                health = c.attrs['State']['Health']['Status']
            
            ports = []
            for port_binding in c.attrs.get('NetworkSettings', {}).get('Ports', {}).values():
                if port_binding:
                    for binding in port_binding:
                        ports.append({
                            'host': binding.get('HostIp', '0.0.0.0'),
                            'host_port': binding.get('HostPort', ''),
                        })
            
            return ContainerInfo(
                name=c.name,
                status=status,
                image=c.image.tags[0] if c.image.tags else c.image.id[:12],
                created=c.attrs['Created'],
                ports=ports,
                health=health
            )
        except NotFound:
            return None
        except DockerException as e:
            raise Exception(f"Docker error: {str(e)}")
    
    def start_containers(self, agent: str) -> dict:
        """Start containers using docker compose."""
        import subprocess
        
        try:
            result = subprocess.run(
                ['docker', 'compose', '--profile', agent, 'up', '-d'],
                capture_output=True,
                text=True,
                cwd='/app/config'
            )
            
            if result.returncode != 0:
                raise Exception(result.stderr)
            
            return {
                'success': True,
                'message': f'Containers started for {agent}',
                'output': result.stdout
            }
        except Exception as e:
            raise Exception(f"Failed to start containers: {str(e)}")
    
    def stop_containers(self) -> dict:
        """Stop all OpenClaw containers."""
        import subprocess
        
        try:
            result = subprocess.run(
                ['docker', 'compose', '--profile', 'openclaw', '--profile', 'claudecode', 'down'],
                capture_output=True,
                text=True,
                cwd='/app/config'
            )
            
            if result.returncode != 0:
                raise Exception(result.stderr)
            
            return {
                'success': True,
                'message': 'Containers stopped',
                'output': result.stdout
            }
        except Exception as e:
            raise Exception(f"Failed to stop containers: {str(e)}")
    
    def restart_containers(self, agent: str) -> dict:
        """Restart containers."""
        import subprocess
        
        try:
            result = subprocess.run(
                ['docker', 'compose', '--profile', agent, 'restart'],
                capture_output=True,
                text=True,
                cwd='/app/config'
            )
            
            if result.returncode != 0:
                raise Exception(result.stderr)
            
            return {
                'success': True,
                'message': f'Containers restarted for {agent}',
                'output': result.stdout
            }
        except Exception as e:
            raise Exception(f"Failed to restart containers: {str(e)}")
    
    def build_image(self, agent: str) -> dict:
        """Build container image."""
        import subprocess
        
        try:
            result = subprocess.run(
                ['docker', 'compose', '--profile', agent, 'build'],
                capture_output=True,
                text=True,
                cwd='/app/config'
            )
            
            if result.returncode != 0:
                raise Exception(result.stderr)
            
            return {
                'success': True,
                'message': f'Image built for {agent}',
                'output': result.stdout
            }
        except Exception as e:
            raise Exception(f"Failed to build image: {str(e)}")
    
    def get_logs(self, container_name: str, tail: int = 100) -> str:
        """Get container logs."""
        try:
            container = self.client.containers.get(container_name)
            logs = container.logs(tail=tail, timestamps=True)
            return logs.decode('utf-8')
        except NotFound:
            raise Exception(f"Container {container_name} not found")
        except DockerException as e:
            raise Exception(f"Docker error: {str(e)}")
    
    def stream_logs(self, container_name: str):
        """Stream container logs as generator."""
        try:
            container = self.client.containers.get(container_name)
            for line in container.logs(stream=True, follow=True):
                yield line.decode('utf-8')
        except NotFound:
            raise Exception(f"Container {container_name} not found")
        except DockerException as e:
            raise Exception(f"Docker error: {str(e)}")
    
    def exec_in_container(self, container_name: str, command: List[str], user: str = None) -> dict:
        """Execute command in container."""
        try:
            container = self.client.containers.get(container_name)
            exec_result = container.exec_run(
                cmd=command,
                user=user,
                stdout=True,
                stderr=True
            )
            
            return {
                'success': exec_result.exit_code == 0,
                'exit_code': exec_result.exit_code,
                'output': exec_result.output.decode('utf-8')
            }
        except NotFound:
            raise Exception(f"Container {container_name} not found")
        except DockerException as e:
            raise Exception(f"Docker error: {str(e)}")
    
    def start_container(self, container_name: str) -> dict:
        """Start a specific container."""
        try:
            container = self.client.containers.get(container_name)
            container.start()
            return {
                'success': True,
                'message': f'Container {container_name} started'
            }
        except NotFound:
            raise Exception(f"Container {container_name} not found")
        except DockerException as e:
            raise Exception(f"Docker error: {str(e)}")
    
    def stop_container(self, container_name: str) -> dict:
        """Stop a specific container."""
        try:
            container = self.client.containers.get(container_name)
            container.stop()
            return {
                'success': True,
                'message': f'Container {container_name} stopped'
            }
        except NotFound:
            raise Exception(f"Container {container_name} not found")
        except DockerException as e:
            raise Exception(f"Docker error: {str(e)}")
    
    def restart_container(self, container_name: str) -> dict:
        """Restart a specific container."""
        try:
            container = self.client.containers.get(container_name)
            container.restart()
            return {
                'success': True,
                'message': f'Container {container_name} restarted'
            }
        except NotFound:
            raise Exception(f"Container {container_name} not found")
        except DockerException as e:
            raise Exception(f"Docker error: {str(e)}")
    
    def _parse_status(self, status_str: str) -> ContainerStatus:
        """Parse Docker status string to ContainerStatus enum."""
        status_lower = status_str.lower()
        if 'running' in status_lower:
            return ContainerStatus.RUNNING
        elif 'paused' in status_lower:
            return ContainerStatus.PAUSED
        elif 'restarting' in status_lower:
            return ContainerStatus.RESTARTING
        elif 'exited' in status_lower or 'stopped' in status_lower:
            return ContainerStatus.STOPPED
        else:
            return ContainerStatus.UNKNOWN