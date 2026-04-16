<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { useInfraStore } from '../stores/infra'
import { dashboardApi } from '../api/client'
import { useToast } from '../composables/useToast'

const store = useInfraStore()
const { push } = useToast()

const actionLoading = ref('')

async function testHost(name: string) {
  actionLoading.value = name
  try {
    const result = await dashboardApi.testHostConnection(name)
    await store.refreshHosts()
    push(result.message || `${name} test complete`, result.connected ? 'success' : 'error')
  } catch (e: any) {
    push(e.message || `Failed to test ${name}`, 'error')
  } finally {
    actionLoading.value = ''
  }
}

async function setupHost(name: string) {
  actionLoading.value = name
  try {
    await dashboardApi.setupHost(name)
    await store.refreshHosts()
    push(`${name} setup complete`, 'success')
  } catch (e: any) {
    push(e.message || `Failed to setup ${name}`, 'error')
  } finally {
    actionLoading.value = ''
  }
}

onMounted(() => store.refreshHosts())
</script>

<template>
  <div class="hosts">
    <h1>SSH Hosts</h1>
    <div v-if="store.loading && store.hostsStatus.length === 0" class="loading">Loading...</div>
    <template v-else>
      <div class="host-list">
        <div v-for="h in store.hostsStatus" :key="h.name" class="host-item">
          <div class="host-info">
            <span class="name">{{ h.name }}</span>
            <span class="addr">{{ h.hostname }}:{{ h.port }}</span>
            <span :class="['status', h.connected ? 'green' : 'red']">
              {{ h.connected ? 'Connected' : 'Disconnected' }}
            </span>
          </div>
          <div class="host-message">{{ h.message }}</div>
          <div class="host-actions">
            <button
              @click="testHost(h.name)"
              :disabled="actionLoading !== ''"
              class="btn"
            >{{ actionLoading === h.name ? 'Testing...' : 'Test' }}</button>
            <button
              @click="setupHost(h.name)"
              :disabled="actionLoading !== ''"
              class="btn"
            >Setup</button>
          </div>
          <div class="host-details">
            <span v-if="h.chroot_exists !== null && h.chroot_exists !== undefined">
              Chroot: {{ h.chroot_exists ? '✓' : '✗' }}
            </span>
            <span v-if="h.key_installed !== null && h.key_installed !== undefined">
              Key: {{ h.key_installed ? '✓' : '✗' }}
            </span>
          </div>
        </div>
      </div>
    </template>
  </div>
</template>

<style scoped>
.hosts { padding: 20px; }
.host-list { display: flex; flex-direction: column; gap: 12px; }
.host-item {
  padding: 15px;
  background: #f9f9f9;
  border-radius: 4px;
  border: 1px solid #e5e5e5;
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.host-info { display: flex; gap: 15px; align-items: center; }
.host-message { font-size: 0.85em; color: #6b7280; }
.host-actions { display: flex; gap: 8px; }
.host-details { font-size: 0.9em; color: #666; display: flex; gap: 15px; }
.name { font-weight: bold; min-width: 120px; }
.addr { min-width: 150px; color: #374151; }
.status { min-width: 100px; font-weight: 500; }
.green { color: #22c55e; }
.red { color: #ef4444; }
.btn {
  padding: 5px 14px;
  border: 1px solid #d1d5db;
  border-radius: 4px;
  background: white;
  cursor: pointer;
  font-size: 0.85em;
}
.btn:hover:not(:disabled) { background: #f3f4f6; }
.btn:disabled { opacity: 0.5; cursor: not-allowed; }
.loading { padding: 20px; text-align: center; }
</style>
