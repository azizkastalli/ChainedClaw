<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { dashboardApi } from '../api/client'

const config = ref<Record<string, any>>({})
const env = ref<Record<string, string>>({})
const loading = ref(true)
const error = ref('')
const saving = ref(false)
const activeTab = ref('config')

// Computed property for config text
const configText = computed({
  get: () => JSON.stringify(config.value, null, 2),
  set: (val: string) => {
    try { config.value = JSON.parse(val) } catch (e) { /* ignore parse errors while typing */ }
  }
})

async function fetchData() {
  try {
    const [configData, envData] = await Promise.all([
      dashboardApi.getConfig(),
      dashboardApi.getEnv()
    ])
    config.value = configData
    env.value = envData.variables
  } catch (e: any) {
    error.value = e.message
  } finally {
    loading.value = false
  }
}

async function saveConfig() {
  saving.value = true
  try {
    await dashboardApi.updateConfig(config.value)
    alert('Config saved!')
  } catch (e: any) {
    error.value = e.message
  } finally {
    saving.value = false
  }
}

async function saveEnv() {
  saving.value = true
  try {
    await dashboardApi.updateEnv(env.value)
    alert('Environment saved!')
  } catch (e: any) {
    error.value = e.message
  } finally {
    saving.value = false
  }
}

async function initKeys() {
  try {
    await dashboardApi.initKeys()
    alert('SSH keys initialized!')
  } catch (e: any) {
    error.value = e.message
  }
}

onMounted(fetchData)
</script>

<template>
  <div class="config">
    <h1>Configuration</h1>
    <div v-if="loading" class="loading">Loading...</div>
    <div v-else-if="error" class="error">{{ error }}</div>
    <template v-else>
      <div class="tabs">
        <button :class="{ active: activeTab === 'config' }" @click="activeTab = 'config'">config.json</button>
        <button :class="{ active: activeTab === 'env' }" @click="activeTab = 'env'">.env</button>
      </div>

      <div v-if="activeTab === 'config'" class="editor">
        <textarea v-model="configText" rows="20"></textarea>
        <div class="actions">
          <button @click="saveConfig" :disabled="saving">{{ saving ? 'Saving...' : 'Save Config' }}</button>
          <button @click="initKeys">Init SSH Keys</button>
        </div>
      </div>

      <div v-if="activeTab === 'env'" class="editor">
        <div class="env-list">
          <div v-for="(_value, key) in env" :key="key" class="env-item">
            <label>{{ key }}</label>
            <input v-model="env[key]" type="text" />
          </div>
        </div>
        <div class="actions">
          <button @click="saveEnv" :disabled="saving">{{ saving ? 'Saving...' : 'Save .env' }}</button>
        </div>
      </div>
    </template>
  </div>
</template>

<style scoped>
.config { padding: 20px; }
.tabs { margin-bottom: 20px; display: flex; gap: 10px; }
.tabs button.active { background: #333; color: white; }
.editor textarea { width: 100%; font-family: monospace; padding: 10px; border: 1px solid #ddd; border-radius: 4px; }
.env-list { display: flex; flex-direction: column; gap: 10px; margin-bottom: 20px; }
.env-item { display: flex; gap: 10px; align-items: center; }
.env-item label { min-width: 200px; font-weight: bold; }
.env-item input { flex: 1; padding: 8px; border: 1px solid #ddd; border-radius: 4px; }
.actions { margin-top: 15px; display: flex; gap: 10px; }
.loading, .error { padding: 20px; text-align: center; }
.error { color: red; }
</style>