<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { dashboardApi, type AppConfig } from '../api/client'
import { useToast } from '../composables/useToast'

const { push } = useToast()

const config = ref<AppConfig>({ allowed_domains: [], ssh_hosts: [] })
const env = ref<Record<string, string>>({})
const loading = ref(true)
const error = ref('')
const saving = ref(false)
const activeTab = ref('config')
const configParseError = ref('')

const configText = computed({
  get: () => JSON.stringify(config.value, null, 2),
  set: (val: string) => {
    try {
      config.value = JSON.parse(val) as AppConfig
      configParseError.value = ''
    } catch (e) {
      configParseError.value = (e as Error).message
    }
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
    push('Config saved successfully', 'success')
  } catch (e: any) {
    push(e.message || 'Failed to save config', 'error')
  } finally {
    saving.value = false
  }
}

async function saveEnv() {
  saving.value = true
  try {
    await dashboardApi.updateEnv(env.value)
    push('Environment saved successfully', 'success')
  } catch (e: any) {
    push(e.message || 'Failed to save environment', 'error')
  } finally {
    saving.value = false
  }
}

async function initKeys() {
  try {
    await dashboardApi.initKeys()
    push('SSH keys initialized', 'success')
  } catch (e: any) {
    push(e.message || 'Failed to initialize SSH keys', 'error')
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
        <textarea v-model="configText" rows="20" :class="{ 'has-error': configParseError }"></textarea>
        <p v-if="configParseError" class="parse-error">{{ configParseError }}</p>
        <div class="actions">
          <button @click="saveConfig" :disabled="saving || !!configParseError">
            {{ saving ? 'Saving...' : 'Save Config' }}
          </button>
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
.tabs button { padding: 8px 16px; border: 1px solid #d1d5db; border-radius: 6px; background: white; cursor: pointer; }
.tabs button.active { background: #333; color: white; border-color: #333; }
.editor textarea {
  width: 100%;
  font-family: monospace;
  padding: 10px;
  border: 1px solid #ddd;
  border-radius: 4px;
  resize: vertical;
  box-sizing: border-box;
}
.editor textarea.has-error { border-color: #ef4444; }
.parse-error {
  margin: 6px 0 0 0;
  color: #ef4444;
  font-size: 0.85em;
  font-family: monospace;
}
.env-list { display: flex; flex-direction: column; gap: 10px; margin-bottom: 20px; }
.env-item { display: flex; gap: 10px; align-items: center; }
.env-item label { min-width: 200px; font-weight: bold; }
.env-item input { flex: 1; padding: 8px; border: 1px solid #ddd; border-radius: 4px; }
.actions { margin-top: 15px; display: flex; gap: 10px; }
.actions button {
  padding: 8px 16px;
  border: 1px solid #d1d5db;
  border-radius: 6px;
  background: white;
  cursor: pointer;
}
.actions button:hover:not(:disabled) { background: #f3f4f6; }
.actions button:disabled { opacity: 0.5; cursor: not-allowed; }
.loading, .error { padding: 20px; text-align: center; }
.error { color: red; }
</style>
