<script setup lang="ts">
import { ref, onMounted, onUnmounted } from 'vue'
import { dashboardApi, type OverallStatus, type Container, type SSHHostStatus } from '../api/client'

const status = ref<OverallStatus | null>(null)
const containers = ref<Container[]>([])
const hosts = ref<SSHHostStatus[]>([])
const loading = ref(true)
const error = ref('')

let refreshInterval: number | null = null

async function fetchData() {
  try {
    const [statusData, containersData, hostsData] = await Promise.all([
      dashboardApi.getOverallStatus(),
      dashboardApi.getContainers(),
      dashboardApi.getHostsStatus()
    ])
    status.value = statusData
    containers.value = containersData
    hosts.value = hostsData
    error.value = ''
  } catch (e: any) {
    error.value = e.message || 'Failed to fetch data'
  } finally {
    loading.value = false
  }
}

function getStatusColor(s: string): string {
  return s === 'ok' ? 'green' : s === 'warn' ? 'orange' : 'red'
}

function getContainerColor(s: string): string {
  return s === 'running' ? 'green' : 'gray'
}

onMounted(() => {
  fetchData()
  refreshInterval = window.setInterval(fetchData, 10000)
})

onUnmounted(() => {
  if (refreshInterval) clearInterval(refreshInterval)
})
</script>

<template>
  <div class="dashboard">
    <h1>OpenClaw Dashboard</h1>
    
    <div v-if="loading" class="loading">Loading...</div>
    <div v-else-if="error" class="error">{{ error }}</div>
    
    <template v-else>
      <!-- Status Overview -->
      <div class="status-card">
        <h2>Status Overview</h2>
        <div class="status-grid">
          <div class="status-item">
            <span class="status-label">Security</span>
            <span :class="['status-value', getStatusColor(status?.security || 'unknown')]">
              {{ status?.security || 'unknown' }}
            </span>
          </div>
          <div class="status-item">
            <span class="status-label">Containers</span>
            <span :class="['status-value', status?.containers_running ? 'green' : 'red']">
              {{ status?.containers_running ? 'Running' : 'Stopped' }}
            </span>
          </div>
          <div class="status-item">
            <span class="status-label">SSH Hosts</span>
            <span class="status-value">
              {{ status?.hosts_connected }}/{{ status?.hosts_total }} connected
            </span>
          </div>
        </div>
      </div>

      <!-- Containers -->
      <div class="section">
        <h2>Containers</h2>
        <div class="container-list">
          <div v-for="c in containers" :key="c.name" class="container-item">
            <span class="container-name">{{ c.name }}</span>
            <span :class="['container-status', getContainerColor(c.status)]">{{ c.status }}</span>
            <span class="container-image">{{ c.image }}</span>
          </div>
        </div>
      </div>

      <!-- SSH Hosts -->
      <div class="section">
        <h2>SSH Hosts</h2>
        <div class="host-list">
          <div v-for="h in hosts" :key="h.name" class="host-item">
            <span class="host-name">{{ h.name }}</span>
            <span class="host-addr">{{ h.hostname }}:{{ h.port }}</span>
            <span :class="['host-status', h.connected ? 'green' : 'red']">
              {{ h.connected ? 'Connected' : 'Disconnected' }}
            </span>
          </div>
        </div>
      </div>
    </template>
  </div>
</template>

<style scoped>
.dashboard {
  padding: 20px;
}
h1 {
  margin-bottom: 20px;
}
h2 {
  font-size: 1.2em;
  margin-bottom: 10px;
}
.status-card {
  background: #f5f5f5;
  padding: 15px;
  border-radius: 8px;
  margin-bottom: 20px;
}
.status-grid {
  display: flex;
  gap: 30px;
}
.status-item {
  display: flex;
  flex-direction: column;
}
.status-label {
  font-size: 0.9em;
  color: #666;
}
.status-value {
  font-weight: bold;
  font-size: 1.1em;
}
.section {
  margin-bottom: 20px;
}
.container-list, .host-list {
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.container-item, .host-item {
  display: flex;
  gap: 15px;
  padding: 10px;
  background: #f9f9f9;
  border-radius: 4px;
}
.container-name, .host-name {
  font-weight: bold;
  min-width: 150px;
}
.container-status, .host-status {
  min-width: 100px;
}
.green { color: #22c55e; }
.orange { color: #f97316; }
.red { color: #ef4444; }
.gray { color: #6b7280; }
.loading, .error {
  padding: 20px;
  text-align: center;
}
.error {
  color: red;
}
</style>