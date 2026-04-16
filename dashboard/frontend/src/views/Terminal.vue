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
    term.writeln('\x1b[33m Connecting to ' + containerName.value + '...\x1b[0m')
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
        term.writeln('\x1b[32m✓ Connected to ' + containerName.value + '\x1b[0m')
        term.writeln('\x1b[90mType commands and press Enter. Type "exit" to disconnect.\x1b[0m')
        term.writeln('')
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
        term.writeln('\x1b[31m✗ Connection error\x1b[0m')
      }
    }
    
    ws.onclose = () => {
      connected.value = false
      connecting.value = false
      if (term) {
        term.writeln('')
        term.writeln('\x1b[33m⚠ Disconnected\x1b[0m')
      }
    }
    
  } catch (e: any) {
    connecting.value = false
    error.value = e.message
    if (term) {
      term.writeln('\x1b[31m✗ Error: ' + e.message + '\x1b[0m')
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
      background: '#0f172a',
      foreground: '#e2e8f0',
      cursor: '#60a5fa',
      cursorAccent: '#0f172a',
      selectionBackground: '#3b82f6',
      black: '#1e293b',
      red: '#f87171',
      green: '#4ade80',
      yellow: '#facc15',
      blue: '#60a5fa',
      magenta: '#c084fc',
      cyan: '#22d3ee',
      white: '#f1f5f9',
      brightBlack: '#475569',
      brightRed: '#fca5a5',
      brightGreen: '#86efac',
      brightYellow: '#fde047',
      brightBlue: '#93c5fd',
      brightMagenta: '#d8b4fe',
      brightCyan: '#67e8f9',
      brightWhite: '#f8fafc'
    },
    fontSize: 14,
    fontFamily: '"JetBrains Mono", "Fira Code", "Cascadia Code", monospace',
    cursorBlink: true,
    cursorStyle: 'bar',
    lineHeight: 1.5
  })
  
  fitAddon = new FitAddon()
  term.loadAddon(fitAddon)
  term.open(terminalRef.value)
  fitAddon.fit()
  
  term.writeln('\x1b[1;36m╔══════════════════════════════════════════════╗\x1b[0m')
  term.writeln('\x1b[1;36m║        🦀 OpenClaw Terminal                  ║\x1b[0m')
  term.writeln('\x1b[1;36m╚══════════════════════════════════════════════╝\x1b[0m')
  term.writeln('')
  term.writeln('\x1b[90mEnter container name and click Connect to start.\x1b[0m')
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
  <div class="terminal-page">
    <div class="page-header">
      <div>
        <h1 class="page-title">Terminal</h1>
        <p class="page-subtitle">Interactive shell access to containers</p>
      </div>
    </div>

    <div class="terminal-card">
      <div class="terminal-toolbar">
        <div class="toolbar-left">
          <div class="input-group">
            <label>Container</label>
            <input 
              v-model="containerName" 
              placeholder="Container name" 
              :disabled="connected"
              class="container-input"
            />
          </div>
          <button 
            v-if="!connected" 
            @click="connectTerminal" 
            :disabled="connecting || !containerName"
            class="btn btn-success"
          >
            <span v-if="connecting">Connecting...</span>
            <span v-else>▶ Connect</span>
          </button>
          <button 
            v-else 
            @click="disconnectTerminal"
            class="btn btn-danger"
          >
            ■ Disconnect
          </button>
        </div>
        <div class="toolbar-right">
          <div class="status-indicator" :class="{ connected }">
            <span class="status-dot"></span>
            <span class="status-text">{{ connected ? 'Connected' : 'Disconnected' }}</span>
          </div>
        </div>
      </div>
      
      <div v-if="error" class="error-banner">
        <span>⚠️</span>
        {{ error }}
      </div>
      
      <div ref="terminalRef" class="terminal-container"></div>
    </div>
  </div>
</template>

<style scoped>
.terminal-page {
  max-width: 1200px;
}

.terminal-card {
  background: white;
  border-radius: 16px;
  overflow: hidden;
  box-shadow: 0 1px 3px rgba(0, 0, 0, 0.05), 0 4px 12px rgba(0, 0, 0, 0.05);
}

.terminal-toolbar {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 16px 20px;
  background: #f8fafc;
  border-bottom: 1px solid #e2e8f0;
  flex-wrap: wrap;
  gap: 12px;
}

.toolbar-left {
  display: flex;
  align-items: center;
  gap: 16px;
}

.input-group {
  display: flex;
  align-items: center;
  gap: 8px;
}

.input-group label {
  font-size: 14px;
  font-weight: 500;
  color: #64748b;
}

.container-input {
  padding: 8px 14px;
  border: 1px solid #e2e8f0;
  border-radius: 8px;
  font-size: 14px;
  min-width: 180px;
  transition: all 0.2s;
}

.container-input:focus {
  outline: none;
  border-color: #3b82f6;
  box-shadow: 0 0 0 3px rgba(59, 130, 246, 0.1);
}

.container-input:disabled {
  background: #f1f5f9;
  color: #94a3b8;
}

.toolbar-right {
  display: flex;
  align-items: center;
}

.status-indicator {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 6px 14px;
  border-radius: 20px;
  background: #f1f5f9;
  transition: all 0.2s;
}

.status-indicator.connected {
  background: #dcfce7;
}

.status-dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: #94a3b8;
  transition: background 0.2s;
}

.status-indicator.connected .status-dot {
  background: #22c55e;
  box-shadow: 0 0 8px rgba(34, 197, 94, 0.5);
}

.status-text {
  font-size: 13px;
  font-weight: 500;
  color: #64748b;
}

.status-indicator.connected .status-text {
  color: #166534;
}

.error-banner {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 12px 20px;
  background: #fef2f2;
  color: #991b1b;
  font-size: 14px;
  border-bottom: 1px solid #fecaca;
}

.terminal-container {
  background: #0f172a;
  height: 500px;
  padding: 4px;
}

/* Override xterm styles */
:deep(.xterm) {
  padding: 16px;
}

:deep(.xterm-viewport) {
  border-radius: 0;
}
</style>