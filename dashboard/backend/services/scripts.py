"""
Service for executing shell scripts for infrastructure management.
"""
import subprocess
import os
from typing import Optional, List


class ScriptService:
    """Service for executing infrastructure management scripts."""
    
    def __init__(self, scripts_dir: str = '/app/scripts'):
        self.scripts_dir = scripts_dir
    
    def run_script(self, script_path: str, args: List[str] = None, use_sudo: bool = False) -> dict:
        """Execute a shell script and return the result."""
        cmd = []
        if use_sudo:
            cmd.append('sudo')
        cmd.append(script_path)
        if args:
            cmd.extend(args)
        
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=300  # 5 minute timeout
            )
            
            return {
                'success': result.returncode == 0,
                'exit_code': result.returncode,
                'stdout': result.stdout,
                'stderr': result.stderr
            }
        except subprocess.TimeoutExpired:
            return {
                'success': False,
                'exit_code': -1,
                'stdout': '',
                'stderr': 'Script execution timed out'
            }
        except Exception as e:
            return {
                'success': False,
                'exit_code': -1,
                'stdout': '',
                'stderr': str(e)
            }
    
    def run_script_with_env(self, script_path: str, args: List[str] = None, env_vars: dict = None, use_sudo: bool = False) -> dict:
        """Execute a shell script with additional environment variables."""
        cmd = []
        if use_sudo:
            cmd.append('sudo')
            # Pass env vars through sudo with -E or individually
            if env_vars:
                for key, value in env_vars.items():
                    cmd.extend([f'{key}={value}'])
        cmd.append(script_path)
        if args:
            cmd.extend(args)
        
        # Build environment with additional vars
        env = os.environ.copy()
        if env_vars and not use_sudo:
            env.update(env_vars)
        
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=300,
                env=env if not use_sudo else None
            )
            
            return {
                'success': result.returncode == 0,
                'exit_code': result.returncode,
                'stdout': result.stdout,
                'stderr': result.stderr
            }
        except subprocess.TimeoutExpired:
            return {
                'success': False,
                'exit_code': -1,
                'stdout': '',
                'stderr': 'Script execution timed out'
            }
        except Exception as e:
            return {
                'success': False,
                'exit_code': -1,
                'stdout': '',
                'stderr': str(e)
            }
    
    def run_command(self, command: List[str], cwd: str = None, use_sudo: bool = False) -> dict:
        """Execute a command and return the result."""
        cmd = []
        if use_sudo:
            cmd.append('sudo')
        cmd.extend(command)
        
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                cwd=cwd,
                timeout=300
            )
            
            return {
                'success': result.returncode == 0,
                'exit_code': result.returncode,
                'stdout': result.stdout,
                'stderr': result.stderr
            }
        except subprocess.TimeoutExpired:
            return {
                'success': False,
                'exit_code': -1,
                'stdout': '',
                'stderr': 'Command execution timed out'
            }
        except Exception as e:
            return {
                'success': False,
                'exit_code': -1,
                'stdout': '',
                'stderr': str(e)
            }
    
    # SSH Key Management
    def init_ssh_keys(self) -> dict:
        """Initialize SSH keys."""
        return self.run_script(
            f'{self.scripts_dir}/ssh_key/init_keys.sh',
            use_sudo=True
        )
    
    def add_ssh_key(self, host: str) -> dict:
        """Add SSH key to a host."""
        result = self.run_script(
            f'{self.scripts_dir}/ssh_key/add.sh',
            args=[host],
            use_sudo=True
        )
        # Reload sshd
        self.run_command(['systemctl', 'reload', 'sshd'], use_sudo=True)
        return result
    
    def remove_ssh_key(self, host: str) -> dict:
        """Remove SSH key from a host."""
        result = self.run_script(
            f'{self.scripts_dir}/ssh_key/remove.sh',
            args=[host],
            use_sudo=True
        )
        # Reload sshd
        self.run_command(['systemctl', 'reload', 'sshd'], use_sudo=True)
        return result
    
    # Chroot Management
    def setup_chroot(self, host: str) -> dict:
        """Set up chroot jail for a host."""
        return self.run_script(
            f'{self.scripts_dir}/chroot_jail/jail_set.sh',
            args=[host],
            use_sudo=True
        )
    
    def remove_chroot(self, host: str) -> dict:
        """Remove chroot jail for a host."""
        return self.run_script(
            f'{self.scripts_dir}/chroot_jail/jail_break.sh',
            args=[host],
            use_sudo=True
        )
    
    def full_host_setup(self, host: str) -> dict:
        """Full host setup: chroot + SSH key + sshd reload."""
        # Step 1: Setup chroot
        chroot_result = self.setup_chroot(host)
        if not chroot_result['success']:
            return {
                'success': False,
                'message': f"Chroot setup failed: {chroot_result['stderr']}",
                'step': 'chroot'
            }
        
        # Step 2: Add SSH key
        key_result = self.add_ssh_key(host)
        if not key_result['success']:
            return {
                'success': False,
                'message': f"SSH key installation failed: {key_result['stderr']}",
                'step': 'ssh_key'
            }
        
        return {
            'success': True,
            'message': f'Host {host} setup complete',
            'stdout': f"{chroot_result['stdout']}\n{key_result['stdout']}"
        }
    
    # Remote Host Management
    def setup_remote_host(self, host: str, remote_key: str, remote_user: str = None) -> dict:
        """Set up chroot on a remote host."""
        args = [host, remote_key]
        if remote_user:
            args.append(remote_user)
        
        return self.run_script(
            f'{self.scripts_dir}/remote/setup.sh',
            args=args
        )
    
    def cleanup_remote_host(self, host: str, remote_key: str, remote_user: str = None) -> dict:
        """Clean up chroot on a remote host."""
        args = [host, remote_key]
        if remote_user:
            args.append(remote_user)
        
        return self.run_script(
            f'{self.scripts_dir}/remote/teardown.sh',
            args=args
        )
    
    # Firewall Management
    def setup_firewall(self, mode: str = "default") -> dict:
        """Set up firewall rules with specified mode (default, strict, block-all)."""
        args = []
        if mode == "strict":
            args = ['--strict']
        elif mode == "block-all":
            args = ['--block-all']
        
        # Set environment variables to point to the correct config paths
        env_vars = {
            'ENV_FILE': '/app/config/.env',
            'CONFIG_JSON': '/app/config/config.json'
        }
        
        return self.run_script_with_env(
            f'{self.scripts_dir}/firewall/setup_firewall.sh',
            args=args,
            env_vars=env_vars,
            use_sudo=True
        )
    
    def flush_firewall(self) -> dict:
        """Flush firewall rules."""
        return self.run_script(
            f'{self.scripts_dir}/firewall/setup_firewall.sh',
            args=['--flush'],
            use_sudo=True
        )
    
    # Cleanup Operations
    def clean_runtime(self) -> dict:
        """Clean runtime files."""
        result = self.run_command(['rm', '-rf', '/app/config/.openclaw-data/tmp'])
        if not result['success']:
            return result
        
        return self.run_command(['rm', '-f', '/app/config/nginx/.htpasswd'])
    
    def purge_data(self) -> dict:
        """Purge agent data directories."""
        result1 = self.run_command(['rm', '-rf', '/app/config/.openclaw-data'])
        result2 = self.run_command(['rm', '-rf', '/app/config/.claudecode-data'])
        
        return {
            'success': result1['success'] and result2['success'],
            'stdout': f"{result1['stdout']}\n{result2['stdout']}",
            'stderr': f"{result1['stderr']}\n{result2['stderr']}"
        }
    
    def uninstall(self) -> dict:
        """Run uninstall script."""
        return self.run_script(
            f'{self.scripts_dir}/uninstall.sh',
            use_sudo=True
        )
    
    # Auth Management
    def reset_auth(self, password: str) -> dict:
        """Reset dashboard password."""
        htpasswd_path = '/app/config/nginx/.htpasswd'
        
        # Use htpasswd to create/update password
        # -b: batch mode (password from command line)
        # -c: create new file (only if doesn't exist)
        
        if os.path.exists(htpasswd_path):
            # Update existing
            result = self.run_command([
                'htpasswd', '-b', htpasswd_path, 'admin', password
            ])
        else:
            # Create new
            result = self.run_command([
                'htpasswd', '-b', '-c', htpasswd_path, 'admin', password
            ])
        
        return result
    
    def check_auth_status(self) -> dict:
        """Check if htpasswd file exists."""
        htpasswd_path = '/app/config/nginx/.htpasswd'
        return {
            'htpasswd_exists': os.path.exists(htpasswd_path),
            'htpasswd_path': htpasswd_path
        }