import * as d3 from 'd3'
import { invoke } from '@tauri-apps/api/core'
import { listen } from '@tauri-apps/api/event'

const container = document.getElementById('treemap-container')
const breadcrumb = document.getElementById('breadcrumb')
const status = document.getElementById('status')
const backBtn = document.getElementById('back-btn')
const tooltip = document.getElementById('tooltip')
const modeToggle = document.getElementById('mode-toggle')

let currentPath = ''
let currentData = { name: '/', children: [] }
let currentScanState = 'READY'
let activeMode = 'dynamic'
const dataCache = new Map()

/**
 * ProgressAnimator: Handles smooth linear interpolation (LERP) of the progress bar.
 * This prevents jumping and ensures the progress never retreats visually.
 */
class ProgressAnimator {
  constructor(renderCallback) {
    this.targetValue = 0
    this.currentValue = 0
    this.renderCallback = renderCallback
    this.isDiscoveryComplete = false
    this.animate()
  }

  update(discovered, processed) {
    let raw = (processed / discovered) * 100
    // As a senior rule: Progress never moves backwards visually
    if (raw > this.targetValue) {
      this.targetValue = Math.min(99.9, raw) // Cap at 99.9 until complete event
    }
  }

  forceComplete() {
    this.targetValue = 100
  }

  reset() {
    this.targetValue = 0
    this.currentValue = 0
  }

  animate() {
    // Smooth gliding towards target (LERP)
    const delta = this.targetValue - this.currentValue
    if (Math.abs(delta) > 0.01) {
      this.currentValue += delta * 0.05 // Gliding speed
      this.renderCallback(Math.floor(this.currentValue))
    }
    requestAnimationFrame(() => this.animate())
  }
}

const progressAnimator = new ProgressAnimator((p) => {
  currentProgress = p
  const total = currentData.children?.reduce((acc, c) => acc + (c.size || 0), 0) || 0
  const isScanning = currentData.children?.some(c => c.isPending)
  if (isScanning || p < 100) {
    updateStatus('scanning', total, p)
  }
})

// Initialize live size updates
listen('size-update', (event) => {
  const update = event.payload
  // 1. Update Cache if exists
  if (update.parent && dataCache.has(update.parent)) {
    const cachedParent = dataCache.get(update.parent)
    const child = cachedParent.children.find(c => c.path === update.path)
    if (child) {
      child.size = update.size
      child.isPending = false
    }
  }

  // 2. Update UI if it matches current view
  if (currentPath === update.parent) {
    const child = currentData.children?.find(c => c.path === update.path)
    if (child) {
      child.size = update.size
      child.isPending = false

      // Update total status
      const total = currentData.children.reduce((acc, c) => acc + (c.size || 0), 0)
      updateStatus('scanning', total, currentProgress)
      render()
    }
  }
})

listen('scan-progress', (event) => {
  const { discovered, processed } = event.payload
  progressAnimator.update(discovered, processed)
})

listen('scan-complete', () => {
  progressAnimator.forceComplete()
  // If the completed scan matches our current view, mark complete
  const total = currentData.children?.reduce((acc, c) => acc + (c.size || 0), 0) || 0
  updateStatus('complete', total)
  prefetchSubdirectories(currentData)
})

listen('scan-heartbeat', (event) => {
  const path = event.payload
  const total = currentData.children?.reduce((acc, c) => acc + (c.size || 0), 0) || 0
  updateStatus('scanning', total, currentProgress, path)
})

listen('scan-state', (event) => {
  currentScanState = event.payload.toUpperCase()
  const total = currentData.children?.reduce((acc, c) => acc + (c.size || 0), 0) || 0
  updateStatus('scanning', total, currentProgress)
})

listen('scan-log', (event) => {
  // Optional: Log handling if needed, or update status text
  // console.log(event.payload)
})

listen('deep-scan-status', (event) => {
  if (activeMode !== 'deep') return
  const msg = event.payload
  // Don't render treemap yet, show flow overlay
  renderDeepScanOverlay(msg)
})

function renderDeepScanOverlay(msg) {
  let overlay = document.getElementById('deep-overlay')
  if (!overlay) {
    overlay = document.createElement('div')
    overlay.id = 'deep-overlay'
    overlay.style.cssText = `
      position: absolute; inset: 0; background: rgba(0,0,0,0.3); backdrop-filter: blur(5px);
      display: flex; flex-direction: column; align-items: center; justify-content: center; z-index: 50;
    `
    overlay.innerHTML = `
      <div class="scanner-ring"></div>
      <div id="deep-msg" style="margin-top:20px; font-weight:600; color:var(--accent-color)">Initializing...</div>
    `
    container.appendChild(overlay)
  }
  const msgEl = document.getElementById('deep-msg')
  if (msgEl) msgEl.innerText = msg
}

listen('deep-scan-complete', () => {
  const overlay = document.getElementById('deep-overlay')
  if (overlay) overlay.remove()

  updateStatus('complete', 0)
  loadDirectory(currentPath) // Refresh current view with new cached values
})

function prefetchSubdirectories(data) {
  if (!data || !data.children) return

  // Sort large folders first for prefetching
  const candidates = data.children.filter(c => c.isDirectory)
    .sort((a, b) => (b.size || 0) - (a.size || 0))
    .slice(0, 10)

  candidates.forEach(c => {
    if (!dataCache.has(c.path)) {
      invoke('scan_directory', { path: c.path }).then(res => {
        if (!res.error) {
          dataCache.set(c.path, res)
        }
      })
    }
  })
}

async function init() {
  try {
    const startPath = await invoke('get_documents_path')
    await loadDirectory(startPath)
    initToggle()
  } catch (e) {
    console.error("Failed to init", e)
  }
}

function initToggle() {
  if (!modeToggle) return
  const options = modeToggle.querySelectorAll('.mode-option')
  options.forEach(opt => {
    opt.onclick = () => {
      const mode = opt.dataset.mode
      activeMode = mode
      if (mode === 'deep') {
        invoke('start_deep_scan')
        modeToggle.classList.add('deep')
      } else {
        modeToggle.classList.remove('deep')
        // Force refresh current view when switching back to dynamic
        loadDirectory(currentPath)
      }
      options.forEach(o => o.classList.remove('active'))
      opt.classList.add('active')
    }
  })
}

let currentProgress = 0

async function loadDirectory(path) {
  progressAnimator.reset()
  currentProgress = 0
  // 1. Check Cache
  if (dataCache.has(path)) {
    currentPath = path
    currentData = dataCache.get(path)
    render()
    updateBreadcrumb()

    const total = currentData.children.reduce((acc, c) => acc + (c.size || 0), 0)
    const isScanning = currentData.children.some(c => c.isPending)
    updateStatus(isScanning ? 'scanning' : 'complete', total)
    return
  }

  // 2. Load Fresh
  try {
    const data = await invoke('scan_directory', { path })

    if (data.error) {
      status.innerText = `Error: ${data.error}`
      return
    }

    currentPath = path
    currentData = data
    dataCache.set(path, data)

    render()
    updateBreadcrumb()

    // Use the known size from the parent scan if available
    updateStatus('scanning', data.size || 0, 0)

    // Smart Prefetch: Load next layer silently
    if (activeMode === 'focus' || activeMode === 'dynamic') {
      setTimeout(() => prefetchSubdirectories(data), 500)
    }
  } catch (err) {
    console.error('Load Error:', err)
    status.innerText = `UI Error: ${err.message}`
  }
}

function findNodeByPath(root, targetPath) {
  if (root.path === targetPath) return root
  if (!root.children) return null
  for (const child of root.children) {
    const found = findNodeByPath(child, targetPath)
    if (found) return found
  }
  return null
}

function render() {
  const isScanning = currentData.children?.some(c => c.isPending)
  container.classList.toggle('is-scanning', !!isScanning)
  renderTreeMap(currentData)
}

function updateBreadcrumb() {
  breadcrumb.innerHTML = ''
  const parts = currentPath.split('/').filter(Boolean)

  const rootSpan = document.createElement('span')
  rootSpan.innerText = 'Home'
  rootSpan.onclick = () => loadDirectory('/')
  breadcrumb.appendChild(rootSpan)

  let pathAcc = ''
  parts.forEach((part) => {
    pathAcc += '/' + part
    const separator = document.createTextNode(' / ')
    breadcrumb.appendChild(separator)

    const span = document.createElement('span')
    span.innerText = part
    const tPath = pathAcc
    span.onclick = () => {
      if (tPath !== currentPath) loadDirectory(tPath)
    }
    breadcrumb.appendChild(span)
  })
}

function formatSize(bytes) {
  if (bytes === -1) return 'Restricted'
  if (bytes === 0) return '0 B'
  if (bytes < 0) return '0 B'
  const k = 1024
  const sizes = ['B', 'KB', 'MB', 'GB', 'TB']
  const i = Math.floor(Math.log(bytes) / Math.log(k))
  return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i]
}

function renderTreeMap(data) {
  const rect = container.getBoundingClientRect()
  const width = rect.width
  const height = rect.height

  if (width === 0 || height === 0) return

  const visibleChildren = data.children?.filter(d => {
    if (!d.name || d.name.trim() === '') return false // Fix for ghost nodes
    if (d.isPending) return true
    if (d.size === -1) return true
    return d.size > 0
  }) || []

  // Handle Empty State
  let emptyMsg = document.getElementById('empty-msg')
  if (visibleChildren.length === 0) {
    if (!emptyMsg) {
      emptyMsg = document.createElement('div')
      emptyMsg.id = 'empty-msg'
      emptyMsg.style.cssText = "display:flex;align-items:center;justify-content:center;height:100%;color:var(--text-secondary)"
      container.appendChild(emptyMsg)
    }
    emptyMsg.innerText = `Empty Directory (${data.path})`
    d3.select(container).selectAll('.node').remove()
    return
  } else {
    if (emptyMsg) emptyMsg.remove()
  }

  // Force the root to purely be the sum of visible children to avoid "empty area" glitches
  const root = d3.hierarchy({ name: 'root', children: visibleChildren })
    .sum(d => {
      if (d.size === -1) return 1024 * 1024 * 50 // 50MB for restricted
      if (d.isPending) return 1024 * 1024 * 10 // 10MB placeholder while loading
      return Math.max(0, d.size || 0)
    })
    .sort((a, b) => b.value - a.value)

  d3.treemap()
    .size([width, height])
    .padding(2)(root)

  const t = d3.transition()
    .duration(750)
    .ease(d3.easeBackOut.overshoot(1.5)); // Aggressive pop

  const nodes = d3.select(container)
    .selectAll('.node')
    .data(root.leaves(), d => d.data.path)

  // EXIT
  nodes.exit()
    .transition(t)
    .style('opacity', 0)
    .style('transform', 'scale(0.8)')
    .remove()

  // ENTER
  const entered = nodes.enter()
    .append('div')
    .attr('class', 'node')
    .style('opacity', 0)
    .style('transform', 'scale(0)') // Start small for the pop effect
    // Position new nodes at their destination immediately
    .style('left', d => `${d.x0}px`)
    .style('top', d => `${d.y0}px`)
    .style('width', d => `${Math.max(0, d.x1 - d.x0)}px`)
    .style('height', d => `${Math.max(0, d.y1 - d.y0)}px`)
    .style('background', 'transparent')
    .on('click', (event, d) => {
      if (d.data.size === -1) {
        invoke('open_privacy_settings')
        return
      }
      if (d.data.isDirectory) loadDirectory(d.data.path)
    })
    .on('contextmenu', (event, d) => {
      event.preventDefault()
      invoke('open_in_finder', { path: d.data.path })
    })
    .on('mouseover', (event, d) => {
      tooltip.classList.remove('hidden')
      const type = d.data.isDirectory ? 'Folder' : 'File'
      const size = d.data.size === -1 ? 'Restricted' : formatSize(d.data.size)
      tooltip.innerHTML = `
                <div style="font-weight:600;margin-bottom:4px">${d.data.name}</div>
                <div style="opacity:0.8;font-size:0.8em">${type} • ${size}</div>
            `
    })
    .on('mousemove', (event) => {
      const margin = 15
      const tw = tooltip.offsetWidth
      const th = tooltip.offsetHeight

      let x = event.pageX + 10
      let y = event.pageY + 10

      // Flip if hits right edge
      if (x + tw > window.innerWidth - margin) {
        x = event.pageX - tw - 10
      }

      // Flip if hits bottom edge
      if (y + th > window.innerHeight - margin) {
        y = event.pageY - th - 10
      }

      tooltip.style.left = x + 'px'
      tooltip.style.top = y + 'px'
    })
    .on('mouseout', () => {
      tooltip.classList.add('hidden')
    })

  // Add Parts
  entered.append('div').attr('class', 'node-label')
  entered.append('div').attr('class', 'node-size')

  // MERGE + UPDATE
  const all = entered.merge(nodes)

  all.classed('is-pending', d => d.data.isPending)
    .classed('is-restricted', d => d.data.size === -1)

  // Animate geometry
  all.transition(t)
    .style('opacity', 1)
    .style('left', d => `${d.x0}px`)
    .style('top', d => `${d.y0}px`)
    .style('width', d => `${Math.max(0, d.x1 - d.x0)}px`)
    .style('height', d => `${Math.max(0, d.y1 - d.y0)}px`)
    .style('transform', 'scale(1)')

  // Instant Text Updates
  all.select('.node-label')
    .text(d => {
      if (d.data.size === -1) return '⚠️ Restricted Access'
      return d.data.name
    })

  all.select('.node-size')
    .text(d => {
      if (d.data.isPending) return '...'
      if (d.data.size === -1) return 'Requires Permissions'
      return formatSize(d.data.size)
    })
}

backBtn.onclick = () => {
  if (currentPath === '/') return
  const parts = currentPath.split('/').filter(Boolean)
  parts.pop()
  loadDirectory('/' + parts.join('/'))
}

window.addEventListener('resize', () => { if (currentData) render() })
init()

function updateStatus(state, sizeBytes, progress = null, heartbeat = null) {
  status.className = `status ${state}`

  let text = currentScanState
  if (state === 'complete') text = 'COMPLETE'
  if (state === 'scanning') {
    text = progress !== null ? `${currentScanState} ${progress}%` : currentScanState
  }

  const sizeStr = formatSize(sizeBytes)

  // Truncate heartbeat path for UI
  const displayHeartbeat = heartbeat
    ? `<div style="font-size:10px; opacity:0.5; margin-top:4px; max-width:200px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap">${heartbeat}</div>`
    : ''

  status.innerHTML = `
        <div style="display:flex; flex-direction:column">
          <div style="display:flex; align-items:center; gap:10px">
              <div class="status-dot"></div>
              <span class="status-text">${text}</span>
              <span class="status-size" style="opacity:0.7; border-left:1px solid rgba(255,255,255,0.2); padding-left:10px; margin-left:2px">${sizeStr}</span>
          </div>
          ${displayHeartbeat}
        </div>
    `
}
