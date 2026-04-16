<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { dashboardApi, type Container } from '../api/client'

const containers = ref<Container[]>([])
const loading = ref(true)
const error = ref('')
const actionLoading = ref('')
const selectedContainer = ref<string | null>(null)
const showLogs = ref(false)
const logs = ref('')
const logsLoading = ref(false)

async function fetchContainers() {
  try {
    containers.value = await dashboardApi.getContainers()
  } catch (e: any) {
    error.value = e.message
  } finally {
    loading.value = false
  }
}

async function startContainers() {
  actionLoading.value = 'start'
  try { await dashboardApi.startContainers('openclaw'); await fetchContainers() }
  catch (e: any) { error.value = e.message }
  finally { actionLoading.value = '' }
}

async function stopContainers() {
  actionLoading.value = 'stop'
  try { await dashboardApi.stopContainers(); await fetchContainers() }
  catch (e: any) { error.value = e.message }
  finally { actionLoading.value = '' }
}

async function restartContainers() {
  actionLoading.value = 'restart'
  try { await dashboardApi.restartContainers('openclaw'); await fetchContainers() }
  catch (e: any) { error.value = e.message }
  finally { actionLoading.value = '' }
}

// Individual container actions
async function startContainer(name: string) {
  actionLoading.value = `start-${name}`
  try { await dashboardApi.startContainer(name); await fetchContainers() }
  catch (e: any) { error.value = e.message }
  finally { actionLoading.value = '' }
}

async function stopContainer(name: string) {
  actionLoading.value = `stop-${name}`
  try { await dashboardApi.stopContainer(name); await fetchContainers() }
  catch (e: any) { error.value = e.message }
  finally { actionLoading.value = '' }
}

async function restartContainer(name: string) {
  actionLoading.value = `restart-${name}`
  try { await dashboardApi.restartContainer(name); await fetchContainers() }
  catch (e: any) { error.value = e.message }
  finally { actionLoading.value = '' }
}

async function viewLogs(name: string) {
  selectedContainer.value = name
  showLogs.value = true
  logsLoading.value = true
  logs.value = ''
  try {
    const result = await dashboardApi.getLogs(name, 200)
    logs.value = result.logs
  } catch (e: any) {
    logs.value = `Error fetching logs: ${e.message}`
  } finally {
    logsLoading.value = false
  }
}

function closeLogs() {
  showLogs.value = false
  selectedContainer.value = null
  logs.value = ''
}

function getStatusColor(s: string): string {
  return s === 'running' ? 'green' : s === 'stopped' || s === 'exited' ? 'red' : 'gray'
}

function isRunning(c: Container): boolean {
  return c.status === 'running'
}

function isStopped(c: Container): boolean {
  return c.status === 'stopped' || c.status === 'exited'
}

onMounted(fetchContainers)
</script>

<template>
  <div class="containers">
    <h1>Containers</h1>
    <div v-if="loading" class="loading">Loading...</div>
    <div v-else-if="error" class="error">{{ error }}</div>
    <template v-else>
      <div class="actions">
        <button @click="startContainers" :disabled="actionLoading !== ''">Start All</button>
        <button @click="stopContainers" :disabled="actionLoading !== ''">Stop All</button>
        <button @click="restartContainers" :disabled="actionLoading !== ''">Restart All</button>
      </div>
      <div class="container-list">
        <div v-for="c in containers" :key="c.name" class="container-item">
          <div class="container-row">
            <span class="name">{{ c.name }}</span>
            <span :class="['status', getStatusColor(c.status)]">{{ c.status }}</span>
            <span class="image">{{ c.image }}</span>
            <span v-if="c.health" :class="['health', c.health]">{{ c.health }}</span>
          </div>
          <div class="container-actions">
            <button 
              v-if="isStopped(c)" 
              @click="startContainer(c.name)" 
              :disabled="actionLoading !== ''"
              class="btn-small btn-start"
            >Start</button>
            <button 
              v-if="isRunning(c)" 
              @click="stopContainer(c.name)" 
              :disabled="actionLoading !== ''"
              class="btn-small btn-stop"
            >Stop</button>
            <button 
              @click="restartContainer(c.name)" 
              :disabled="actionLoading !== '' || isStopped(c)"
              class="btn-small btn-restart"
            >Restart</button>
            <button 
              @click="viewLogs(c.name)" 
              class="btn-small btn-logs"
            >Logs</button>
          </div>
        </div>
      </div>
    </template>

    <!-- Logs Modal -->
    <div v-if="showLogs" class="modal-overlay" @click.self="closeLogs">
      <div class="modal">
        <div class="modal-header">
          <h2>Logs: {{ selectedContainer }}</h2>
          <button @click="closeLogs" class="btn-close">&times;</button>
        </div>
        <div class="modal-body">
          <div v-if="logsLoading" class="loading">Loading logs...</div>
          <pre v-else class="logs-output">{{ logs || 'No logs available' }}</pre>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.containers { padding: 20px; }
.actions { margin-bottom: 20px; display: flex; gap: 10px; }
.container-list { display: flex; flex-direction: column; gap: 8px; }
.container-item { 
  display: flex; 
  flex-direction: column;
  gap: 10px; 
  padding: 15px; 
  background: #f9f9f9; 
  border-radius: 4px; 
  border: 1px solid #e5e5e5;
}
.container-row { display: flex; gap: 15px; align-items: center; }
.name { font-weight: bold; min-width: 180px; }
.status { min-width: 100px; font-weight: 500; }
.image { color: #666; font-size: 0.9em; flex: 1; }
.health { padding: 2px 8px; border-radius: 3px; font-size: 0.8em; }
.health.healthy { background: #dcfce7; color: #166534; }
.health.unhealthy { background: #fee2e2; color: #991b1b; }
.health.starting { background: #fef3c7; color: #92400e; }
.container-actions { display: flex; gap: 8px; }
.btn-small { 
  padding: 4px 12px; 
  font-size: 0.85em; 
  border: 1px solid #ddd; 
  background: white; 
  border-radius: 4px; 
  cursor: pointer;
}
.btn-small:hover:not(:disabled) { background: #f0f0f0; }
.btn-small:disabled { opacity: 0.5; cursor: not-allowed; }
.btn-start { border-color: #22c55e; color: #22c55e; }
.btn-stop { border-color: #ef4444; color: #ef4444; }
.btn-restart { border-color: #f97316; color: #f97316; }
.btn-logs { border-color: #3b82f6; color: #3b82f6; }
.green { color: #22c55e; }
.red { color: #ef4444; }
.gray { color: #6b7280; }
.loading, .error { padding: 20px; text-align: center; }
.error { color: red; }

/* Modal styles */
.modal-overlay { 
  position: fixed; 
  top: 0; left: 0; right: 0; bottom: 0; 
  background: rgba(0,0,0,0.5); 
  display: flex; 
  align-items: center; 
  justify-content: center; 
  z-index: 1000; 
}
.modal { 
  background: white; 
  border-radius: 8px; 
  width: 90%; 
  max-width: 900px; 
  max-height: 80vh; 
  display: flex; 
  flex-direction: column; 
}
.modal-header { 
  display: flex; 
  justify-content: space-between; 
  align-items: center; 
  padding: 15px 20px; 
  border-bottom: 1px solid #e5e5e5; 
}
.modal-header h2 { margin: 0; font-size: 1.2em; }
.btn-close { 
  background: none; 
  border: none; 
  font-size: 1.5em; 
  cursor: pointer; 
  color: #666; 
}
.modal-body { padding: 20px; overflow: auto; flex: 1; }
.logs-output { 
  background: #1e1e1e; 
  color: #d4d4d4; 
  padding: 15px; 
  border-radius: 4px; 
  font-family: monospace; 
  font-size: 12px; 
  white-space: pre-wrap; 
  max-height: 500px; 
  overflow: auto; 
}
</style>