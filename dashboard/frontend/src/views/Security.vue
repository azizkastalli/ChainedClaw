<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { dashboardApi, type SecurityStatus } from '../api/client'

const status = ref<SecurityStatus | null>(null)
const loading = ref(true)
const error = ref('')
const actionLoading = ref('')

async function fetchStatus() {
  try { status.value = await dashboardApi.getSecurityStatus() }
  catch (e: any) { error.value = e.message }
  finally { loading.value = false }
}

async function runPreflight() {
  actionLoading.value = 'preflight'
  try { await dashboardApi.runPreflight(); await fetchStatus() }
  catch (e: any) { error.value = e.message }
  finally { actionLoading.value = '' }
}

async function setupFirewall() {
  actionLoading.value = 'firewall'
  try { await dashboardApi.setupFirewall(); await fetchStatus() }
  catch (e: any) { error.value = e.message }
  finally { actionLoading.value = '' }
}

async function flushFirewall() {
  actionLoading.value = 'flush'
  try { await dashboardApi.flushFirewall(); await fetchStatus() }
  catch (e: any) { error.value = e.message }
  finally { actionLoading.value = '' }
}

function getStatusColor(s: string): string {
  return s === 'ok' ? 'green' : s === 'warn' ? 'orange' : 'red'
}

onMounted(fetchStatus)
</script>

<template>
  <div class="security">
    <h1>Security</h1>
    <div v-if="loading" class="loading">Loading...</div>
    <div v-else-if="error" class="error">{{ error }}</div>
    <template v-else>
      <div class="actions">
        <button @click="runPreflight" :disabled="actionLoading !== ''">Run Preflight</button>
        <button @click="setupFirewall" :disabled="actionLoading !== ''">Apply Firewall</button>
        <button @click="flushFirewall" :disabled="actionLoading !== ''">Flush Firewall</button>
      </div>
      <div class="status-list">
        <div class="status-item">
          <span class="label">Seccomp</span>
          <span :class="['value', getStatusColor(status?.seccomp?.status || 'unknown')]">
            {{ status?.seccomp?.status }} - {{ status?.seccomp?.message }}
          </span>
        </div>
        <div class="status-item">
          <span class="label">Firewall</span>
          <span :class="['value', getStatusColor(status?.firewall?.status || 'unknown')]">
            {{ status?.firewall?.status }} - {{ status?.firewall?.message }}
          </span>
        </div>
        <div class="status-item">
          <span class="label">Container</span>
          <span :class="['value', getStatusColor(status?.container?.status || 'unknown')]">
            {{ status?.container?.status }} - {{ status?.container?.message }}
          </span>
        </div>
        <div class="status-item">
          <span class="label">Capabilities</span>
          <span :class="['value', getStatusColor(status?.capabilities?.status || 'unknown')]">
            {{ status?.capabilities?.status }} - {{ status?.capabilities?.message }}
          </span>
        </div>
      </div>
      <div class="overall">
        Overall Status: <span :class="getStatusColor(status?.overall || 'unknown')">{{ status?.overall }}</span>
      </div>
    </template>
  </div>
</template>

<style scoped>
.security { padding: 20px; }
.actions { margin-bottom: 20px; display: flex; gap: 10px; }
.status-list { display: flex; flex-direction: column; gap: 10px; }
.status-item { display: flex; gap: 15px; padding: 10px; background: #f9f9f9; border-radius: 4px; }
.label { font-weight: bold; min-width: 120px; }
.overall { margin-top: 20px; font-size: 1.2em; }
.green { color: #22c55e; }
.orange { color: #f97316; }
.red { color: #ef4444; }
.loading, .error { padding: 20px; text-align: center; }
.error { color: red; }
</style>