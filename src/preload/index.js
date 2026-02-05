import { contextBridge, ipcRenderer } from 'electron'
import { electronAPI } from '@electron-toolkit/preload'

const api = {
    getDocumentsPath: () => ipcRenderer.invoke('get-documents-path'),
    scanDirectory: (path) => ipcRenderer.invoke('scan-directory', path),
    getRecursiveSize: (path) => ipcRenderer.invoke('get-recursive-size', path),
    startFullIndex: (path) => ipcRenderer.invoke('start-full-index', path),
    onScanLog: (callback) => ipcRenderer.on('scan-log', (_event, value) => callback(value)),
    onSizeUpdate: (callback) => ipcRenderer.on('size-update', (_event, value) => callback(value)),
    onScanComplete: (callback) => ipcRenderer.on('scan-complete', (_event, value) => callback(value)),
    onFullIndexProgress: (callback) => ipcRenderer.on('full-index-progress', (_event, value) => callback(value)),
    openPrivacySettings: () => ipcRenderer.invoke('open-privacy-settings')
}

if (process.contextIsolated) {
    try {
        contextBridge.exposeInMainWorld('electron', electronAPI)
        contextBridge.exposeInMainWorld('api', api)
    } catch (error) {
        console.error(error)
    }
} else {
    window.electron = electronAPI
    window.api = api
}
