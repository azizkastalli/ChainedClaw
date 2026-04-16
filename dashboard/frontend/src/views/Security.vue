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
  actionLoading.value = 'preflight'
  error.value = ''
  try { await dashboardApi.runPreflight(); await fetchStatus() }
  catch (e: any) { error.value = e.message }
  finally { actionLoading.value = '' }
}

async function setupFirewall() {
  actionLoading.value = 'firewall'
  error.value = ''
  try { 
    await dashboardApi.setupFirewall(firewallMode.value)
    await fetchStatus() 
  }
  catch (e: any) { error.value = e.message }
  finally { actionLoading.value = '' }
}

async function flushFirewall() {
  actionLoading.value = 'flush'
  error.value = ''
  showConfirmFlush.value = false
  try { await dashboardApi.flushFirewall(); await fetchStatus() }
  catch (e: any) { error.value = e.message }
  finally { actionLoading.value = '' }
}

function getStatusClass(s: string): string {
  return s === 'ok' ? 'success' : s === 'warn' ? 'warning' : 'danger'
}

function getStatusIcon(s: string): string {
  return s === 'ok' ? '✓' : s === 'warn' ? '!' : '✗'
}

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

    <div v-if="loading" class="loading-container">
      <div class="spinner"></div>
      <span>Loading security status...</span>
    </div>

    <div v-else-if="error" class="error-message">{{ error }}</div>

    <template v-else>
      <!-- Overall Status -->
      <div class="overall-status-card" :class="getStatusClass(status?.overall || 'unknown')">
        <div class="overall-content">
          <span class="overall-icon">{{ getStatusIcon(status?.overall || 'unknown') }}</span>
          <div>
            <span class="overall-label">Overall Status</span>
            <span class="overall-value">{{ status?.overall?.toUpperCase() || 'UNKNOWN' }}</span>
          </div>
        </div>
      </div>

      <!-- Security Layers Grid -->
      <div class="layers-grid">
        <!-- Firewall -->
        <div class="layer-card">
          <div class="layer-header">
            <div class="layer-icon firewall">🛡️</div>
            <div class="layer-info">
              <h3 class="layer-title">Firewall</h3>
              <span :class="['badge', getStatusClass(status?.firewall?.status || 'unknown')]">
                {{ status?.firewall?.status }}
              </span>
            </div>
          </div>
          <p class="layer-message">{{ status?.firewall?.message }}</p>
          
          <div class="layer-controls">
            <div class="mode-select">
              <label>Mode</label>
              <select v-model="firewallMode" :disabled="actionLoading !== ''">
                <option value="default">Default</option>
                <option value="strict">Strict</option>
                <option value="block-all">Block All</option>
              </select>
            </div>
            <div class="layer-actions">
              <button 
                @click="setupFirewall" 
                :disabled="actionLoading !== ''"
                class="btn btn-success btn-sm"
              >Apply</button>
              <button 
                @click="showConfirmFlush = true"
                :disabled="actionLoading !== ''"
                class="btn btn-danger btn-sm"
              >Flush</button>
            </div>
          </div>
        </div>

        <!-- Seccomp -->
        <div class="layer-card">
          <div class="layer-header">
            <div class="layer-icon seccomp">🔒</div>
            <div class="layer-info">
              <h3 class="layer-title">Seccomp Profile</h3>
              <span :class="['badge', getStatusClass(status?.seccomp?.status || 'unknown')]">
                {{ status?.seccomp?.status }}
              </span>
            </div>
          </div>
          <p class="layer-message">{{ status?.seccomp?.message }}</p>
        </div>

        <!-- Container -->
        <div class="layer-card">
          <div class="layer-header">
            <div class="layer-icon container">📦</div>
            <div class="layer-info">
              <h3 class="layer-title">Container</h3>
              <span :class="['badge', getStatusClass(status?.container?.status || 'unknown')]">
                {{ status?.container?.status }}
              </span>
            </div>
          </div>
          <p class="layer-message">{{ status?.container?.message }}</p>
        </div>

        <!-- Capabilities -->
        <div class="layer-card">
          <div class="layer-header">
            <div class="layer-icon capabilities">⚡</div>
            <div class="layer-info">
              <h3 class="layer-title">Capabilities</h3>
              <span :class="['badge', getStatusClass(status?.capabilities?.status || 'unknown')]">
                {{ status?.capabilities?.status }}
              </span>
            </div>
          </div>
          <p class="layer-message">{{ status?.capabilities?.message }}</p>
        </div>
      </div>
    </template>

    <!-- Confirmation Modal -->
    <div v-if="showConfirmFlush" class="modal-overlay" @click.self="showConfirmFlush = false">
      <div class="confirm-modal">
        <div class="confirm-icon">⚠️</div>
        <h3>Flush Firewall Rules?</h3>
        <p>This will remove all firewall rules and the container will have unrestricted network access.</p>
        <div class="confirm-actions">
          <button @click="showConfirmFlush = false" class="btn btn-secondary">Cancel</button>
          <button @click="flushFirewall" class="btn btn-danger">Flush Rules</button>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.security-page {
  max-width: 1000px;
}

.page-header {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  margin-bottom: 24px;
}

/* Overall Status Card */
.overall-status-card {
  border-radius: 16px;
  padding: 24px;
  margin-bottom: 24px;
  background: white;
  box-shadow: 0 1px 3px rgba(0, 0, 0, 0.05), 0 4px 12px rgba(0, 0, 0, 0.05);
}

.overall-status-card.success {
  background: linear-gradient(135deg, #dcfce7 0%, #bbf7d0 100%);
  border-left: 4px solid #22c55e;
}

.overall-status-card.warning {
  background: linear-gradient(135deg, #fef3c7 0%, #fde68a 100%);
  border-left: 4px solid #f59e0b;
}

.overall-status-card.danger {
  background: linear-gradient(135deg, #fee2e2 0%, #fecaca 100%);
  border-left: 4px solid #ef4444;
}

.overall-content {
  display: flex;
  align-items: center;
  gap: 16px;
}

.overall-icon {
  font-size: 32px;
  width: 56px;
  height: 56px;
  border-radius: 12px;
  display: flex;
  align-items: center;
  justify-content: center;
  background: white;
  box-shadow: 0 2px 8px rgba(0, 0, 0, 0.1);
}

.overall-label {
  display: block;
  font-size: 14px;
  color: #6b7280;
  margin-bottom: 4px;
}

.overall-value {
  font-size: 24px;
  font-weight: 700;
  color: #1f2937;
}

/* Layers Grid */
.layers-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
  gap: 16px;
}

.layer-card {
  background: white;
  border-radius: 16px;
  padding: 24px;
  box-shadow: 0 1px 3px rgba(0, 0, 0, 0.05), 0 4px 12px rgba(0, 0, 0, 0.05);
}

.layer-header {
  display: flex;
  gap: 16px;
  margin-bottom: 12px;
}

.layer-icon {
  width: 48px;
  height: 48px;
  border-radius: 12px;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 24px;
}

.layer-icon.firewall { background: linear-gradient(135deg, #dbeafe 0%, #bfdbfe 100%); }
.layer-icon.seccomp { background: linear-gradient(135deg, #d1fae5 0%, #a7f3d0 100%); }
.layer-icon.container { background: linear-gradient(135deg, #fef3c7 0%, #fde68a 100%); }
.layer-icon.capabilities { background: linear-gradient(135deg, #e0e7ff 0%, #c7d2fe 100%); }

.layer-info {
  flex: 1;
}

.layer-title {
  font-size: 16px;
  font-weight: 600;
  color: #1f2937;
  margin-bottom: 6px;
}

.layer-message {
  color: #6b7280;
  font-size: 14px;
  margin: 0 0 16px 0;
}

.layer-controls {
  display: flex;
  flex-direction: column;
  gap: 12px;
  padding-top: 16px;
  border-top: 1px solid #f3f4f6;
}

.mode-select {
  display: flex;
  align-items: center;
  gap: 12px;
}

.mode-select label {
  font-size: 14px;
  font-weight: 500;
  color: #374151;
  min-width: 50px;
}

.mode-select select {
  flex: 1;
  padding: 8px 12px;
  border: 1px solid #e5e7eb;
  border-radius: 8px;
  font-size: 14px;
  background: #f9fafb;
}

.layer-actions {
  display: flex;
  gap: 8px;
}

/* Confirm Modal */
.modal-overlay {
  position: fixed;
  top: 0; left: 0; right: 0; bottom: 0;
  background: rgba(15, 23, 42, 0.7);
  backdrop-filter: blur(4px);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 1000;
}

.confirm-modal {
  background: white;
  border-radius: 20px;
  padding: 32px;
  max-width: 400px;
  text-align: center;
  box-shadow: 0 25px 50px -12px rgba(0, 0, 0, 0.25);
}

.confirm-icon {
  font-size: 48px;
  margin-bottom: 16px;
}

.confirm-modal h3 {
  font-size: 20px;
  font-weight: 600;
  margin-bottom: 12px;
  color: #1f2937;
}

.confirm-modal p {
  color: #6b7280;
  font-size: 14px;
  margin-bottom: 24px;
}

.confirm-actions {
  display: flex;
  gap: 12px;
  justify-content: center;
}
</style>