<script setup lang="ts">
import { ref } from 'vue'
import { RouterLink, RouterView, useRoute } from 'vue-router'

const route = useRoute()
const sidebarCollapsed = ref(false)

const navItems = [
  { path: '/', icon: '📊', label: 'Overview' },
  { path: '/containers', icon: '📦', label: 'Containers' },
  { path: '/security', icon: '🛡️', label: 'Security' },
  { path: '/hosts', icon: '🖥️', label: 'Hosts' },
  { path: '/config', icon: '⚙️', label: 'Config' },
  { path: '/logs', icon: '📋', label: 'Logs' },
  { path: '/terminal', icon: '💻', label: 'Terminal' },
]

function isActive(path: string): boolean {
  return route.path === path
}
</script>

<template>
  <div class="app-container">
    <!-- Sidebar -->
    <aside :class="['sidebar', { collapsed: sidebarCollapsed }]">
      <div class="sidebar-header">
        <div class="logo">
          <span class="logo-icon">🦀</span>
          <span v-if="!sidebarCollapsed" class="logo-text">Agent Manager</span>
        </div>
        <button class="collapse-btn" @click="sidebarCollapsed = !sidebarCollapsed">
          {{ sidebarCollapsed ? '→' : '←' }}
        </button>
      </div>
      
      <nav class="sidebar-nav">
        <RouterLink 
          v-for="item in navItems" 
          :key="item.path"
          :to="item.path"
          :class="['nav-item', { active: isActive(item.path) }]"
        >
          <span class="nav-icon">{{ item.icon }}</span>
          <span v-if="!sidebarCollapsed" class="nav-label">{{ item.label }}</span>
        </RouterLink>
      </nav>
      
      <div class="sidebar-footer">
        <span v-if="!sidebarCollapsed" class="version">v1.0.0</span>
      </div>
    </aside>

    <!-- Main Content -->
    <main class="main-content">
      <RouterView />
    </main>
  </div>
</template>

<style>
/* Global Styles */
* {
  margin: 0;
  padding: 0;
  box-sizing: border-box;
}

body {
  font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
  background: #0f0f0f;
  color: #e5e5e5;
  line-height: 1.6;
}

/* App Container */
.app-container {
  display: flex;
  min-height: 100vh;
}

/* Sidebar */
.sidebar {
  width: 220px;
  background: #1a1a1a;
  color: #e5e5e5;
  display: flex;
  flex-direction: column;
  transition: width 0.2s ease;
  position: fixed;
  left: 0;
  top: 0;
  bottom: 0;
  z-index: 100;
  border-right: 1px solid #2a2a2a;
}

.sidebar.collapsed {
  width: 56px;
}

.sidebar-header {
  padding: 16px;
  border-bottom: 1px solid #2a2a2a;
  display: flex;
  justify-content: space-between;
  align-items: center;
}

.logo {
  display: flex;
  align-items: center;
  gap: 10px;
}

.logo-icon {
  font-size: 22px;
}

.logo-text {
  font-size: 15px;
  font-weight: 600;
  color: #ffffff;
}

.collapse-btn {
  background: #2a2a2a;
  border: none;
  color: #888;
  width: 24px;
  height: 24px;
  display: flex;
  align-items: center;
  justify-content: center;
  cursor: pointer;
  font-size: 12px;
}

.collapse-btn:hover {
  background: #3a3a3a;
  color: #fff;
}

.sidebar-nav {
  flex: 1;
  padding: 8px;
  display: flex;
  flex-direction: column;
  gap: 2px;
}

.nav-item {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 10px 12px;
  color: #888;
  text-decoration: none;
  transition: all 0.15s ease;
  font-weight: 500;
  font-size: 13px;
}

.nav-item:hover {
  background: #252525;
  color: #e5e5e5;
}

.nav-item.active {
  background: #2563eb;
  color: #ffffff;
}

.nav-icon {
  font-size: 16px;
  width: 20px;
  text-align: center;
}

.sidebar-footer {
  padding: 12px 16px;
  border-top: 1px solid #2a2a2a;
}

.version {
  color: #555;
  font-size: 11px;
}

/* Main Content */
.main-content {
  flex: 1;
  margin-left: 220px;
  padding: 20px;
  min-height: 100vh;
  transition: margin-left 0.2s ease;
  background: #0f0f0f;
}

.sidebar.collapsed + .main-content {
  margin-left: 56px;
}

/* Page Header */
.page-header {
  margin-bottom: 20px;
}

.page-title {
  font-size: 22px;
  font-weight: 600;
  color: #ffffff;
  margin-bottom: 4px;
}

.page-subtitle {
  color: #666;
  font-size: 13px;
}

/* Card Styles */
.card {
  background: #1a1a1a;
  border: 1px solid #2a2a2a;
  padding: 20px;
  margin-bottom: 16px;
}

.card-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 16px;
}

.card-title {
  font-size: 15px;
  font-weight: 600;
  color: #ffffff;
}

/* Button Styles */
.btn {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  padding: 8px 14px;
  font-size: 13px;
  font-weight: 500;
  cursor: pointer;
  transition: all 0.15s ease;
  border: none;
  text-decoration: none;
}

.btn-primary {
  background: #2563eb;
  color: #ffffff;
}

.btn-primary:hover:not(:disabled) {
  background: #1d4ed8;
}

.btn-success {
  background: #16a34a;
  color: #ffffff;
}

.btn-success:hover:not(:disabled) {
  background: #15803d;
}

.btn-danger {
  background: #dc2626;
  color: #ffffff;
}

.btn-danger:hover:not(:disabled) {
  background: #b91c1c;
}

.btn-secondary {
  background: #374151;
  color: #e5e5e5;
  border: 1px solid #4b5563;
}

.btn-secondary:hover:not(:disabled) {
  background: #4b5563;
}

.btn:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}

.btn-sm {
  padding: 6px 12px;
  font-size: 12px;
}

/* Status Badge */
.badge {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  padding: 3px 10px;
  font-size: 11px;
  font-weight: 600;
  text-transform: uppercase;
}

.badge-success {
  background: #166534;
  color: #86efac;
}

.badge-warning {
  background: #854d0e;
  color: #fde047;
}

.badge-danger {
  background: #991b1b;
  color: #fca5a5;
}

.badge-info {
  background: #1e40af;
  color: #93c5fd;
}

/* Loading & Error States */
.loading-container {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  padding: 60px 20px;
  color: #666;
}

.spinner {
  width: 32px;
  height: 32px;
  border: 3px solid #2a2a2a;
  border-top-color: #2563eb;
  border-radius: 50%;
  animation: spin 1s linear infinite;
  margin-bottom: 12px;
}

@keyframes spin {
  to { transform: rotate(360deg); }
}

.error-message {
  background: #1f1315;
  border: 1px solid #7f1d1d;
  color: #fca5a5;
  padding: 14px 16px;
  margin-bottom: 16px;
}

/* Responsive */
@media (max-width: 768px) {
  .sidebar {
    width: 56px;
  }
  
  .sidebar .logo-text,
  .sidebar .nav-label,
  .sidebar .version {
    display: none;
  }
  
  .main-content {
    margin-left: 56px;
  }
}

/* Input Styles */
input, select {
  background: #1a1a1a;
  border: 1px solid #3a3a3a;
  color: #e5e5e5;
  padding: 8px 12px;
  font-size: 13px;
  outline: none;
}

input:focus, select:focus {
  border-color: #2563eb;
}

input::placeholder {
  color: #666;
}

input:disabled {
  background: #252525;
  color: #666;
}

/* Table Styles */
table {
  width: 100%;
  border-collapse: collapse;
}

th, td {
  padding: 10px 12px;
  text-align: left;
  border-bottom: 1px solid #2a2a2a;
}

th {
  font-weight: 600;
  color: #888;
  font-size: 12px;
  text-transform: uppercase;
}

td {
  color: #e5e5e5;
  font-size: 13px;
}

tr:hover {
  background: #1f1f1f;
}
</style>