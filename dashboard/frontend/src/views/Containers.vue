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
        <p class="page-subtitle">Manage your OpenClaw containers</p>
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
  margin-bottom: 24px;
  flex-wrap: wrap;
  gap: 16px;
}

.header-actions {
  display: flex;
  gap: 8px;
}

/* Containers Grid */
.containers-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(320px, 1fr));
  gap: 16px;
}

.container-card {
  background: white;
  border-radius: 16px;
  box-shadow: 0 1px 3px rgba(0, 0, 0, 0.05), 0 4px 12px rgba(0, 0, 0, 0.05);
  overflow: hidden;
  transition: transform 0.2s, box-shadow 0.2s;
}

.container-card:hover {
  transform: translateY(-2px);
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.1), 0 8px 24px rgba(0, 0, 0, 0.1);
}

.container-header {
  padding: 20px;
  border-bottom: 1px solid #f3f4f6;
}

.container-title-row {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 12px;
}

.container-name {
  font-size: 16px;
  font-weight: 600;
  color: #1f2937;
}

.container-meta {
  display: flex;
  gap: 16px;
}

.meta-item {
  display: flex;
  align-items: center;
  gap: 6px;
  font-size: 13px;
  color: #6b7280;
}

.meta-icon {
  font-size: 14px;
}

.health-status {
  margin-top: 12px;
}

.health-badge {
  padding: 4px 10px;
  border-radius: 12px;
  font-size: 11px;
  font-weight: 600;
  text-transform: uppercase;
}

.health-badge.healthy {
  background: #dcfce7;
  color: #166534;
}

.health-badge.unhealthy {
  background: #fee2e2;
  color: #991b1b;
}

.health-badge.starting {
  background: #fef3c7;
  color: #92400e;
}

.container-actions {
  padding: 16px 20px;
  display: flex;
  gap: 8px;
  flex-wrap: wrap;
  background: #f9fafb;
}

/* Modal */
.modal-overlay {
  position: fixed;
  top: 0; left: 0; right: 0; bottom: 0;
  background: rgba(15, 23, 42, 0.7);
  backdrop-filter: blur(4px);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 1000;
  padding: 20px;
}

.modal {
  background: white;
  border-radius: 20px;
  width: 100%;
  max-width: 900px;
  max-height: 80vh;
  display: flex;
  flex-direction: column;
  box-shadow: 0 25px 50px -12px rgba(0, 0, 0, 0.25);
}

.modal-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 20px 24px;
  border-bottom: 1px solid #f3f4f6;
}

.modal-header h2 {
  font-size: 18px;
  font-weight: 600;
  color: #1f2937;
}

.modal-close {
  background: #f3f4f6;
  border: none;
  font-size: 24px;
  cursor: pointer;
  color: #6b7280;
  width: 36px;
  height: 36px;
  border-radius: 10px;
  display: flex;
  align-items: center;
  justify-content: center;
  transition: all 0.2s;
}

.modal-close:hover {
  background: #e5e7eb;
  color: #1f2937;
}

.modal-body {
  padding: 24px;
  overflow: auto;
  flex: 1;
}

.logs-output {
  background: #0f172a;
  color: #e2e8f0;
  padding: 20px;
  border-radius: 12px;
  font-family: 'JetBrains Mono', 'Fira Code', monospace;
  font-size: 13px;
  line-height: 1.6;
  white-space: pre-wrap;
  max-height: 500px;
  overflow: auto;
}
</style>