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

function getStatusClass(s: string): string {
  return s === 'running' ? 'success' : 'danger'
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
  <div class="containers-page">
    <div class="page-header">
      <div>
        <h1 class="page-title">Containers</h1>
        <p class="page-subtitle">Manage your containers</p>
      </div>
      <div class="header-actions">
        <button @click="startContainers" :disabled="actionLoading !== ''" class="btn btn-success btn-sm">
          ▶ Start All
        </button>
        <button @click="stopContainers" :disabled="actionLoading !== ''" class="btn btn-danger btn-sm">
          ■ Stop All
        </button>
        <button @click="restartContainers" :disabled="actionLoading !== ''" class="btn btn-secondary btn-sm">
          ↻ Restart All
        </button>
      </div>
    </div>

    <div v-if="loading" class="loading-container">
      <div class="spinner"></div>
      <span>Loading containers...</span>
    </div>

    <div v-else-if="error" class="error-message">{{ error }}</div>

    <div v-else class="containers-grid">
      <div v-for="c in containers" :key="c.name" class="container-card">
        <div class="container-header">
          <div class="container-title-row">
            <h3 class="container-name">{{ c.name }}</h3>
            <span :class="['badge', getStatusClass(c.status)]">
              {{ c.status }}
            </span>
          </div>
          <div class="container-meta">
            <span class="meta-item">
              <span class="meta-icon">📦</span>
              {{ c.image }}
            </span>
          </div>
          <div v-if="c.health" class="health-status">
            <span :class="['health-badge', c.health]">
              {{ c.health }}
            </span>
          </div>
        </div>
        
        <div class="container-actions">
          <button 
            v-if="isStopped(c)" 
            @click="startContainer(c.name)" 
            :disabled="actionLoading !== ''"
            class="btn btn-success btn-sm"
          >▶ Start</button>
          <button 
            v-if="isRunning(c)" 
            @click="stopContainer(c.name)" 
            :disabled="actionLoading !== ''"
            class="btn btn-danger btn-sm"
          >■ Stop</button>
          <button 
            @click="restartContainer(c.name)" 
            :disabled="actionLoading !== '' || isStopped(c)"
            class="btn btn-secondary btn-sm"
          >↻ Restart</button>
          <button 
            @click="viewLogs(c.name)" 
            class="btn btn-secondary btn-sm"
          >📋 Logs</button>
        </div>
      </div>
    </div>

    <!-- Logs Modal -->
    <div v-if="showLogs" class="modal-overlay" @click.self="closeLogs">
      <div class="modal">
        <div class="modal-header">
          <h2>📋 Logs: {{ selectedContainer }}</h2>
          <button @click="closeLogs" class="modal-close">&times;</button>
        </div>
        <div class="modal-body">
          <div v-if="logsLoading" class="loading-container">
            <div class="spinner"></div>
            <span>Loading logs...</span>
          </div>
          <pre v-else class="logs-output">{{ logs || 'No logs available' }}</pre>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.containers-page {
  max-width: 1200px;
}

.page-header {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  margin-bottom: 20px;
  flex-wrap: wrap;
  gap: 12px;
}

.header-actions {
  display: flex;
  gap: 6px;
}

/* Containers Grid */
.containers-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
  gap: 12px;
}

.container-card {
  background: #1a1a1a;
  border: 1px solid #2a2a2a;
}

.container-header {
  padding: 16px;
  border-bottom: 1px solid #2a2a2a;
}

.container-title-row {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 8px;
}

.container-name {
  font-size: 14px;
  font-weight: 600;
  color: #ffffff;
}

.container-meta {
  display: flex;
  gap: 12px;
}

.meta-item {
  display: flex;
  align-items: center;
  gap: 4px;
  font-size: 12px;
  color: #888;
}

.meta-icon {
  font-size: 12px;
}

.health-status {
  margin-top: 8px;
}

.health-badge {
  padding: 2px 8px;
  font-size: 10px;
  font-weight: 600;
  text-transform: uppercase;
}

.health-badge.healthy {
  background: #166534;
  color: #86efac;
}

.health-badge.unhealthy {
  background: #991b1b;
  color: #fca5a5;
}

.health-badge.starting {
  background: #854d0e;
  color: #fde047;
}

.container-actions {
  padding: 12px 16px;
  display: flex;
  gap: 6px;
  flex-wrap: wrap;
  background: #0f0f0f;
}

/* Modal */
.modal-overlay {
  position: fixed;
  top: 0; left: 0; right: 0; bottom: 0;
  background: rgba(0, 0, 0, 0.8);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 1000;
  padding: 20px;
}

.modal {
  background: #1a1a1a;
  border: 1px solid #2a2a2a;
  width: 100%;
  max-width: 900px;
  max-height: 80vh;
  display: flex;
  flex-direction: column;
}

.modal-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 16px 20px;
  border-bottom: 1px solid #2a2a2a;
}

.modal-header h2 {
  font-size: 15px;
  font-weight: 600;
  color: #ffffff;
}

.modal-close {
  background: #2a2a2a;
  border: none;
  font-size: 20px;
  cursor: pointer;
  color: #888;
  width: 32px;
  height: 32px;
  display: flex;
  align-items: center;
  justify-content: center;
}

.modal-close:hover {
  background: #3a3a3a;
  color: #fff;
}

.modal-body {
  padding: 20px;
  overflow: auto;
  flex: 1;
}

.logs-output {
  background: #0a0a0a;
  color: #a3e635;
  padding: 16px;
  font-family: 'JetBrains Mono', 'Fira Code', monospace;
  font-size: 12px;
  line-height: 1.5;
  white-space: pre-wrap;
  max-height: 500px;
  overflow: auto;
  margin: 0;
}
</style>