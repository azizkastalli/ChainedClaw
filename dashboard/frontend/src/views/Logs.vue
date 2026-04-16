<script setup lang="ts">
import { ref, onMounted, onUnmounted } from 'vue'
import { dashboardApi, type Container } from '../api/client'

const containers = ref<Container[]>([])
const selectedContainer = ref('')
const logs = ref('')
const loading = ref(true)
const error = ref('')
let ws: WebSocket | null = null

async function fetchContainers() {
  try {
    containers.value = await dashboardApi.getContainers()
    if (containers.value.length > 0) {
      selectedContainer.value = containers.value[0].name
      fetchLogs()
    }
  } catch (e: any) {
    error.value = e.message
  } finally {
    loading.value = false
  }
}

async function fetchLogs() {
  if (!selectedContainer.value) return
  try {
    const result = await dashboardApi.getLogs(selectedContainer.value, 500)
    logs.value = result.logs
  } catch (e: any) {
    error.value = e.message
  }
}

// WebSocket connection for real-time logs (future use)
// function connectWebSocket() {
//   if (!selectedContainer.value) return
//   const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:'
//   ws = new WebSocket(`${protocol}//${window.location.host}/api/containers/${selectedContainer.value}/logs/stream`)
//   ws.onmessage = (e) => { logs.value += e.data }
//   ws.onerror = () => { error.value = 'WebSocket error' }
// }

function disconnectWebSocket() {
  if (ws) { ws.close(); ws = null }
}

onMounted(fetchContainers)
onUnmounted(disconnectWebSocket)
</script>

<template>
  <div class="logs">
    <h1>Container Logs</h1>
    <div v-if="loading" class="loading">Loading...</div>
    <template v-else>
      <div class="controls">
        <select v-model="selectedContainer" @change="fetchLogs">
          <option v-for="c in containers" :key="c.name" :value="c.name">{{ c.name }}</option>
        </select>
        <button @click="fetchLogs">Refresh</button>
      </div>
      <div v-if="error" class="error">{{ error }}</div>
      <pre class="log-output">{{ logs || 'No logs available' }}</pre>
    </template>
  </div>
</template>

<style scoped>
.logs { padding: 20px; }
.controls { margin-bottom: 15px; display: flex; gap: 10px; }
select { padding: 8px; border: 1px solid #ddd; border-radius: 4px; }
.log-output { background: #1e1e1e; color: #d4d4d4; padding: 15px; border-radius: 4px; height: 500px; overflow: auto; font-family: monospace; font-size: 12px; white-space: pre-wrap; }
.loading { padding: 20px; text-align: center; }
.error { color: red; padding: 10px; }
</style>