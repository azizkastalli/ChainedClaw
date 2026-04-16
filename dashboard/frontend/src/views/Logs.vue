<script setup lang="ts">
import { ref, nextTick, onMounted, onUnmounted } from 'vue'
import { dashboardApi, type Container } from '../api/client'
import { useToast } from '../composables/useToast'

const { push } = useToast()

const containers = ref<Container[]>([])
const selectedContainer = ref('')
const logs = ref('')
const loading = ref(true)
const error = ref('')
const streaming = ref(false)
const logOutputRef = ref<HTMLPreElement | null>(null)

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
    nextTick(scrollToBottom)
  } catch (e: any) {
    error.value = e.message
  }
}

function connectWebSocket() {
  if (!selectedContainer.value) return
  disconnectWebSocket()
  logs.value = ''
  error.value = ''

  const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:'
  ws = new WebSocket(`${protocol}//${window.location.host}/api/containers/${selectedContainer.value}/logs/stream`)

  ws.onopen = () => {
    streaming.value = true
  }

  ws.onmessage = (e) => {
    logs.value += e.data
    nextTick(scrollToBottom)
  }

  ws.onerror = () => {
    streaming.value = false
    push('Log stream connection error', 'error')
  }

  ws.onclose = () => {
    streaming.value = false
  }
}

function disconnectWebSocket() {
  if (ws) {
    ws.close()
    ws = null
  }
  streaming.value = false
}

function scrollToBottom() {
  if (logOutputRef.value) {
    logOutputRef.value.scrollTop = logOutputRef.value.scrollHeight
  }
}

function onContainerChange() {
  disconnectWebSocket()
  fetchLogs()
}

function toggleMode() {
  if (streaming.value) {
    disconnectWebSocket()
    fetchLogs()
  } else {
    connectWebSocket()
  }
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
        <select v-model="selectedContainer" @change="onContainerChange">
          <option v-for="c in containers" :key="c.name" :value="c.name">{{ c.name }}</option>
        </select>
        <button @click="fetchLogs" :disabled="streaming">Refresh</button>
        <button @click="toggleMode" :class="{ 'btn-active': streaming }">
          {{ streaming ? 'Stop Live' : 'Go Live' }}
        </button>
        <span v-if="streaming" class="live-badge">● LIVE</span>
      </div>
      <div v-if="error" class="error">{{ error }}</div>
      <pre ref="logOutputRef" class="log-output">{{ logs || 'No logs available' }}</pre>
    </template>
  </div>
</template>

<style scoped>
.logs { padding: 20px; }
.controls { margin-bottom: 15px; display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }
select { padding: 8px; border: 1px solid #ddd; border-radius: 4px; }
button {
  padding: 7px 14px;
  border: 1px solid #d1d5db;
  border-radius: 4px;
  background: white;
  cursor: pointer;
  font-size: 0.9em;
}
button:hover:not(:disabled) { background: #f3f4f6; }
button:disabled { opacity: 0.5; cursor: not-allowed; }
.btn-active { background: #ef4444; color: white; border-color: #ef4444; }
.btn-active:hover:not(:disabled) { background: #dc2626; }
.live-badge {
  color: #ef4444;
  font-size: 0.85em;
  font-weight: bold;
  animation: pulse 1.5s infinite;
}
@keyframes pulse {
  0%, 100% { opacity: 1; }
  50% { opacity: 0.4; }
}
.log-output {
  background: #1e1e1e;
  color: #d4d4d4;
  padding: 15px;
  border-radius: 4px;
  height: 500px;
  overflow: auto;
  font-family: monospace;
  font-size: 12px;
  white-space: pre-wrap;
}
.loading { padding: 20px; text-align: center; }
.error { color: #ef4444; padding: 10px; background: #fef2f2; border-radius: 4px; margin-bottom: 10px; }
</style>
