use tauri::{AppHandle, Manager, Emitter, State};
use std::path::{Path, PathBuf};
use std::fs;
use std::process::Command;
use serde::{Serialize, Deserialize};
use walkdir::WalkDir;
use std::collections::{HashSet, HashMap};
use std::sync::{Mutex, Arc};
use std::sync::atomic::{AtomicUsize, Ordering, AtomicBool};

// Global state to track everything durable across views
pub struct ScanState {
    pub files_discovered: AtomicUsize,
    pub files_processed: AtomicUsize,
    // Store already scanned recursive sizes to make navigation instant
    pub global_cache: Mutex<HashMap<String, i64>>,
    pub is_deep_scanning: AtomicBool,
}

#[derive(Serialize, Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
struct FileNodeDTO {
    name: String,
    path: String,
    is_directory: bool,
    size: i64,
    is_pending: bool,
}

#[derive(Serialize)]
struct ScanResult {
    name: String,
    path: String,
    children: Vec<FileNodeDTO>,
    size: i64, // The known total size of this directory itself
    error: Option<String>,
}

#[derive(Serialize, Clone)]
struct SizeUpdate {
    path: String,
    parent: String,
    size: i64,
}

#[tauri::command]
fn get_documents_path(app: AppHandle) -> String {
    app.path().home_dir()
        .unwrap_or_else(|_| PathBuf::from("/"))
        .to_string_lossy()
        .to_string()
}

#[tauri::command]
async fn open_in_finder(path: String) {
    #[cfg(target_os = "macos")]
    let _ = Command::new("open")
        .arg("-R") // Reveals in Finder
        .arg(path)
        .spawn();
}

#[tauri::command]
async fn open_privacy_settings() {
    #[cfg(target_os = "macos")]
    let _ = Command::new("open")
        .arg("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        .spawn();
}

#[tauri::command]
async fn start_deep_scan(app: AppHandle, state: State<'_, ScanState>) -> Result<(), String> {
    if state.is_deep_scanning.swap(true, Ordering::SeqCst) {
        return Ok(()); // Already running
    }

    let home = app.path().home_dir().map_err(|e| e.to_string())?;
    let home_str = home.to_string_lossy().to_string();
    let app_handle = app.clone();

    tauri::async_runtime::spawn(async move {
        let _ = app_handle.emit("deep-scan-status", "Starting...");
        
        let path_clone = home_str.clone();
        let app_inner = app_handle.clone();
        
        tauri::async_runtime::spawn_blocking(move || {
            let s = app_inner.state::<ScanState>();
            let mut folder_sizes: HashMap<String, i64> = HashMap::new();
            let mut seen_inodes = HashSet::new();
            let mut item_count = 0;

            // Perform deep traversal
            for entry in WalkDir::new(&path_clone)
                .same_file_system(true)
                .into_iter()
            {
                item_count += 1;
                if item_count % 200 == 0 {
                    let _ = app_inner.emit("deep-scan-status", format!("Indexed {} items...", item_count));
                }

                // Incremental cache flush
                if item_count % 1000 == 0 {
                    let mut cache = s.global_cache.lock().unwrap();
                    for (p, s) in &folder_sizes {
                        cache.insert(p.clone(), *s);
                    }
                }

                if let Ok(entry) = entry {
                    let path = entry.path();
                    if entry.file_type().is_file() {
                         if let Ok(meta) = entry.metadata() {
                            #[cfg(unix)]
                            {
                                use std::os::unix::fs::MetadataExt;
                                let inode = (meta.dev(), meta.ino());
                                if seen_inodes.insert(inode) {
                                    let size = get_size_on_disk(&meta);
                                    let mut curr = path.parent();
                                    while let Some(p) = curr {
                                        let p_str = p.to_string_lossy().to_string();
                                        *folder_sizes.entry(p_str.clone()).or_insert(0) += size;
                                        if p_str == path_clone { break; }
                                        curr = p.parent();
                                    }
                                }
                            }
                         }
                    }
                }
            }

            // Flush to global cache
            let mut cache = s.global_cache.lock().unwrap();
            for (p, s) in folder_sizes {
                cache.insert(p, s);
            }
            s.is_deep_scanning.store(false, Ordering::SeqCst);
            let _ = app_inner.emit("deep-scan-complete", ());
        });
    });

    Ok(())
}

#[tauri::command]
async fn scan_directory(
    app: AppHandle, 
    state: State<'_, ScanState>,
    path: String
) -> Result<ScanResult, String> {
    let dir_path = Path::new(&path);
    let mut children = Vec::new();
    
    // Reset Progress Counters for this specific scan session
    state.files_discovered.store(0, Ordering::SeqCst);
    state.files_processed.store(0, Ordering::SeqCst);

    let mut self_size = 0;
    {
        let cache = state.global_cache.lock().unwrap();
        if let Some(&s) = cache.get(&path) {
            self_size = s;
        }
    }

    // 1. Shallow Read
    match fs::read_dir(dir_path) {
        Ok(entries) => {
            for entry in entries {
                if let Ok(entry) = entry {
                    let path_buf = entry.path();
                    let name = entry.file_name().to_string_lossy().to_string();
                    let is_dir = path_buf.is_dir();
                    let full_path = path_buf.to_string_lossy().to_string();
                    
                    let mut size = 0;
                    if !is_dir {
                         if let Ok(metadata) = entry.metadata() {
                             size = get_size_on_disk(&metadata);
                         } else {
                             size = -1;
                         }
                    } else {
                        // Check if we already have this in cache from background preloading
                        let cache = state.global_cache.lock().unwrap();
                        if let Some(&cached_size) = cache.get(&full_path) {
                            size = cached_size;
                        }
                    }

                    children.push(FileNodeDTO {
                        name,
                        path: full_path,
                        is_directory: is_dir,
                        size,
                        is_pending: is_dir && size <= 0, 
                    });
                }
            }
        },
        Err(e) => {
             return Err(e.to_string());
        }
    }

    // 2. Start Background Scanning for this path
    let children_clone = children.clone();
    let parent_path = path.clone();
    
    tauri::async_runtime::spawn(async move {
        let mut folders_to_scan: Vec<_> = children_clone.into_iter()
            .filter(|c| c.is_pending)
            .collect();
        
        // Prioritize "Library"
        folders_to_scan.sort_by(|a, b| {
            if a.name == "Library" { std::cmp::Ordering::Less }
            else if b.name == "Library" { std::cmp::Ordering::Greater }
            else { std::cmp::Ordering::Equal }
        });
        
        if folders_to_scan.is_empty() {
             let _ = app.emit("scan-complete", ());
             return;
        }

        let total_folders = folders_to_scan.len();
        let completed_count = Arc::new(AtomicUsize::new(0));
        let local_seen_inodes = Arc::new(Mutex::new(HashSet::new()));

        // Emit initial scan state
        let _ = app.emit("scan-state", "calculating");

        for child in folders_to_scan {
            let child_path = child.path.clone();
            let parent = parent_path.clone();
            let app_handle = app.clone();
            let done_ptr = Arc::clone(&completed_count);
            let seen_inodes = Arc::clone(&local_seen_inodes);
            
            tauri::async_runtime::spawn(async move {
                let inner_app = app_handle.clone();
                let inner_path = child_path.clone();
                
                let size = tauri::async_runtime::spawn_blocking(move || {
                    let s = inner_app.state::<ScanState>();
                    let mut folder_total: i64 = 0;
                    let mut heartbeat_throttle = 0;

                    for entry in WalkDir::new(&inner_path)
                        .same_file_system(true)
                        .into_iter()
                    {
                        if let Ok(entry) = entry {
                            let path_str = entry.path().to_string_lossy().to_string();
                            
                            heartbeat_throttle += 1;
                            if heartbeat_throttle % 50 == 0 {
                                let _ = inner_app.emit("scan-heartbeat", path_str);
                            }

                            if entry.file_type().is_file() {
                                if let Ok(meta) = entry.metadata() {
                                    #[cfg(unix)]
                                    {
                                        use std::os::unix::fs::MetadataExt;
                                        let inode = (meta.dev(), meta.ino());
                                        if seen_inodes.lock().unwrap().insert(inode) {
                                            folder_total += get_size_on_disk(&meta);
                                        }
                                    }
                                    #[cfg(not(unix))]
                                    {
                                        folder_total += meta.len() as i64;
                                    }
                                }
                            }
                        }
                    }
                    
                    s.global_cache.lock().unwrap().insert(inner_path, folder_total);
                    folder_total
                }).await.unwrap_or(0);

                let _ = app_handle.emit("size-update", SizeUpdate {
                    path: child_path,
                    parent,
                    size,
                });

                if done_ptr.fetch_add(1, Ordering::SeqCst) + 1 == total_folders {
                    let _ = app_handle.emit("scan-complete", ());
                }
            });
        }
    });

    Ok(ScanResult {
        name: Path::new(&path).file_name().unwrap_or_default().to_string_lossy().to_string(),
        path,
        children,
        size: self_size,
        error: None,
    })
}

fn get_size_on_disk(metadata: &fs::Metadata) -> i64 {
    #[cfg(target_os = "macos")]
    {
        use std::os::unix::fs::MetadataExt;
        (metadata.blocks() * 512) as i64
    }
    #[cfg(not(target_os = "macos"))]
    {
        metadata.len() as i64
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .manage(ScanState { 
            files_discovered: AtomicUsize::new(0),
            files_processed: AtomicUsize::new(0),
            global_cache: Mutex::new(HashMap::new()),
            is_deep_scanning: AtomicBool::new(false),
        })
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![get_documents_path, open_privacy_settings, scan_directory, open_in_finder, start_deep_scan])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
