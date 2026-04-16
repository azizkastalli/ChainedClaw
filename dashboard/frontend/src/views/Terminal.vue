<script setup lang="ts">
import { ref, onMounted, onUnmounted } from 'vue'
import { Terminal } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import '@xterm/xterm/css/xterm.css'

const terminalRef = ref<HTMLElement | null>(null)
const containerName = ref('agent-dev')
const connected = ref(false)
const error = ref('')
const connecting = ref(false)

let term: Terminal | null = null
let fitAddon: FitAddon | null = null
let ws: WebSocket | null = null

function connectTerminal() {
  if (!containerName.value || connecting.value) return
  error.value = ''; connecting.value = true
  if (term) term.writeln('\n\x1b[33m Connecting to ' + containerName.value + '...\x1b[0m')
  if (ws) { ws.close(); ws = null }
  try {
    const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:'
    ws = new WebSocket(`${protocol}//${window.location.host}/api/containers/${containerName.value}/shell`)
    ws.onopen = () => { connected.value = true; connecting.value = false; if (term) { term.writeln('\x1b[32m✓ Connected\x1b[0m\n') } }
    ws.onmessage = (e) => { if (term) term.write(e.data) }
    ws.onerror = () => { connecting.value = false; error.value = 'Connection error'; if (term) term.writeln('\x1b[31m✗ Error\x1b[0m') }
    ws.onclose = () => { connected.value = false; connecting.value = false; if (term) term.writeln('\x1b[33m⚠ Disconnected\x1b[0m') }
  } catch (e: any) { connecting.value = false; error.value = e.message }
}

function disconnectTerminal() { if (ws) { ws.close(); ws = null }; connected.value = false }

function initTerminal() {
  if (!terminalRef.value) return
  term = new Terminal({
    theme: { background: '#0a0a0a', foreground: '#a3e635', cursor: '#a3e635', selectionBackground: '#166534' },
    fontSize: 13, fontFamily: '"JetBrains Mono", monospace', cursorBlink: true, cursorStyle: 'block', lineHeight: 1.4
  })
  fitAddon = new FitAddon()
  term.loadAddon(fitAddon)
  term.open(terminalRef.value)
  fitAddon.fit()
  term.writeln('\x1b[32mAgent Manager Terminal\x1b[0m')
  term.writeln('\x1b[90mEnter container name and click Connect.\x1b[0m\n')
  term.onData((d) => { if (ws && ws.readyState === WebSocket.OPEN) ws.send(d) })
  window.addEventListener('resize', () => fitAddon?.fit())
}

onMounted(initTerminal)
onUnmounted(() => { if (ws) ws.close(); if (term) term.dispose() })
</script>

<template>
  <div class="terminal-page">
    <div class="page-header">
      <h1 class="page-title">Terminal</h1>
      <p class="page-subtitle">Interactive shell access</p>
    </div>
    <div class="terminal-card">
      <div class="terminal-toolbar">
        <div class="toolbar-left">
          <label>Container</label>
          <input v-model="containerName" placeholder="Container name" :disabled="connected" />
          <button v-if="!connected" @click="connectTerminal" :disabled="connecting || !containerName" class="btn btn-success btn-sm">{{ connecting ? 'Connecting...' : '▶ Connect' }}</button>
          <button v-else @click="disconnectTerminal" class="btn btn-danger btn-sm">■ Disconnect</button>
        </div>
        <div class="status" :class="{ connected }"><span class="dot"></span><span>{{ connected ? 'Connected' : 'Disconnected' }}</span></div>
      </div>
      <div v-if="error" class="error-bar">⚠️ {{ error }}</div>
      <div ref="terminalRef" class="terminal-container"></div>
    </div>
  </div>
</template>

<style scoped>
.terminal-page { max-width: 1200px; }
.terminal-card { background: var(--bg-secondary); border: 1px solid var(--border-color); }
.terminal-toolbar { display: flex; justify-content: space-between; align-items: center; padding: 12px 16px; background: var(--bg-primary); border-bottom: 1px solid var(--border-color); gap: 12px; flex-wrap: wrap; }
.toolbar-left { display: flex; align-items: center; gap: 10px; }
.toolbar-left label { font-size: 12px; color: var(--text-secondary); }
.toolbar-left input { width: 140px; padding: 6px 10px; font-size: 12px; }
.status { display: flex; align-items: center; gap: 6px; font-size: 12px; color: var(--text-muted); }
.status.connected { color: #4ade80; }
.dot { width: 8px; height: 8px; background: var(--border-color); }
.status.connected .dot { background: #4ade80; }
.error-bar { padding: 10px 16px; background: #1f1315; border-bottom: 1px solid #7f1d1d; color: #fca5a5; font-size: 12px; }
.terminal-container { background: #0a0a0a; height: 450px; display: flex; }
:deep(.xterm) { padding: 12px; width: 100%; }
:deep(.xterm-viewport) { overflow-y: auto !important; }
:deep(.xterm-screen) { margin: 0; padding: 0; }
:deep(.xterm-helpers) { left: 0 !important; }
:deep(.xterm-rows) { text-align: left !important; }
:deep(.xterm-container) { text-align: left !important; }
</style>