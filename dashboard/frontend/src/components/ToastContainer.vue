<script setup lang="ts">
import { useToast } from '../composables/useToast'

const { toasts, dismiss } = useToast()
</script>

<template>
  <Teleport to="body">
    <div class="toast-wrapper">
      <TransitionGroup name="toast">
        <div
          v-for="toast in toasts"
          :key="toast.id"
          :class="['toast', `toast--${toast.type}`]"
          @click="dismiss(toast.id)"
          role="alert"
        >
          <span class="toast-icon">
            {{ toast.type === 'success' ? '✓' : toast.type === 'error' ? '✗' : 'ℹ' }}
          </span>
          <span class="toast-message">{{ toast.message }}</span>
          <button class="toast-close" @click.stop="dismiss(toast.id)" aria-label="Dismiss">&times;</button>
        </div>
      </TransitionGroup>
    </div>
  </Teleport>
</template>

<style scoped>
.toast-wrapper {
  position: fixed;
  bottom: 24px;
  right: 24px;
  z-index: 9999;
  display: flex;
  flex-direction: column;
  gap: 10px;
  pointer-events: none;
}

.toast {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 12px 16px;
  border-radius: 8px;
  min-width: 260px;
  max-width: 420px;
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.15);
  cursor: pointer;
  pointer-events: all;
  font-size: 0.9em;
  border-left: 4px solid transparent;
}

.toast--success {
  background: #f0fdf4;
  border-left-color: #22c55e;
  color: #166534;
}

.toast--error {
  background: #fef2f2;
  border-left-color: #ef4444;
  color: #991b1b;
}

.toast--info {
  background: #eff6ff;
  border-left-color: #3b82f6;
  color: #1e40af;
}

.toast-icon {
  font-weight: bold;
  flex-shrink: 0;
}

.toast-message {
  flex: 1;
  word-break: break-word;
}

.toast-close {
  background: none;
  border: none;
  cursor: pointer;
  font-size: 1.2em;
  line-height: 1;
  opacity: 0.6;
  color: inherit;
  flex-shrink: 0;
  padding: 0;
}
.toast-close:hover { opacity: 1; }

/* TransitionGroup animations */
.toast-enter-active {
  transition: all 0.25s ease-out;
}
.toast-leave-active {
  transition: all 0.2s ease-in;
}
.toast-enter-from {
  opacity: 0;
  transform: translateX(40px);
}
.toast-leave-to {
  opacity: 0;
  transform: translateX(40px);
}
</style>
