"""
Service for checking infrastructure status.
"""
import subprocess
import os
import json
import asyncio
from concurrent.futures import ThreadPoolExecutor
from typing import List, Dict, Any, Optional


class StatusService:
    """Service for checking infrastructure status."""
    
    def __init__(self, config_path: str = '/app/config/config.json'):
        self.config_path = config_path
    
    def check_seccomp(self) -> dict:
        """Check seccomp profile status."""
        seccomp_path = '/app/config/security/seccomp-agent.json'
        
        if not os.path.exists(seccomp_path):
            return {
                'name': 'Seccomp',
                'status': 'fail',
                'message': 'Seccomp profile not found',
                'details': f'Expected at {seccomp_path}'
            }
        
        # Check if Docker supports seccomp
        try:
            result = subprocess.run(
                ['docker', 'info', '--format', '{{.SecurityOptions}}'],
                capture_output=True,
                text=True
            )
            
            if 'seccomp' in result.stdout:
                return {
                    'name': 'Seccomp',
                    'status': 'ok',
                    'message': 'Seccomp profile present, Docker supports seccomp',
                    'details': seccomp_path
                }
            else:
                return {
                    'name': 'Seccomp',
                    'status': 'warn',
                    'message': 'Profile exists but Docker seccomp support not detected',
                    'details': seccomp_path
                }
        except Exception as e:
            return {
                'name': 'Seccomp',
                'status': 'fail',
                'message': f'Error checking Docker: {str(e)}',
                'details': None
            }
    
    def check_firewall(self) -> dict:
        """Check firewall rules status."""
        try:
            result = subprocess.run(
                ['sudo', 'iptables', '-L', 'FORWARD', '-n'],
                capture_output=True,
                text=True
            )
            
            if 'AGENT-DEV-FIREWALL' in result.stdout:
                return {
                    'name': 'Firewall',
                    'status': 'ok',
                    'message': 'AGENT-DEV-FIREWALL rules are present',
                    'details': 'Firewall active'
                }
            else:
                return {
                    'name': 'Firewall',
                    'status': 'fail',
                    'message': 'No firewall rules found',
                    'details': 'Run firewall setup to fix'
                }
        except Exception as e:
            return {
                'name': 'Firewall',
                'status': 'fail',
                'message': f'Error checking firewall: {str(e)}',
                'details': None
            }
    
    def check_container(self, container_name: str = 'agent-dev') -> dict:
        """Check container status."""
        try:
            result = subprocess.run(
                ['docker', 'ps', '--filter', f'name={container_name}', 
                 '--filter', 'status=running', '--format', '{{.Names}}'],
                capture_output=True,
                text=True
            )
            
            if container_name in result.stdout:
                return {
                    'name': 'Container',
                    'status': 'ok',
                    'message': f'{container_name} is running',
                    'details': None
                }
            else:
                return {
                    'name': 'Container',
                    'status': 'fail',
                    'message': f'{container_name} is not running',
                    'details': 'Start containers to fix'
                }
        except Exception as e:
            return {
                'name': 'Container',
                'status': 'fail',
                'message': f'Error checking container: {str(e)}',
                'details': None
            }
    
    def check_capabilities(self, container_name: str = 'agent-dev') -> dict:
        """Check container capabilities."""
        try:
            result = subprocess.run(
                ['docker', 'inspect', container_name, 
                 '--format', '{{.HostConfig.CapAdd}}'],
                capture_output=True,
                text=True
            )
            
            cap_add = result.stdout.strip()
            
            # Check for NET_ADMIN
            has_net_admin = 'NET_ADMIN' in cap_add
            has_net_raw = 'NET_RAW' in cap_add
            
            # Check cap_drop
            result_drop = subprocess.run(
                ['docker', 'inspect', container_name, 
                 '--format', '{{.HostConfig.CapDrop}}'],
                capture_output=True,
                text=True
            )
            cap_drop = result_drop.stdout.strip()
            has_drop_all = 'ALL' in cap_drop
            
            messages = []
            if has_net_admin:
                messages.append('NET_ADMIN present')
            if has_net_raw:
                messages.append('NET_RAW present')
            if has_drop_all:
                messages.append('cap_drop: ALL')
            
            if has_net_admin and has_net_raw and has_drop_all:
                return {
                    'name': 'Capabilities',
                    'status': 'ok',
                    'message': 'All capabilities configured correctly',
                    'details': ', '.join(messages)
                }
            else:
                missing = []
                if not has_net_admin:
                    missing.append('NET_ADMIN')
                if not has_net_raw:
                    missing.append('NET_RAW')
                if not has_drop_all:
                    missing.append('cap_drop: ALL')
                
                return {
                    'name': 'Capabilities',
                    'status': 'warn',
                    'message': f'Missing: {", ".join(missing)}',
                    'details': cap_add
                }
        except Exception as e:
            return {
                'name': 'Capabilities',
                'status': 'fail',
                'message': f'Error checking capabilities: {str(e)}',
                'details': None
            }
    
    def get_security_status(self, container_name: str = 'agent-dev') -> dict:
        """Get overall security status."""
        seccomp = self.check_seccomp()
        firewall = self.check_firewall()
        container = self.check_container(container_name)
        capabilities = self.check_capabilities(container_name)
        
        # Determine overall status
        statuses = [s['status'] for s in [seccomp, firewall, container, capabilities]]
        if 'fail' in statuses:
            overall = 'fail'
        elif 'warn' in statuses:
            overall = 'warn'
        else:
            overall = 'ok'
        
        return {
            'seccomp': seccomp,
            'firewall': firewall,
            'container': container,
            'capabilities': capabilities,
            'overall': overall
        }
    
    def get_ssh_hosts(self) -> List[Dict[str, Any]]:
        """Get SSH hosts from config.json."""
        try:
            with open(self.config_path, 'r') as f:
                config = json.load(f)
            return config.get('ssh_hosts', [])
        except Exception as e:
            return []
    
    def test_ssh_connection(self, host: str) -> dict:
        """Test SSH connection to a host from the agent container."""
        try:
            # Get the container user
            result = subprocess.run(
                ['docker', 'inspect', 'agent-dev', '--format', 
                 '{{range .Config.Env}}{{println .}}{{end}}'],
                capture_output=True,
                text=True
            )
            
            agent_user = 'root'
            for line in result.stdout.split('\n'):
                if line.startswith('AGENT_USER='):
                    agent_user = line.split('=')[1].strip()
                    break
            
            # Find SSH agent socket
            socket_result = subprocess.run(
                ['docker', 'exec', '-u', agent_user, 'agent-dev', 
                 'bash', '-c', 'ls /tmp/ssh-*/agent.* 2>/dev/null | head -1'],
                capture_output=True,
                text=True
            )
            
            socket = socket_result.stdout.strip()
            
            # Test SSH connection
            ssh_result = subprocess.run(
                ['docker', 'exec', '-u', agent_user, '-e', f'SSH_AUTH_SOCK={socket}',
                 'agent-dev', 'ssh', '-o', 'ConnectTimeout=5', host, 'whoami'],
                capture_output=True,
                text=True,
                timeout=10
            )
            
            if ssh_result.returncode == 0:
                return {
                    'connected': True,
                    'message': f"Connected as {ssh_result.stdout.strip()}"
                }
            else:
                return {
                    'connected': False,
                    'message': ssh_result.stderr.strip() or 'Connection failed'
                }
        except subprocess.TimeoutExpired:
            return {
                'connected': False,
                'message': 'Connection timed out'
            }
        except Exception as e:
            return {
                'connected': False,
                'message': str(e)
            }
    
    def check_chroot_exists(self, host: str) -> bool:
        """Check if chroot exists for a host."""
        chroot_path = f'/home/dev-bot/{host}'
        return os.path.exists(chroot_path)
    
    def check_key_installed(self, host: str) -> bool:
        """Check if SSH key is installed for a host."""
        key_path = f'/home/dev-bot/{host}/.ssh/authorized_keys'
        return os.path.exists(key_path)
    
    def get_host_status(self, host_config: dict) -> dict:
        """Get full status for a host."""
        host_name = host_config.get('name', 'unknown')
        hostname = host_config.get('hostname', '')
        port = host_config.get('port', 22)
        
        # Check if chroot exists (for local hosts)
        chroot_exists = self.check_chroot_exists(host_name) if host_config.get('isolation') == 'chroot' else None
        
        # Check if key is installed
        key_installed = self.check_key_installed(host_name) if host_config.get('isolation') == 'chroot' else None
        
        # Test SSH connection
        ssh_status = self.test_ssh_connection(host_name)
        
        return {
            'name': host_name,
            'hostname': hostname,
            'port': port,
            'connected': ssh_status['connected'],
            'message': ssh_status['message'],
            'chroot_exists': chroot_exists,
            'key_installed': key_installed
        }
    
    def get_all_hosts_status(self) -> List[dict]:
        """Get status for all configured hosts (sequential, for direct calls)."""
        hosts = self.get_ssh_hosts()
        return [self.get_host_status(h) for h in hosts]

    async def get_all_hosts_status_async(self) -> List[dict]:
        """Get status for all configured hosts concurrently."""
        hosts = self.get_ssh_hosts()
        if not hosts:
            return []
        loop = asyncio.get_event_loop()
        with ThreadPoolExecutor(max_workers=min(len(hosts), 10)) as pool:
            results = await asyncio.gather(
                *[loop.run_in_executor(pool, self.get_host_status, h) for h in hosts]
            )
        return list(results)

    async def get_overall_status_async(self) -> dict:
        """Get overall infrastructure status with parallel SSH checks."""
        loop = asyncio.get_event_loop()
        # Run security checks and host checks concurrently
        security_future = loop.run_in_executor(None, self.get_security_status)
        hosts_future = self.get_all_hosts_status_async()
        security, hosts = await asyncio.gather(security_future, hosts_future)

        connected_count = sum(1 for h in hosts if h['connected'])

        return {
            'security': security['overall'],
            'containers_running': security['container']['status'] == 'ok',
            'hosts_total': len(hosts),
            'hosts_connected': connected_count,
            'warnings': [],
            'issues': []
        }