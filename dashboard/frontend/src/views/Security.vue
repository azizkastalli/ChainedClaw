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

function getStatusColor(s: string): string {
  return s === 'ok' ? 'green' : s === 'warn' ? 'orange' : 'red'
}

function getStatusIcon(s: string): string {
  return s === 'ok' ? '✓' : s === 'warn' ? '⚠' : '✗'
}

onMounted(fetchStatus)
</script>

<template>
  <div class="security">
    <h1>Security</h1>
    <div v-if="loading" class="loading">Loading...</div>
    <div v-else-if="error" class="error">{{ error }}</div>
    <template v-else>
      <!-- Quick Actions -->
      <div class="actions-card">
        <h2>Quick Actions</h2>
        <div class="actions">
          <button @click="runPreflight" :disabled="actionLoading !== ''" class="btn btn-primary">
            {{ actionLoading === 'preflight' ? 'Running...' : 'Run Preflight' }}
          </button>
        </div>
      </div>

      <!-- Firewall Section -->
      <div class="section-card">
        <div class="section-header">
          <h2>🛡️ Firewall</h2>
          <span :class="['status-badge', getStatusColor(status?.firewall?.status || 'unknown')]">
            {{ getStatusIcon(status?.firewall?.status || 'unknown') }} 
            {{ status?.firewall?.status || 'unknown' }}
          </span>
        </div>
        <p class="section-message">{{ status?.firewall?.message }}</p>
        <p v-if="status?.firewall?.details" class="section-details">{{ status?.firewall?.details }}</p>
        
        <div class="firewall-controls">
          <div class="mode-selector">
            <label>Mode:</label>
            <select v-model="firewallMode" :disabled="actionLoading !== ''">
              <option value="default">Default (SSH whitelist only)</option>
              <option value="strict">Strict (Block all SSH not in whitelist)</option>
              <option value="block-all">Block All (Block all non-SSH outbound)</option>
            </select>
          </div>
          <div class="firewall-actions">
            <button 
              @click="setupFirewall" 
              :disabled="actionLoading !== ''"
              class="btn btn-success"
            >
              {{ actionLoading === 'firewall' ? 'Applying...' : 'Apply Rules' }}
            </button>
            <button 
              @click="showConfirmFlush = true"
              :disabled="actionLoading !== ''"
              class="btn btn-danger"
            >
              Flush Rules
            </button>
          </div>
        </div>
      </div>

      <!-- Seccomp Section -->
      <div class="section-card">
        <div class="section-header">
          <h2>🔒 Seccomp Profile</h2>
          <span :class="['status-badge', getStatusColor(status?.seccomp?.status || 'unknown')]">
            {{ getStatusIcon(status?.seccomp?.status || 'unknown') }} 
            {{ status?.seccomp?.status || 'unknown' }}
          </span>
        </div>
        <p class="section-message">{{ status?.seccomp?.message }}</p>
        <p v-if="status?.seccomp?.details" class="section-details">{{ status?.seccomp?.details }}</p>
      </div>

      <!-- Container Section -->
      <div class="section-card">
        <div class="section-header">
          <h2>📦 Container</h2>
          <span :class="['status-badge', getStatusColor(status?.container?.status || 'unknown')]">
            {{ getStatusIcon(status?.container?.status || 'unknown') }} 
            {{ status?.container?.status || 'unknown' }}
          </span>
        </div>
        <p class="section-message">{{ status?.container?.message }}</p>
        <p v-if="status?.container?.details" class="section-details">{{ status?.container?.details }}</p>
      </div>

      <!-- Capabilities Section -->
      <div class="section-card">
        <div class="section-header">
          <h2>⚡ Capabilities</h2>
          <span :class="['status-badge', getStatusColor(status?.capabilities?.status || 'unknown')]">
            {{ getStatusIcon(status?.capabilities?.status || 'unknown') }} 
            {{ status?.capabilities?.status || 'unknown' }}
          </span>
        </div>
        <p class="section-message">{{ status?.capabilities?.message }}</p>
        <p v-if="status?.capabilities?.details" class="section-details">{{ status?.capabilities?.details }}</p>
      </div>

      <!-- Overall Status -->
      <div class="overall-card">
        <h2>Overall Security Status</h2>
        <span :class="['overall-status', getStatusColor(status?.overall || 'unknown')]">
          {{ status?.overall?.toUpperCase() || 'UNKNOWN' }}
        </span>
      </div>
    </template>

    <!-- Confirmation Modal -->
    <div v-if="showConfirmFlush" class="modal-overlay" @click.self="showConfirmFlush = false">
      <div class="modal confirm-modal">
        <h3>Confirm Flush Firewall</h3>
        <p>This will remove all firewall rules for the agent container. The container will have unrestricted network access.</p>
        <div class="modal-actions">
          <button @click="showConfirmFlush = false" class="btn">Cancel</button>
          <button @click="flushFirewall" class="btn btn-danger">Flush Rules</button>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.security { padding: 20px; max-width: 900px; }
.loading, .error { padding: 20px; text-align: center; }
.error { color: #ef4444; background: #fef2f2; border-radius: 8px; }

.actions-card {
  background: #f8fafc;
  border: 1px solid #e2e8f0;
  border-radius: 8px;
  padding: 20px;
  margin-bottom: 20px;
}
.actions-card h2 { margin: 0 0 15px 0; font-size: 1.1em; }
.actions { display: flex; gap: 10px; }

.section-card {
  background: white;
  border: 1px solid #e5e5e5;
  border-radius: 8px;
  padding: 20px;
  margin-bottom: 15px;
}
.section-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 10px;
}
.section-header h2 { margin: 0; font-size: 1.1em; }
.section-message { margin: 0 0 8px 0; color: #374151; }
.section-details { margin: 0; font-size: 0.85em; color: #6b7280; font-family: monospace; }

.status-badge {
  padding: 4px 12px;
  border-radius: 20px;
  font-size: 0.85em;
  font-weight: 500;
}
.status-badge.green { background: #dcfce7; color: #166534; }
.status-badge.orange { background: #fef3c7; color: #92400e; }
.status-badge.red { background: #fee2e2; color: #991b1b; }

.firewall-controls {
  margin-top: 15px;
  padding-top: 15px;
  border-top: 1px solid #e5e5e5;
  display: flex;
  flex-direction: column;
  gap: 15px;
}
.mode-selector {
  display: flex;
  align-items: center;
  gap: 10px;
}
.mode-selector label { font-weight: 500; min-width: 60px; }
.mode-selector select {
  flex: 1;
  padding: 8px 12px;
  border: 1px solid #d1d5db;
  border-radius: 6px;
  font-size: 0.9em;
}
.firewall-actions { display: flex; gap: 10px; }

.overall-card {
  background: #1e293b;
  color: white;
  border-radius: 8px;
  padding: 25px;
  text-align: center;
}
.overall-card h2 { margin: 0 0 15px 0; font-size: 1.1em; font-weight: normal; }
.overall-status {
  font-size: 1.5em;
  font-weight: bold;
  padding: 10px 30px;
  border-radius: 8px;
}
.overall-status.green { background: #166534; }
.overall-status.orange { background: #92400e; }
.overall-status.red { background: #991b1b; }

/* Buttons */
.btn {
  padding: 8px 16px;
  border: 1px solid #d1d5db;
  border-radius: 6px;
  background: white;
  cursor: pointer;
  font-size: 0.9em;
}
.btn:hover:not(:disabled) { background: #f3f4f6; }
.btn:disabled { opacity: 0.5; cursor: not-allowed; }
.btn-primary { background: #3b82f6; color: white; border-color: #3b82f6; }
.btn-primary:hover:not(:disabled) { background: #2563eb; }
.btn-success { background: #22c55e; color: white; border-color: #22c55e; }
.btn-success:hover:not(:disabled) { background: #16a34a; }
.btn-danger { background: #ef4444; color: white; border-color: #ef4444; }
.btn-danger:hover:not(:disabled) { background: #dc2626; }

/* Modal */
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
  padding: 25px;
  max-width: 400px;
}
.confirm-modal h3 { margin: 0 0 15px 0; }
.confirm-modal p { color: #6b7280; margin: 0 0 20px 0; }
.modal-actions { display: flex; gap: 10px; justify-content: flex-end; }

/* Colors */
.green { color: #22c55e; }
.orange { color: #f97316; }
.red { color: #ef4444; }
</style>