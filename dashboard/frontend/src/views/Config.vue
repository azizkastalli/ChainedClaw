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
  <div class="config-page">
    <div class="page-header">
      <h1 class="page-title">Configuration</h1>
      <p class="page-subtitle">Manage application settings</p>
    </div>

    <div v-if="loading" class="loading-container"><div class="spinner"></div><span>Loading...</span></div>
    <div v-else-if="error" class="error-message">{{ error }}</div>

    <template v-else>
      <div class="tabs">
        <button :class="['tab', { active: activeTab === 'config' }]" @click="activeTab = 'config'">config.json</button>
        <button :class="['tab', { active: activeTab === 'env' }]" @click="activeTab = 'env'">.env</button>
      </div>

      <div v-if="activeTab === 'config'" class="editor-card">
        <textarea v-model="configText" rows="20" :class="['config-textarea', { 'has-error': configParseError }]"></textarea>
        <p v-if="configParseError" class="parse-error">{{ configParseError }}</p>
        <div class="actions">
          <button @click="saveConfig" :disabled="saving || !!configParseError" class="btn btn-primary btn-sm">
            {{ saving ? 'Saving...' : 'Save Config' }}
          </button>
          <button @click="initKeys" class="btn btn-secondary btn-sm">Init SSH Keys</button>
        </div>
      </div>

      <div v-if="activeTab === 'env'" class="editor-card">
        <div class="env-list">
          <div v-for="(_value, key) in env" :key="key" class="env-item">
            <label>{{ key }}</label>
            <input v-model="env[key]" type="text" />
          </div>
        </div>
        <div class="actions">
          <button @click="saveEnv" :disabled="saving" class="btn btn-primary btn-sm">
            {{ saving ? 'Saving...' : 'Save .env' }}
          </button>
        </div>
      </div>
    </template>
  </div>
</template>

<style scoped>
.config-page { max-width: 900px; }
.tabs { display: flex; gap: 4px; margin-bottom: 12px; }
.tab { padding: 10px 20px; background: var(--bg-secondary); border: 1px solid var(--border-color); color: var(--text-secondary); cursor: pointer; font-size: 13px; font-weight: 500; }
.tab:hover { background: var(--bg-tertiary); color: var(--text-primary); }
.tab.active { background: var(--accent-blue); border-color: var(--accent-blue); color: #fff; }
.editor-card { background: var(--bg-secondary); border: 1px solid var(--border-color); padding: 16px; }
.config-textarea { width: 100%; font-family: 'JetBrains Mono', monospace; font-size: 12px; padding: 12px; border: 1px solid var(--border-color); background: var(--bg-primary); color: var(--text-primary); resize: vertical; box-sizing: border-box; outline: none; }
.config-textarea:focus { border-color: var(--accent-blue); }
.config-textarea.has-error { border-color: #dc2626; }
.parse-error { margin: 8px 0 0 0; color: #f87171; font-size: 12px; font-family: monospace; }
.env-list { display: flex; flex-direction: column; gap: 10px; margin-bottom: 16px; }
.env-item { display: flex; gap: 12px; align-items: center; }
.env-item label { min-width: 180px; font-size: 13px; color: var(--text-secondary); font-weight: 500; }
.env-item input { flex: 1; padding: 8px 12px; font-size: 13px; }
.actions { display: flex; gap: 8px; margin-top: 16px; }
</style>