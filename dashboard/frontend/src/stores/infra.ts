import { ref } from 'vue'
import { defineStore } from 'pinia'
import { dashboardApi, type Container, type OverallStatus, type SSHHostStatus } from '../api/client'

export const useInfraStore = defineStore('infra', () => {
  const containers = ref<Container[]>([])
  const overallStatus = ref<OverallStatus | null>(null)
  const hostsStatus = ref<SSHHostStatus[]>([])
  const loading = ref(false)
  const error = ref('')

  async function refresh() {
    loading.value = true
    try {
      const [s, c, h] = await Promise.all([
        dashboardApi.getOverallStatus(),
        dashboardApi.getContainers(),
        dashboardApi.getHostsStatus(),
      ])
      overallStatus.value = s
      containers.value = c
      hostsStatus.value = h
      error.value = ''
    } catch (e: any) {
      error.value = e.message || 'Fetch failed'
    } finally {
      loading.value = false
    }
  }

  async function refreshContainers() {
    try {
      containers.value = await dashboardApi.getContainers()
    } catch (e: any) {
      error.value = e.message || 'Failed to refresh containers'
    }
  }

  async function refreshHosts() {
    try {
      hostsStatus.value = await dashboardApi.getHostsStatus()
    } catch (e: any) {
      error.value = e.message || 'Failed to refresh hosts'
    }
  }

  return { containers, overallStatus, hostsStatus, loading, error, refresh, refreshContainers, refreshHosts }
})
