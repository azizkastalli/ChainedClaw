<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { RouterLink, RouterView, useRoute } from 'vue-router'

const route = useRoute()
const sidebarCollapsed = ref(false)
const isDarkMode = ref(true)

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

function toggleTheme() {
  isDarkMode.value = !isDarkMode.value
  localStorage.setItem('theme', isDarkMode.value ? 'dark' : 'light')
  applyTheme()
}

function applyTheme() {
  document.documentElement.setAttribute('data-theme', isDarkMode.value ? 'dark' : 'light')
}

onMounted(() => {
  const saved = localStorage.getItem('theme')
  if (saved) {
    isDarkMode.value = saved === 'dark'
  }
  applyTheme()
})
</script>

<template>
  <div class="app-container">
    <!-- Sidebar -->
    <aside :class="['sidebar', { collapsed: sidebarCollapsed }]">
      <div class="sidebar-header">
        <div class="logo">
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
        <button v-if="!sidebarCollapsed" @click="toggleTheme" class="theme-toggle">
          {{ isDarkMode ? '☀️ Light' : '🌙 Dark' }}
        </button>
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
/* Dark Theme (default) */
:root, [data-theme="dark"] {
  --bg-primary: #0f0f0f;
  --bg-secondary: #1a1a1a;
  --bg-tertiary: #252525;
  --border-color: #2a2a2a;
  --text-primary: #e5e5e5;
  --text-secondary: #888;
  --text-muted: #666;
  --accent-blue: #2563eb;
  --accent-green: #16a34a;
  --accent-red: #dc2626;
}

/* Light Theme */
[data-theme="light"] {
  --bg-primary: #f5f5f5;
  --bg-secondary: #ffffff;
  --bg-tertiary: #e5e5e5;
  --border-color: #d4d4d4;
  --text-primary: #1a1a1a;
  --text-secondary: #525252;
  --text-muted: #737373;
  --accent-blue: #2563eb;
  --accent-green: #16a34a;
  --accent-red: #dc2626;
}

/* Global Styles */
* {
  margin: 0;
  padding: 0;
  box-sizing: border-box;
}

body {
  font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
  background: var(--bg-primary);
  color: var(--text-primary);
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
  background: var(--bg-secondary);
  color: var(--text-primary);
  display: flex;
  flex-direction: column;
  transition: width 0.2s ease;
  position: fixed;
  left: 0;
  top: 0;
  bottom: 0;
  z-index: 100;
  border-right: 1px solid var(--border-color);
}

.sidebar.collapsed {
  width: 56px;
}

.sidebar-header {
  padding: 16px;
  border-bottom: 1px solid var(--border-color);
  display: flex;
  justify-content: space-between;
  align-items: center;
}

.logo {
  display: flex;
  align-items: center;
  gap: 10px;
}

.logo-text {
  font-size: 15px;
  font-weight: 600;
  color: var(--text-primary);
}

.collapse-btn {
  background: var(--bg-tertiary);
  border: none;
  color: var(--text-secondary);
  width: 24px;
  height: 24px;
  display: flex;
  align-items: center;
  justify-content: center;
  cursor: pointer;
  font-size: 12px;
}

.collapse-btn:hover {
  background: var(--border-color);
  color: var(--text-primary);
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
  color: var(--text-secondary);
  text-decoration: none;
  transition: all 0.15s ease;
  font-weight: 500;
  font-size: 13px;
}

.nav-item:hover {
  background: var(--bg-tertiary);
  color: var(--text-primary);
}

.nav-item.active {
  background: var(--accent-blue);
  color: #ffffff;
}

.nav-icon {
  font-size: 16px;
  width: 20px;
  text-align: center;
}

.sidebar-footer {
  padding: 12px 16px;
  border-top: 1px solid var(--border-color);
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.theme-toggle {
  background: var(--bg-tertiary);
  border: 1px solid var(--border-color);
  color: var(--text-primary);
  padding: 8px 12px;
  font-size: 12px;
  cursor: pointer;
  text-align: left;
}

.theme-toggle:hover {
  background: var(--border-color);
}

.version {
  color: var(--text-muted);
  font-size: 11px;
}

/* Main Content */
.main-content {
  flex: 1;
  margin-left: 220px;
  padding: 20px;
  min-height: 100vh;
  transition: margin-left 0.2s ease;
  background: var(--bg-primary);
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
  color: var(--text-primary);
  margin-bottom: 4px;
}

.page-subtitle {
  color: var(--text-muted);
  font-size: 13px;
}

/* Card Styles */
.card {
  background: var(--bg-secondary);
  border: 1px solid var(--border-color);
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
  color: var(--text-primary);
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
  background: var(--accent-blue);
  color: #ffffff;
}

.btn-primary:hover:not(:disabled) {
  background: #1d4ed8;
}

.btn-success {
  background: var(--accent-green);
  color: #ffffff;
}

.btn-success:hover:not(:disabled) {
  background: #15803d;
}

.btn-danger {
  background: var(--accent-red);
  color: #ffffff;
}

.btn-danger:hover:not(:disabled) {
  background: #b91c1c;
}

.btn-secondary {
  background: var(--bg-tertiary);
  color: var(--text-primary);
  border: 1px solid var(--border-color);
}

.btn-secondary:hover:not(:disabled) {
  background: var(--border-color);
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
  color: var(--text-muted);
}

.spinner {
  width: 32px;
  height: 32px;
  border: 3px solid var(--border-color);
  border-top-color: var(--accent-blue);
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
  .sidebar .version,
  .sidebar .theme-toggle {
    display: none;
  }
  
  .main-content {
    margin-left: 56px;
  }
}

/* Input Styles */
input, select {
  background: var(--bg-secondary);
  border: 1px solid var(--border-color);
  color: var(--text-primary);
  padding: 8px 12px;
  font-size: 13px;
  outline: none;
}

input:focus, select:focus {
  border-color: var(--accent-blue);
}

input::placeholder {
  color: var(--text-muted);
}

input:disabled {
  background: var(--bg-tertiary);
  color: var(--text-muted);
}

/* Table Styles */
table {
  width: 100%;
  border-collapse: collapse;
}

th, td {
  padding: 10px 12px;
  text-align: left;
  border-bottom: 1px solid var(--border-color);
}

th {
  font-weight: 600;
  color: var(--text-secondary);
  font-size: 12px;
  text-transform: uppercase;
}

td {
  color: var(--text-primary);
  font-size: 13px;
}

tr:hover {
  background: var(--bg-tertiary);
}
</style>