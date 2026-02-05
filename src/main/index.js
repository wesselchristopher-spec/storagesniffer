import { app, shell, BrowserWindow, ipcMain } from 'electron'
import { join } from 'path'
import { electronApp, optimizer, is } from '@electron-toolkit/utils'
import fs from 'fs/promises'
import path from 'path'
import { spawn } from 'child_process'

function createWindow() {
    const mainWindow = new BrowserWindow({
        width: 1100,
        height: 800,
        show: false,
        autoHideMenuBar: true,
        titleBarStyle: 'hiddenInset',
        backgroundColor: '#0f172a',
        webPreferences: {
            preload: join(app.getAppPath(), 'out/preload/index.mjs'),
            sandbox: false
        }
    })

    mainWindow.on('ready-to-show', () => {
        mainWindow.show()
    })

    mainWindow.webContents.setWindowOpenHandler((details) => {
        shell.openExternal(details.url)
        return { action: 'deny' }
    })

    if (is.dev && process.env['ELECTRON_RENDERER_URL']) {
        mainWindow.loadURL(process.env['ELECTRON_RENDERER_URL'])
    } else {
        mainWindow.loadFile(join(app.getAppPath(), 'out/renderer/index.html'))
    }
}

app.whenReady().then(() => {
    app.on('browser-window-created', (_, window) => {
        optimizer.watchWindowShortcuts(window)
    })

    ipcMain.handle('get-documents-path', () => {
        return app.getPath('home')
    })

    ipcMain.handle('open-privacy-settings', () => {
        // Direct link to Full Disk Access settings on macOS
        shell.openExternal('x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles')
    })

    // Rapid Scan: Non-blocking "Render First" approach
    let activeProcesses = []
    ipcMain.handle('scan-directory', async (event, dirPath) => {
        const win = BrowserWindow.fromWebContents(event.sender)

        // Cancel previous scan processes
        activeProcesses.forEach(p => p.kill())
        activeProcesses = []

        try {
            // 1. Get immediate directory listing (Instant ~5ms)
            const entries = await fs.readdir(dirPath, { withFileTypes: true })

            const children = await Promise.all(entries.map(async (entry) => {
                const fullPath = path.join(dirPath, entry.name)
                const isDirectory = entry.isDirectory()
                let size = 0
                let isPending = isDirectory

                if (!isDirectory) {
                    try {
                        const stats = await fs.lstat(fullPath)
                        size = stats.size
                    } catch (e) {
                        size = 0
                    }
                }

                return {
                    name: entry.name,
                    path: fullPath,
                    isDirectory,
                    size,
                    isPending
                }
            }))

            // 2. Queue for background scanning (Parallel Popcorn Effect)
            // Prioritize typically large folders to give faster feedback on big items
            const priorityFolders = [
                'Movies', 'Downloads', 'Music', 'Pictures', 'Desktop', 'Documents',
                'Library', 'Applications', 'System', 'Users', 'Developer',
                '.Trash', 'node_modules', '.git', 'dist', 'build'
            ]
            const foldersToScan = children
                .filter(c => c.isDirectory)
                .map(c => c.path)
                .sort((a, b) => {
                    const nameA = path.basename(a)
                    const nameB = path.basename(b)
                    const idxA = priorityFolders.indexOf(nameA)
                    const idxB = priorityFolders.indexOf(nameB)

                    // If both are priority, sort by priority index
                    if (idxA !== -1 && idxB !== -1) return idxA - idxB
                    // If only A is priority, it comes first
                    if (idxA !== -1) return -1
                    // If only B is priority, it comes first
                    if (idxB !== -1) return 1

                    // Otherwise keep original order
                    return 0
                })

            setImmediate(async () => {
                const limit = 6 // Concurrency limit
                const queue = [...foldersToScan]

                const processNext = async () => {
                    if (queue.length === 0) return
                    const targetPath = queue.shift()
                    const name = path.basename(targetPath)

                    // Log start
                    try { win.webContents.send('scan-log', `Queued: ${name}`) } catch (e) { }

                    return new Promise(resolve => {
                        // Use du -s (summary) for this specific folder
                        const childDu = spawn('du', ['-x', '-s', '-k', targetPath])
                        activeProcesses.push(childDu)
                        let output = ''

                        childDu.stdout.on('data', d => output += d.toString())

                        childDu.on('close', (code) => {
                            activeProcesses = activeProcesses.filter(p => p !== childDu)
                            if (code === 0) {
                                const match = output.match(/^(\d+)/)
                                if (match) {
                                    const sizeInBytes = parseInt(match[1]) * 1024
                                    try {
                                        win.webContents.send('size-update', {
                                            path: targetPath,
                                            parent: dirPath, // Include parent for cache lookup
                                            size: sizeInBytes
                                        })
                                        win.webContents.send('scan-log', `Resolved: ${name}`)
                                    } catch (e) { }
                                } else {
                                    // Match failed but code was 0? fallback
                                    win.webContents.send('size-update', { path: targetPath, parent: dirPath, size: -1 })
                                }
                            } else if (code !== null) {
                                // Scanning failed (permissions, etc)
                                win.webContents.send('size-update', { path: targetPath, parent: dirPath, size: -1 })
                                win.webContents.send('scan-log', `Restricted: ${name}`)
                            }
                            resolve()
                        })

                        childDu.on('error', () => {
                            activeProcesses = activeProcesses.filter(p => p !== childDu)
                            win.webContents.send('size-update', { path: targetPath, parent: dirPath, size: -1 })
                            resolve()
                        })
                    })
                }

                // Batch processor
                const workers = Array(limit).fill(null).map(async () => {
                    while (queue.length > 0) {
                        await processNext()
                    }
                })

                await Promise.all(workers)

                try {
                    win.webContents.send('scan-complete')
                    win.webContents.send('scan-log', 'Scan Complete')
                } catch (e) { }
            })

            // 3. Return structure immediately so UI draws
            return {
                name: path.basename(dirPath) || dirPath,
                path: dirPath,
                children: children
            }

        } catch (error) {
            return { error: error.message, children: [] }
        }
    })

    createWindow()

    app.on('activate', function () {
        if (BrowserWindow.getAllWindows().length === 0) createWindow()
    })
})

app.on('window-all-closed', () => {
    if (process.platform !== 'darwin') {
        app.quit()
    }
})
