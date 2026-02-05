import * as d3 from 'd3'
const container = document.getElementById('treemap-container')
const breadcrumb = document.getElementById('breadcrumb')
const status = document.getElementById('status')
const backBtn = document.getElementById('back-btn')
const tooltip = document.getElementById('tooltip')

let currentPath = ''
let currentData = { name: '/', children: [] }
const dataCache = new Map()

// Initialize live size updates
window.api.onSizeUpdate((update) => {
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
        // We can use currentData directly as it is a reference to the cache usually
        // But for safety let's find the node in currentData
        const child = currentData.children?.find(c => c.path === update.path)
        if (child) {
            child.size = update.size
            child.isPending = false

            // Update total status
            const total = currentData.children.reduce((acc, c) => acc + (c.size || 0), 0)
            updateStatus('scanning', total)
            render()
        }
    }
})

window.api.onScanComplete(() => {
    // If the completed scan matches our current view, mark complete
    // We don't have the path in the event, but we can infer or rely on "no pending items"
    const isScanning = currentData.children?.some(c => c.isPending)
    const total = currentData.children?.reduce((acc, c) => acc + (c.size || 0), 0) || 0

    if (!isScanning) {
        updateStatus('complete', total)
        prefetchSubdirectories(currentData)
    }
})

function prefetchSubdirectories(data) {
    if (!data || !data.children) return

    // Sort large folders first for prefetching
    const candidates = data.children.filter(c => c.isDirectory && c.size > 0)
        .sort((a, b) => b.size - a.size)
        // Limit prefetch to top 10 to avoid blasting the CPU
        .slice(0, 10)

    candidates.forEach(c => {
        if (!dataCache.has(c.path)) {
            // Trigger scan but don't switch view
            // window.api.scanDirectory constructs the cache entry in the backend
            // responding with the initial structure.
            // We need to capture that response and put it in cache.
            window.api.scanDirectory(c.path).then(res => {
                if (!res.error) {
                    dataCache.set(c.path, res)
                }
            })
        }
    })
}

async function init() {
    const startPath = await window.api.getDocumentsPath()
    await loadDirectory(startPath)
}

async function loadDirectory(path) {
    // 1. Check Cache
    if (dataCache.has(path)) {
        currentPath = path
        currentData = dataCache.get(path)
        render()
        updateBreadcrumb()

        // Calculate status from cached data
        const total = currentData.children.reduce((acc, c) => acc + (c.size || 0), 0)
        const isScanning = currentData.children.some(c => c.isPending)
        updateStatus(isScanning ? 'scanning' : 'complete', total)
        return
    }

    // 2. Load Fresh
    try {
        const data = await window.api.scanDirectory(path)

        if (data.error) {
            status.innerText = `Error: ${data.error}`
            return
        }

        currentPath = path
        currentData = data
        dataCache.set(path, data)

        render()
        updateBreadcrumb()

        updateStatus('scanning', 0)
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
    rootSpan.innerText = '/'
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
    const width = container.clientWidth
    const height = container.clientHeight

    const visibleChildren = data.children?.filter(d => {
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

    const root = d3.hierarchy({ ...data, children: visibleChildren })
        .sum(d => {
            if (d.size === -1) return 1024 * 1024 * 50 // 50MB for restricted
            if (d.isPending) return 1024 * 1024 * 10 // 10MB placeholder while loading
            return d.size || 0
        })
        .sort((a, b) => b.value - a.value)

    d3.treemap()
        .size([width, height])
        .padding(2)(root)

    const t = container.transition // Shared transition for this frame
        ? d3.select(container).transition().duration(500).ease(d3.easeBackOut.overshoot(0.8))
        : d3.transition().duration(500).ease(d3.easeBackOut.overshoot(0.8));

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
                window.api.openPrivacySettings()
                return
            }
            if (d.data.isDirectory) loadDirectory(d.data.path)
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
            tooltip.style.left = event.pageX + 10 + 'px'
            tooltip.style.top = event.pageY + 10 + 'px'
        })
        .on('mouseout', () => {
            tooltip.classList.add('hidden')
        })

    // Add Parts
    entered.append('div').attr('class', 'node-label')
    entered.append('div').attr('class', 'node-size')

    // MERGE + UPDATE
    // This is where the magic happens: One transition handles everything moving together
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

    // Instant Text Updates (no transition needed for text content usually)
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

function updateStatus(state, sizeBytes) {
    status.className = `status ${state}`

    let text = 'READY'
    if (state === 'scanning') text = 'SCANNING'

    const sizeStr = formatSize(sizeBytes)

    status.innerHTML = `
        <div class="status-dot"></div>
        <span class="status-text">${text}</span>
        <span class="status-size" style="opacity:0.7; border-left:1px solid rgba(255,255,255,0.2); padding-left:10px; margin-left:2px">${sizeStr}</span>
    `
}
