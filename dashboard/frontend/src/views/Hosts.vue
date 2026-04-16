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
  <div class="hosts-page">
    <div class="page-header">
      <h1 class="page-title">SSH Hosts</h1>
      <p class="page-subtitle">Manage remote host connections</p>
    </div>

    <div v-if="store.loading && store.hostsStatus.length === 0" class="loading-container">
      <div class="spinner"></div><span>Loading...</span>
    </div>

    <div v-else class="hosts-grid">
      <div v-for="h in store.hostsStatus" :key="h.name" class="host-card">
        <div class="host-header">
          <div class="host-title-row">
            <h3 class="host-name">{{ h.name }}</h3>
            <span :class="['badge', h.connected ? 'success' : 'danger']">
              {{ h.connected ? 'Connected' : 'Disconnected' }}
            </span>
          </div>
          <div class="host-addr">{{ h.hostname }}:{{ h.port }}</div>
        </div>
        
        <p class="host-message">{{ h.message }}</p>
        
        <div class="host-details">
          <span v-if="h.chroot_exists !== null && h.chroot_exists !== undefined" class="detail-item">
            <span class="detail-label">Chroot</span>
            <span :class="['detail-value', h.chroot_exists ? 'success' : 'danger']">
              {{ h.chroot_exists ? '✓' : '✗' }}
            </span>
          </span>
          <span v-if="h.key_installed !== null && h.key_installed !== undefined" class="detail-item">
            <span class="detail-label">Key</span>
            <span :class="['detail-value', h.key_installed ? 'success' : 'danger']">
              {{ h.key_installed ? '✓' : '✗' }}
            </span>
          </span>
        </div>
        
        <div class="host-actions">
          <button @click="testHost(h.name)" :disabled="actionLoading !== ''" class="btn btn-secondary btn-sm">
            {{ actionLoading === h.name ? 'Testing...' : 'Test' }}
          </button>
          <button @click="setupHost(h.name)" :disabled="actionLoading !== ''" class="btn btn-primary btn-sm">
            Setup
          </button>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.hosts-page { max-width: 1000px; }
.hosts-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 12px; }
.host-card { background: var(--bg-secondary); border: 1px solid var(--border-color); padding: 16px; }
.host-header { margin-bottom: 8px; }
.host-title-row { display: flex; justify-content: space-between; align-items: center; margin-bottom: 4px; }
.host-name { font-size: 14px; font-weight: 600; color: var(--text-primary); margin: 0; }
.host-addr { font-size: 12px; color: var(--text-secondary); }
.host-message { font-size: 12px; color: var(--text-muted); margin: 0 0 12px 0; }
.host-details { display: flex; gap: 16px; padding: 10px 0; border-top: 1px solid var(--border-color); margin-bottom: 12px; }
.detail-item { display: flex; gap: 6px; font-size: 12px; }
.detail-label { color: var(--text-secondary); }
.detail-value.success { color: #4ade80; }
.detail-value.danger { color: #f87171; }
.host-actions { display: flex; gap: 6px; }
</style>