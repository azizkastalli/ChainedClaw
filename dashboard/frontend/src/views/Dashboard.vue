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
      <h1 class="page-title">Dashboard</h1>
      <p class="page-subtitle">OpenClaw infrastructure overview</p>
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
  grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
  gap: 16px;
  margin-bottom: 24px;
}

.stat-card {
  background: white;
  border-radius: 16px;
  padding: 20px;
  display: flex;
  align-items: center;
  gap: 16px;
  box-shadow: 0 1px 3px rgba(0, 0, 0, 0.05), 0 4px 12px rgba(0, 0, 0, 0.05);
  transition: transform 0.2s, box-shadow 0.2s;
}

.stat-card:hover {
  transform: translateY(-2px);
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.1), 0 8px 24px rgba(0, 0, 0, 0.1);
}

.stat-icon {
  width: 48px;
  height: 48px;
  border-radius: 12px;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 24px;
}

.stat-icon.security { background: linear-gradient(135deg, #dbeafe 0%, #bfdbfe 100%); }
.stat-icon.containers { background: linear-gradient(135deg, #d1fae5 0%, #a7f3d0 100%); }
.stat-icon.hosts { background: linear-gradient(135deg, #fef3c7 0%, #fde68a 100%); }
.stat-icon.warnings { background: linear-gradient(135deg, #fee2e2 0%, #fecaca 100%); }

.stat-content {
  display: flex;
  flex-direction: column;
}

.stat-label {
  font-size: 13px;
  color: #6b7280;
  margin-bottom: 4px;
}

.stat-value {
  font-size: 24px;
  font-weight: 700;
  text-transform: capitalize;
}

.stat-value.success { color: #16a34a; }
.stat-value.warning { color: #d97706; }
.stat-value.danger { color: #dc2626; }
.stat-value.info { color: #2563eb; }

/* Container Grid */
.container-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
  gap: 12px;
}

.container-item {
  background: #f9fafb;
  border-radius: 12px;
  padding: 14px;
  transition: background 0.2s;
}

.container-item:hover {
  background: #f3f4f6;
}

.container-info {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 6px;
}

.container-name {
  font-weight: 600;
  color: #1f2937;
  font-size: 14px;
}

.container-image {
  font-size: 12px;
  color: #6b7280;
}

/* Quick Actions */
.quick-actions {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
  gap: 12px;
}

.action-btn {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 16px;
  background: linear-gradient(135deg, #f8fafc 0%, #f1f5f9 100%);
  border-radius: 12px;
  text-decoration: none;
  color: #374151;
  font-weight: 500;
  transition: all 0.2s;
  border: 1px solid #e2e8f0;
}

.action-btn:hover {
  background: linear-gradient(135deg, #eff6ff 0%, #dbeafe 100%);
  border-color: #93c5fd;
  color: #1d4ed8;
  transform: translateY(-2px);
}

.action-icon {
  font-size: 20px;
}

/* Alerts */
.alerts-card {
  border-left: 4px solid #f59e0b;
}

.alerts-list {
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.alert-item {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 12px 16px;
  border-radius: 8px;
  font-size: 14px;
}

.alert-item.danger {
  background: #fef2f2;
  color: #991b1b;
}

.alert-item.warning {
  background: #fffbeb;
  color: #92400e;
}

.alert-icon {
  font-size: 16px;
}
</style>