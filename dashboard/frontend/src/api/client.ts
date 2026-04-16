import axios, { type AxiosInstance } from 'axios'

// API base URL - uses nginx proxy
const API_BASE_URL = '/api'

// Create axios instance with defaults
const api: AxiosInstance = axios.create({
  baseURL: API_BASE_URL,
  timeout: 30000,
  headers: {
    'Content-Type': 'application/json'
  }
})

// Types
export interface Container {
  name: string
  status: string
  image: string
  created: string
  ports: Array<{ host: string; host_port: string }>
  health?: string
}

export interface SecurityStatus {
  seccomp: { name: string; status: string; message: string; details?: string }
  firewall: { name: string; status: string; message: string; details?: string }
  container: { name: string; status: string; message: string; details?: string }
  capabilities: { name: string; status: string; message: string; details?: string }
  overall: string
}

export interface SSHHostStatus {
  name: string
  hostname: string
  port: number
  connected: boolean
  message: string
  chroot_exists?: boolean
  key_installed?: boolean
}

export interface SSHHost {
  name: string
  hostname: string
  port: number
  user: string
  strict_host_key_checking?: boolean
  isolation?: string
  chroot_egress_filter?: boolean
  docker_access?: boolean
  project_paths?: string[]
  forward_ports?: number[]
}

export interface AppConfig {
  allowed_domains: string[]
  ssh_hosts: SSHHost[]
  [key: string]: unknown
}

export interface OverallStatus {
  security: string
  containers_running: boolean
  hosts_total: number
  hosts_connected: number
  warnings: string[]
  issues: string[]
}

// API functions
export const dashboardApi = {
  // Status
  async getOverallStatus(): Promise<OverallStatus> {
    const response = await api.get('/status')
    return response.data
  },

  // Containers
  async getContainers(): Promise<Container[]> {
    const response = await api.get('/containers')
    return response.data
  },

  async startContainers(agent: string): Promise<{ success: boolean; message: string }> {
    const response = await api.post('/containers/up', { agent })
    return response.data
  },

  async stopContainers(): Promise<{ success: boolean; message: string }> {
    const response = await api.post('/containers/down')
    return response.data
  },

  async restartContainers(agent: string): Promise<{ success: boolean; message: string }> {
    const response = await api.post('/containers/restart', { agent })
    return response.data
  },

  async buildImage(agent: string): Promise<{ success: boolean; message: string }> {
    const response = await api.post('/containers/build', { agent })
    return response.data
  },

  async getLogs(name: string, tail: number = 100): Promise<{ logs: string; container: string }> {
    const response = await api.get(`/containers/${name}/logs`, { params: { tail } })
    return response.data
  },

  async startContainer(name: string): Promise<{ success: boolean; message: string }> {
    const response = await api.post(`/containers/${name}/start`)
    return response.data
  },

  async stopContainer(name: string): Promise<{ success: boolean; message: string }> {
    const response = await api.post(`/containers/${name}/stop`)
    return response.data
  },

  async restartContainer(name: string): Promise<{ success: boolean; message: string }> {
    const response = await api.post(`/containers/${name}/restart`)
    return response.data
  },

  // Security
  async getSecurityStatus(): Promise<SecurityStatus> {
    const response = await api.get('/security/status')
    return response.data
  },

  async runPreflight(): Promise<{ success: boolean; message: string; result: SecurityStatus }> {
    const response = await api.post('/security/preflight')
    return response.data
  },

  async setupFirewall(mode: string = 'default'): Promise<{ success: boolean; message: string }> {
    const response = await api.post('/security/firewall', null, { params: { mode } })
    return response.data
  },

  async flushFirewall(): Promise<{ success: boolean; message: string }> {
    const response = await api.delete('/security/firewall')
    return response.data
  },

  // Hosts
  async getHosts(): Promise<SSHHost[]> {
    const response = await api.get('/hosts')
    return response.data
  },

  async getHostsStatus(): Promise<SSHHostStatus[]> {
    const response = await api.get('/hosts/status')
    return response.data
  },

  async testHostConnection(name: string): Promise<{ host: string; connected: boolean; message: string }> {
    const response = await api.post(`/hosts/${name}/test`)
    return response.data
  },

  async setupHost(name: string): Promise<{ success: boolean; message: string }> {
    const response = await api.post(`/hosts/${name}/setup`)
    return response.data
  },

  async setupChroot(name: string): Promise<{ success: boolean; message: string }> {
    const response = await api.post(`/hosts/${name}/chroot`)
    return response.data
  },

  async removeChroot(name: string): Promise<{ success: boolean; message: string }> {
    const response = await api.delete(`/hosts/${name}/chroot`)
    return response.data
  },

  async installKey(name: string): Promise<{ success: boolean; message: string }> {
    const response = await api.post(`/hosts/${name}/key`)
    return response.data
  },

  async removeKey(name: string): Promise<{ success: boolean; message: string }> {
    const response = await api.delete(`/hosts/${name}/key`)
    return response.data
  },

  // Config
  async getConfig(): Promise<AppConfig> {
    const response = await api.get('/config')
    return response.data
  },

  async updateConfig(config: AppConfig): Promise<{ success: boolean; message: string }> {
    const response = await api.put('/config', { config })
    return response.data
  },

  async getEnv(): Promise<{ variables: Record<string, string>; exists: boolean }> {
    const response = await api.get('/config/env')
    return response.data
  },

  async updateEnv(env: Record<string, string>): Promise<{ success: boolean; message: string }> {
    const response = await api.put('/config/env', { env })
    return response.data
  },

  async initKeys(): Promise<{ success: boolean; message: string }> {
    const response = await api.post('/config/keys')
    return response.data
  },

  async getAuthStatus(): Promise<{ htpasswd_exists: boolean; htpasswd_path: string }> {
    const response = await api.get('/config/auth')
    return response.data
  },

  async resetAuth(password: string): Promise<{ success: boolean; message: string }> {
    const response = await api.post('/config/auth/reset', { password })
    return response.data
  },

  // Cleanup
  async cleanRuntime(): Promise<{ success: boolean; message: string }> {
    const response = await api.post('/cleanup/clean')
    return response.data
  },

  async purgeData(): Promise<{ success: boolean; message: string }> {
    const response = await api.post('/cleanup/purge-data', { confirm: 'yes' })
    return response.data
  },

  async uninstall(): Promise<{ success: boolean; message: string }> {
    const response = await api.post('/cleanup/uninstall', { confirm: 'yes' })
    return response.data
  }
}

export default api