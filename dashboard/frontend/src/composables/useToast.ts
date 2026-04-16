import { reactive } from 'vue'

export type ToastType = 'success' | 'error' | 'info'

export interface Toast {
  id: number
  message: string
  type: ToastType
}

// Module-scoped reactive list — shared across all imports
const toasts = reactive<Toast[]>([])
let nextId = 0

export function useToast() {
  function push(message: string, type: ToastType = 'info') {
    const id = nextId++
    toasts.push({ id, message, type })
    setTimeout(() => dismiss(id), 4000)
  }

  function dismiss(id: number) {
    const idx = toasts.findIndex(t => t.id === id)
    if (idx !== -1) toasts.splice(idx, 1)
  }

  return { toasts, push, dismiss }
}
