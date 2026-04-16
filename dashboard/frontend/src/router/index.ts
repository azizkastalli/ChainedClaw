import { createRouter, createWebHistory } from 'vue-router'
import Dashboard from '../views/Dashboard.vue'
import Containers from '../views/Containers.vue'
import Security from '../views/Security.vue'
import Hosts from '../views/Hosts.vue'
import Config from '../views/Config.vue'
import Logs from '../views/Logs.vue'
import Terminal from '../views/Terminal.vue'

const router = createRouter({
  history: createWebHistory(import.meta.env.BASE_URL),
  routes: [
    {
      path: '/',
      name: 'dashboard',
      component: Dashboard
    },
    {
      path: '/containers',
      name: 'containers',
      component: Containers
    },
    {
      path: '/security',
      name: 'security',
      component: Security
    },
    {
      path: '/hosts',
      name: 'hosts',
      component: Hosts
    },
    {
      path: '/config',
      name: 'config',
      component: Config
    },
    {
      path: '/logs',
      name: 'logs',
      component: Logs
    },
    {
      path: '/terminal',
      name: 'terminal',
      component: Terminal
    }
  ]
})

export default router