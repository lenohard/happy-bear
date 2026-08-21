import { contextBridge, ipcRenderer } from 'electron'
import { IPC_CHANNELS, type IPCApi } from '../shared/ipc'
const api:IPCApi = {
 libraryGetStatus:()=>ipcRenderer.invoke(IPC_CHANNELS.getStatus), libraryRefresh:()=>ipcRenderer.invoke(IPC_CHANNELS.refresh), libraryGetFolders:()=>ipcRenderer.invoke(IPC_CHANNELS.getFolders), libraryGetFavorites:()=>ipcRenderer.invoke(IPC_CHANNELS.getFavorites), libraryGetCollections:(folderId,includeArchived)=>ipcRenderer.invoke(IPC_CHANNELS.getCollections,folderId,includeArchived), libraryGetTracks:(id,page,size)=>ipcRenderer.invoke(IPC_CHANNELS.getTracks,id,page,size), libraryGetContinue:limit=>ipcRenderer.invoke(IPC_CHANNELS.getContinue,limit), librarySearch:(q,limit)=>ipcRenderer.invoke(IPC_CHANNELS.search,q,limit), trackGetTextContent:id=>ipcRenderer.invoke(IPC_CHANNELS.getText,id), trackGetPlayback:id=>ipcRenderer.invoke(IPC_CHANNELS.resolvePlayback,id), baiduGetStatus:()=>ipcRenderer.invoke(IPC_CHANNELS.baiduStatus), baiduLogin:()=>ipcRenderer.invoke(IPC_CHANNELS.baiduLogin), baiduLogout:()=>ipcRenderer.invoke(IPC_CHANNELS.baiduLogout)
}
contextBridge.exposeInMainWorld('api',api)
