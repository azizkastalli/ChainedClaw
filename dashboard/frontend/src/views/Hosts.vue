<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { dashboardApi, type SSHHostStatus } from '../api/client'

const hosts = ref<SSHHostStatus[]>([])
const loading = ref(true)
const error = ref('')
const actionLoading = ref('')

async function fetchHosts() {
  try { hosts.value = await dashboardApi.getHostsStatus() }
  catch (e: any) { error.value = e.message }
  finally { loading.value = false }
}

async function testHost(name: string) {
  actionLoading.value = name
  try { await dashboardApi.testHostConnection(name); await fetchHosts() }
  catch (e: any) { error.value = e.message }
  finally { actionLoading.value = '' }
}

async function setupHost(name: string) {
  actionLoading.value = name
  try { await dashboardApi.setupHost(name); await fetchHosts() }
  catch (e: any) { error.value = e.message }
  finally { actionLoading.value = '' }
}

onMounted(fetchHosts)
</script>

<template>
  <div class="hosts">
    <h1>SSH Hosts</h1>
    <div v-if="loading" class="loading">Loading...</div>
    <div v-else-if="error" class="error">{{ error }}</div>
    <template v-else>
      <div class="host-list">
        <div v-for="h in hosts" :key="h.name" class="host-item">
          <div class="host-info">
            <span class="name">{{ h.name }}</span>
            <span class="addr">{{ h.hostname }}:{{ h.port }}</span>
            <span :class="['status', h.connected ? 'green' : 'red']">
              {{ h.connected ? 'Connected' : 'Disconnected' }}
            </span>
          </div>
          <div class="host-actions">
            <button @click="testHost(h.name)" :disabled="actionLoading !== ''">Test</button>
            <button @click="setupHost(h.name)" :disabled="actionLoading !== ''">Setup</button>
          </div>
          <div class="host-details">
            <span v-if="h.chroot_exists !== null">Chroot: {{ h.chroot_exists ? '✓' : '✗' }}</span>
            <span v-if="h.key_installed !== null">Key: {{ h.key_installed ? '✓' : '✗' }}</span>
          </div>
        </div>
      </div>
    </template>
  </div>
</template>

<style scoped>
.hosts { padding: 20px; }
.host-list { display: flex; flex-direction: column; gap: 12px; }
.host-item { padding: 15px; background: #f9f9f9; border-radius: 4px; }
.host-info { display: flex; gap: 15px; margin-bottom: 8px; }
.host-actions { display: flex; gap: 8px; margin-bottom: 8px; }
.host-details { font-size: 0.9em; color: #666; display: flex; gap: 15px; }
.name { font-weight: bold; min-width: 120px; }
.addr { min-width: 150px; }
.status { min-width: 100px; }
.green { color: #22c55e; }
.red { color: #ef4444; }
.loading, .error { padding: 20px; text-align: center; }
.error { color: red; }
</style>