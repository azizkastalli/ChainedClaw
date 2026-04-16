<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { dashboardApi, type SecurityStatus } from '../api/client'

const status = ref<SecurityStatus | null>(null)
const loading = ref(true)
const error = ref('')
const actionLoading = ref('')
const firewallMode = ref('default')
const showConfirmFlush = ref(false)

async function fetchStatus() {
  try { status.value = await dashboardApi.getSecurityStatus() }
  catch (e: any) { error.value = e.message }
  finally { loading.value = false }
}

async function runPreflight() {
  actionLoading.value = 'preflight'; error.value = ''
  try { await dashboardApi.runPreflight(); await fetchStatus() }
  catch (e: any) { error.value = e.message }
  finally { actionLoading.value = '' }
}

async function setupFirewall() {
  actionLoading.value = 'firewall'; error.value = ''
  try { await dashboardApi.setupFirewall(firewallMode.value); await fetchStatus() }
  catch (e: any) { error.value = e.message }
  finally { actionLoading.value = '' }
}

async function flushFirewall() {
  actionLoading.value = 'flush'; error.value = ''; showConfirmFlush.value = false
  try { await dashboardApi.flushFirewall(); await fetchStatus() }
  catch (e: any) { error.value = e.message }
  finally { actionLoading.value = '' }
}

function getStatusClass(s: string): string { return s === 'ok' ? 'success' : s === 'warn' ? 'warning' : 'danger' }
function getStatusIcon(s: string): string { return s === 'ok' ? '✓' : s === 'warn' ? '!' : '✗' }

onMounted(fetchStatus)
</script>

<template>
  <div class="security-page">
    <div class="page-header">
      <div>
        <h1 class="page-title">Security</h1>
        <p class="page-subtitle">Monitor and configure security layers</p>
      </div>
      <button @click="runPreflight" :disabled="actionLoading !== ''" class="btn btn-primary">
        {{ actionLoading === 'preflight' ? 'Running...' : '🔍 Run Preflight' }}
      </button>
    </div>

    <div v-if="loading" class="loading-container"><div class="spinner"></div><span>Loading...</span></div>
    <div v-else-if="error" class="error-message">{{ error }}</div>

    <template v-else>
      <div class="overall-card" :class="getStatusClass(status?.overall || 'unknown')">
        <span class="overall-icon">{{ getStatusIcon(status?.overall || 'unknown') }}</span>
        <div>
          <span class="overall-label">Overall Status</span>
          <span class="overall-value">{{ status?.overall?.toUpperCase() || 'UNKNOWN' }}</span>
        </div>
      </div>

      <div class="layers-grid">
        <div class="layer-card">
          <div class="layer-header">
            <span class="layer-icon">🛡️</span>
            <div class="layer-info">
              <h3 class="layer-title">Firewall</h3>
              <span :class="['badge', getStatusClass(status?.firewall?.status || 'unknown')]">{{ status?.firewall?.status }}</span>
            </div>
          </div>
          <p class="layer-message">{{ status?.firewall?.message }}</p>
          <div class="layer-controls">
            <select v-model="firewallMode" :disabled="actionLoading !== ''">
              <option value="default">Default</option>
              <option value="strict">Strict</option>
              <option value="block-all">Block All</option>
            </select>
            <div class="layer-actions">
              <button @click="setupFirewall" :disabled="actionLoading !== ''" class="btn btn-success btn-sm">Apply</button>
              <button @click="showConfirmFlush = true" :disabled="actionLoading !== ''" class="btn btn-danger btn-sm">Flush</button>
            </div>
          </div>
        </div>

        <div class="layer-card">
          <div class="layer-header">
            <span class="layer-icon">🔒</span>
            <div class="layer-info">
              <h3 class="layer-title">Seccomp</h3>
              <span :class="['badge', getStatusClass(status?.seccomp?.status || 'unknown')]">{{ status?.seccomp?.status }}</span>
            </div>
          </div>
          <p class="layer-message">{{ status?.seccomp?.message }}</p>
        </div>

        <div class="layer-card">
          <div class="layer-header">
            <span class="layer-icon">📦</span>
            <div class="layer-info">
              <h3 class="layer-title">Container</h3>
              <span :class="['badge', getStatusClass(status?.container?.status || 'unknown')]">{{ status?.container?.status }}</span>
            </div>
          </div>
          <p class="layer-message">{{ status?.container?.message }}</p>
        </div>

        <div class="layer-card">
          <div class="layer-header">
            <span class="layer-icon">⚡</span>
            <div class="layer-info">
              <h3 class="layer-title">Capabilities</h3>
              <span :class="['badge', getStatusClass(status?.capabilities?.status || 'unknown')]">{{ status?.capabilities?.status }}</span>
            </div>
          </div>
          <p class="layer-message">{{ status?.capabilities?.message }}</p>
        </div>
      </div>
    </template>

    <div v-if="showConfirmFlush" class="modal-overlay" @click.self="showConfirmFlush = false">
      <div class="confirm-modal">
        <h3>⚠️ Flush Firewall Rules?</h3>
        <p>This will remove all firewall rules. The container will have unrestricted network access.</p>
        <div class="confirm-actions">
          <button @click="showConfirmFlush = false" class="btn btn-secondary">Cancel</button>
          <button @click="flushFirewall" class="btn btn-danger">Flush</button>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.security-page { max-width: 1000px; }
.page-header { display: flex; justify-content: space-between; align-items: flex-start; margin-bottom: 20px; }
.overall-card { display: flex; align-items: center; gap: 16px; padding: 20px; margin-bottom: 20px; background: var(--bg-secondary); border: 1px solid var(--border-color); border-left: 4px solid var(--border-color); }
.overall-card.success { border-left-color: #16a34a; }
.overall-card.warning { border-left-color: #ca8a04; }
.overall-card.danger { border-left-color: #dc2626; }
.overall-icon { font-size: 24px; width: 40px; height: 40px; display: flex; align-items: center; justify-content: center; background: var(--bg-tertiary); }
.overall-label { display: block; font-size: 12px; color: var(--text-secondary); margin-bottom: 2px; }
.overall-value { font-size: 18px; font-weight: 600; color: var(--text-primary); }
.layers-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 12px; }
.layer-card { background: var(--bg-secondary); border: 1px solid var(--border-color); padding: 16px; }
.layer-header { display: flex; gap: 12px; margin-bottom: 8px; }
.layer-icon { font-size: 20px; width: 36px; height: 36px; display: flex; align-items: center; justify-content: center; background: var(--bg-tertiary); border: 1px solid var(--border-color); }
.layer-info { flex: 1; }
.layer-title { font-size: 14px; font-weight: 600; color: var(--text-primary); margin-bottom: 4px; }
.layer-message { color: var(--text-secondary); font-size: 12px; margin: 0 0 12px 0; }
.layer-controls { display: flex; flex-direction: column; gap: 8px; padding-top: 12px; border-top: 1px solid var(--border-color); }
.layer-controls select { padding: 6px 10px; font-size: 12px; }
.layer-actions { display: flex; gap: 6px; }
.modal-overlay { position: fixed; top: 0; left: 0; right: 0; bottom: 0; background: rgba(0, 0, 0, 0.8); display: flex; align-items: center; justify-content: center; z-index: 1000; }
.confirm-modal { background: var(--bg-secondary); border: 1px solid var(--border-color); padding: 24px; max-width: 360px; }
.confirm-modal h3 { font-size: 16px; margin-bottom: 12px; color: var(--text-primary); }
.confirm-modal p { color: var(--text-secondary); font-size: 13px; margin-bottom: 20px; }
.confirm-actions { display: flex; gap: 8px; justify-content: flex-end; }
</style>