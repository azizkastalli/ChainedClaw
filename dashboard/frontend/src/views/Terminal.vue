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
  
  error.value = ''
  connecting.value = true
  
  if (term) {
    term.writeln('')
    term.writeln(`Connecting to ${containerName.value}...`)
  }
  
  if (ws) {
    ws.close()
    ws = null
  }
  
  try {
    const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:'
    const wsUrl = `${protocol}//${window.location.host}/api/containers/${containerName.value}/shell`
    
    ws = new WebSocket(wsUrl)
    
    ws.onopen = () => {
      connected.value = true
      connecting.value = false
      if (term) {
        term.writeln(`Connected to ${containerName.value}`)
      }
    }
    
    ws.onmessage = (event) => {
      if (term) {
        term.write(event.data)
      }
    }
    
    ws.onerror = () => {
      connecting.value = false
      error.value = 'WebSocket connection error'
      if (term) {
        term.writeln('')
        term.writeln('Connection error')
      }
    }
    
    ws.onclose = () => {
      connected.value = false
      connecting.value = false
      if (term) {
        term.writeln('')
        term.writeln('Disconnected')
      }
    }
    
  } catch (e: any) {
    connecting.value = false
    error.value = e.message
    if (term) {
      term.writeln(`Error: ${e.message}`)
    }
  }
}

function disconnectTerminal() {
  if (ws) {
    ws.close()
    ws = null
  }
  connected.value = false
}

function initTerminal() {
  if (!terminalRef.value) return
  
  term = new Terminal({
    theme: {
      background: '#1e1e1e',
      foreground: '#d4d4d4',
      cursor: '#ffffff',
      selectionBackground: '#264f78'
    },
    fontSize: 14,
    fontFamily: 'monospace',
    cursorBlink: true
  })
  
  fitAddon = new FitAddon()
  term.loadAddon(fitAddon)
  term.open(terminalRef.value)
  fitAddon.fit()
  
  term.writeln('OpenClaw Terminal')
  term.writeln('Enter container name and click Connect')
  term.writeln('')
  
  term.onData((data) => {
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(data)
    }
  })
  
  window.addEventListener('resize', handleResize)
}

function handleResize() {
  fitAddon?.fit()
}

function cleanup() {
  if (ws) ws.close()
  if (term) term.dispose()
  window.removeEventListener('resize', handleResize)
}

onMounted(initTerminal)
onUnmounted(cleanup)
</script>

<template>
  <div class="terminal-view">
    <h1>Terminal</h1>
    <div class="controls">
      <input 
        v-model="containerName" 
        placeholder="Container name" 
        :disabled="connected"
      />
      <button 
        v-if="!connected" 
        @click="connectTerminal" 
        :disabled="connecting || !containerName"
      >
        {{ connecting ? 'Connecting...' : 'Connect' }}
      </button>
      <button 
        v-else 
        @click="disconnectTerminal"
        class="btn-danger"
      >
        Disconnect
      </button>
    </div>
    <div v-if="error" class="error">{{ error }}</div>
    <div class="status-bar">
      <span :class="['status-indicator', connected ? 'connected' : 'disconnected']"></span>
      <span>{{ connected ? 'Connected' : 'Disconnected' }}</span>
    </div>
    <div ref="terminalRef" class="terminal-container"></div>
  </div>
</template>

<style scoped>
.terminal-view { padding: 20px; }
.controls { margin-bottom: 15px; display: flex; gap: 10px; align-items: center; }
input { 
  padding: 8px 12px; 
  border: 1px solid #d1d5db; 
  border-radius: 6px; 
  min-width: 200px; 
}
input:disabled { background: #f3f4f6; }
button { 
  padding: 8px 16px; 
  border: 1px solid #d1d5db; 
  border-radius: 6px; 
  background: white; 
  cursor: pointer;
}
button:disabled { opacity: 0.5; cursor: not-allowed; }
.btn-danger { background: #ef4444; color: white; border-color: #ef4444; }
.status-bar { 
  display: flex; 
  align-items: center; 
  gap: 8px; 
  margin-bottom: 10px; 
  font-size: 0.9em; 
  color: #6b7280;
}
.status-indicator { 
  width: 8px; 
  height: 8px; 
  border-radius: 50%; 
}
.status-indicator.connected { background: #22c55e; }
.status-indicator.disconnected { background: #9ca3af; }
.terminal-container { 
  background: #1e1e1e; 
  border-radius: 8px; 
  padding: 10px; 
  height: 500px; 
  overflow: hidden;
}
.error { 
  color: #ef4444; 
  background: #fef2f2; 
  padding: 10px; 
  margin-bottom: 10px; 
  border-radius: 6px;
}
</style>