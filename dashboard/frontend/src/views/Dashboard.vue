<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { dashboardApi, type OverallStatus, type Container } from '../api/client'

const status = ref<OverallStatus | null>(null)
const containers = ref<Container[]>([])
const loading = ref(true)
const error = ref('')

async function fetchData() {
  try {
    status.value = await dashboardApi.getOverallStatus()
    containers.value = await dashboardApi.getContainers()
  } catch (e: any) {
    error.value = e.message
  } finally {
    loading.value = false
  }
}

function getSecurityClass(s: string): string {
  return s === 'secure' || s === 'ok' ? 'success' : s === 'warning' || s === 'warn' ? 'warning' : 'danger'
}

function getStatusClass(s: string): string {
  return s === 'running' ? 'success' : 'danger'
}

onMounted(fetchData)
</script>

<template>
  <div class="dashboard-page">
    <div class="page-header">
      <h1 class="page-title">Overview</h1>
      <p class="page-subtitle">Agent Manager infrastructure status</p>
    </div>

    <div v-if="loading" class="loading-container">
      <div class="spinner"></div>
      <span>Loading...</span>
    </div>

    <div v-else-if="error" class="error-message">{{ error }}</div>

    <template v-else>
      <!-- Stats Row -->
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-icon security">🛡️</div>
          <div class="stat-content">
            <span class="stat-label">Security</span>
            <span :class="['stat-value', getSecurityClass(status?.security || 'unknown')]">
              {{ status?.security || 'Unknown' }}
            </span>
          </div>
        </div>
        
        <div class="stat-card">
          <div class="stat-icon containers">📦</div>
          <div class="stat-content">
            <span class="stat-label">Containers</span>
            <span :class="['stat-value', status?.containers_running ? 'success' : 'danger']">
              {{ containers.filter(c => c.status === 'running').length }} / {{ containers.length }}
            </span>
          </div>
        </div>
        
        <div class="stat-card">
          <div class="stat-icon hosts">🖥️</div>
          <div class="stat-content">
            <span class="stat-label">Hosts</span>
            <span class="stat-value info">
              {{ status?.hosts_connected || 0 }} / {{ status?.hosts_total || 0 }}
            </span>
          </div>
        </div>
        
        <div class="stat-card">
          <div class="stat-icon warnings">⚠️</div>
          <div class="stat-content">
            <span class="stat-label">Warnings</span>
            <span :class="['stat-value', (status?.warnings?.length || 0) > 0 ? 'warning' : 'success']">
              {{ status?.warnings?.length || 0 }}
            </span>
          </div>
        </div>
      </div>

      <!-- Containers Section -->
      <div class="card">
        <div class="card-header">
          <h2 class="card-title">Containers</h2>
          <RouterLink to="/containers" class="btn btn-secondary btn-sm">View All →</RouterLink>
        </div>
        <div class="container-grid">
          <div v-for="c in containers.slice(0, 4)" :key="c.name" class="container-item">
            <div class="container-info">
              <span class="container-name">{{ c.name }}</span>
              <span :class="['badge', getStatusClass(c.status)]">
                {{ c.status }}
              </span>
            </div>
            <span class="container-image">{{ c.image.split(':')[0] }}</span>
          </div>
        </div>
      </div>

      <!-- Quick Actions -->
      <div class="card">
        <div class="card-header">
          <h2 class="card-title">Quick Actions</h2>
        </div>
        <div class="quick-actions">
          <RouterLink to="/containers" class="action-btn">
            <span class="action-icon">▶️</span>
            <span>Manage Containers</span>
          </RouterLink>
          <RouterLink to="/security" class="action-btn">
            <span class="action-icon">🛡️</span>
            <span>Security Settings</span>
          </RouterLink>
          <RouterLink to="/terminal" class="action-btn">
            <span class="action-icon">💻</span>
            <span>Open Terminal</span>
          </RouterLink>
          <RouterLink to="/config" class="action-btn">
            <span class="action-icon">⚙️</span>
            <span>Configuration</span>
          </RouterLink>
        </div>
      </div>

      <!-- Issues & Warnings -->
      <div v-if="status?.issues?.length || status?.warnings?.length" class="card alerts-card">
        <div class="card-header">
          <h2 class="card-title">Alerts</h2>
        </div>
        <div class="alerts-list">
          <div v-for="issue in status?.issues" :key="issue" class="alert-item danger">
            <span class="alert-icon">❌</span>
            <span>{{ issue }}</span>
          </div>
          <div v-for="warning in status?.warnings" :key="warning" class="alert-item warning">
            <span class="alert-icon">⚠️</span>
            <span>{{ warning }}</span>
          </div>
        </div>
      </div>
    </template>
  </div>
</template>

<style scoped>
.dashboard-page {
  max-width: 1200px;
}

/* Stats Grid */
.stats-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
  gap: 12px;
  margin-bottom: 20px;
}

.stat-card {
  background: #1a1a1a;
  border: 1px solid #2a2a2a;
  padding: 16px;
  display: flex;
  align-items: center;
  gap: 14px;
}

.stat-icon {
  width: 42px;
  height: 42px;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 20px;
  background: #252525;
  border: 1px solid #3a3a3a;
}

.stat-icon.security { background: #1e3a5f; border-color: #2563eb; }
.stat-icon.containers { background: #14532d; border-color: #16a34a; }
.stat-icon.hosts { background: #713f12; border-color: #ca8a04; }
.stat-icon.warnings { background: #7f1d1d; border-color: #dc2626; }

.stat-content {
  display: flex;
  flex-direction: column;
}

.stat-label {
  font-size: 12px;
  color: #888;
  margin-bottom: 2px;
  text-transform: uppercase;
}

.stat-value {
  font-size: 20px;
  font-weight: 600;
  text-transform: capitalize;
}

.stat-value.success { color: #4ade80; }
.stat-value.warning { color: #facc15; }
.stat-value.danger { color: #f87171; }
.stat-value.info { color: #60a5fa; }

/* Container Grid */
.container-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
  gap: 10px;
}

.container-item {
  background: #0f0f0f;
  border: 1px solid #2a2a2a;
  padding: 12px;
}

.container-item:hover {
  border-color: #3a3a3a;
}

.container-info {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 4px;
}

.container-name {
  font-weight: 500;
  color: #e5e5e5;
  font-size: 13px;
}

.container-image {
  font-size: 11px;
  color: #666;
}

/* Quick Actions */
.quick-actions {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(160px, 1fr));
  gap: 10px;
}

.action-btn {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 14px;
  background: #0f0f0f;
  border: 1px solid #2a2a2a;
  text-decoration: none;
  color: #e5e5e5;
  font-weight: 500;
  font-size: 13px;
  transition: all 0.15s;
}

.action-btn:hover {
  background: #1a1a1a;
  border-color: #2563eb;
  color: #60a5fa;
}

.action-icon {
  font-size: 18px;
}

/* Alerts */
.alerts-card {
  border-left: 3px solid #f59e0b;
}

.alerts-list {
  display: flex;
  flex-direction: column;
  gap: 6px;
}

.alert-item {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 10px 14px;
  font-size: 13px;
}

.alert-item.danger {
  background: #1f1315;
  border: 1px solid #7f1d1d;
  color: #fca5a5;
}

.alert-item.warning {
  background: #1c1917;
  border: 1px solid #78350f;
  color: #fde68a;
}

.alert-icon {
  font-size: 14px;
}
</style>