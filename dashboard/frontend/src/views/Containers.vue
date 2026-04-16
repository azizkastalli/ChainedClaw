<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { dashboardApi, type Container } from '../api/client'

const containers = ref<Container[]>([])
const loading = ref(true)
const error = ref('')
const actionLoading = ref('')

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

function getStatusColor(s: string): string {
  return s === 'running' ? 'green' : 'gray'
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
          <span class="name">{{ c.name }}</span>
          <span :class="['status', getStatusColor(c.status)]">{{ c.status }}</span>
          <span class="image">{{ c.image }}</span>
        </div>
      </div>
    </template>
  </div>
</template>

<style scoped>
.containers { padding: 20px; }
.actions { margin-bottom: 20px; display: flex; gap: 10px; }
.container-list { display: flex; flex-direction: column; gap: 8px; }
.container-item { display: flex; gap: 15px; padding: 10px; background: #f9f9f9; border-radius: 4px; }
.name { font-weight: bold; min-width: 150px; }
.status { min-width: 100px; }
.green { color: #22c55e; }
.gray { color: #6b7280; }
.loading, .error { padding: 20px; text-align: center; }
.error { color: red; }
</style>