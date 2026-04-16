<script setup lang="ts">
import { RouterLink, RouterView } from 'vue-router'
</script>

<template>
  <div class="app">
    <header class="header">
      <h1>OpenClaw Dashboard</h1>
      <nav class="nav">
        <RouterLink to="/">Dashboard</RouterLink>
        <RouterLink to="/containers">Containers</RouterLink>
        <RouterLink to="/security">Security</RouterLink>
        <RouterLink to="/hosts">Hosts</RouterLink>
        <RouterLink to="/config">Config</RouterLink>
        <RouterLink to="/logs">Logs</RouterLink>
        <RouterLink to="/terminal">Terminal</RouterLink>
      </nav>
    </header>
    <main class="main">
      <RouterView />
    </main>
  </div>
</template>

<style scoped>
.app { min-height: 100vh; display: flex; flex-direction: column; }
.header { background: #2c3e50; color: white; padding: 15px 20px; }
.header h1 { margin: 0 0 10px 0; font-size: 1.5em; }
.nav { display: flex; gap: 15px; flex-wrap: wrap; }
.nav a { color: #b8c7ce; text-decoration: none; padding: 5px 10px; border-radius: 4px; transition: all 0.2s; }
.nav a:hover { color: white; background: rgba(255,255,255,0.1); }
.nav a.router-link-active { color: white; background: rgba(255,255,255,0.2); }
.main { flex: 1; background: #f5f5f5; }
</style>