<script setup lang="ts">
import { ref, onMounted, onUnmounted } from 'vue'
import { Terminal } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import '@xterm/xterm/css/xterm.css'

const terminalRef = ref<HTMLElement | null>(null)
const containerName = ref('agent-dev')
const connected = ref(false)
const error = ref('')

let term: Terminal | null = null
let fitAddon: FitAddon | null = null
let ws: WebSocket | null = null

function connectTerminal() {
  if (!containerName.value) return
  
  error.value = ''
  connected.value = false
  
  try {
    // Note: This would need a WebSocket endpoint on the backend for shell access
    // For now, this is a placeholder that shows terminal UI
    if (term && fitAddon) {
      term.writeln('OpenClaw Terminal')
      term.writeln(`Container: ${containerName.value}`)
      term.writeln('')
      term.writeln('To execute commands inside the container, run:')
      term.writeln(`  docker exec -it ${containerName.value} bash`)
      term.writeln('')
      term.writeln('Or use: make shell')
    }
  } catch (e: any) {
    error.value = e.message
  }
}

function initTerminal() {
  if (!terminalRef.value) return
  
  term = new Terminal({
    theme: {
      background: '#1e1e1e',
      foreground: '#d4d4d4'
    },
    fontSize: 14,
    fontFamily: 'monospace'
  })
  
  fitAddon = new FitAddon()
  term.loadAddon(fitAddon)
  term.open(terminalRef.value)
  fitAddon.fit()
  
  window.addEventListener('resize', () => fitAddon?.fit())
  
  connectTerminal()
}

function cleanup() {
  if (ws) ws.close()
  if (term) term.dispose()
  window.removeEventListener('resize', () => fitAddon?.fit())
}

onMounted(initTerminal)
onUnmounted(cleanup)
</script>

<template>
  <div class="terminal-view">
    <h1>Terminal</h1>
    <div class="controls">
      <input v-model="containerName" placeholder="Container name" />
      <button @click="connectTerminal">Connect</button>
    </div>
    <div v-if="error" class="error">{{ error }}</div>
    <div ref="terminalRef" class="terminal-container"></div>
  </div>
</template>

<style scoped>
.terminal-view { padding: 20px; }
.controls { margin-bottom: 15px; display: flex; gap: 10px; }
input { padding: 8px; border: 1px solid #ddd; border-radius: 4px; min-width: 200px; }
.terminal-container { background: #1e1e1e; border-radius: 4px; padding: 10px; height: 500px; }
.error { color: red; padding: 10px; margin-bottom: 10px; }
</style>