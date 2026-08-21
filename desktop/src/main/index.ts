import { app, BrowserWindow, ipcMain, net, protocol } from 'electron'
import { existsSync } from 'fs'
import { dirname, join, sep } from 'path'
import { pathToFileURL } from 'url'
import { IPC_CHANNELS, type PlaybackState } from '../shared/ipc'
import { BaiduService } from './baidu'
import { LibraryService } from './library'
import { SOURCE_DB, SnapshotDatabase } from './library-db'
import { initUpdater } from './updater'
import { startCliServer, stopCliServer, setPlaybackState, ackRemoteCommand } from './cli-server'

protocol.registerSchemesAsPrivileged([
  { scheme:'hb-media', privileges:{standard:true,secure:true,supportFetchAPI:true,stream:true,corsEnabled:true} },
  { scheme:'hb-cover', privileges:{standard:true,secure:true,supportFetchAPI:true,corsEnabled:true} }
])
app.setName('PolarBear')
let mainWindow:BrowserWindow|null=null
let library:LibraryService
const snapshot = new SnapshotDatabase()
const baidu = new BaiduService()
function createWindow(){ mainWindow=new BrowserWindow({width:1200,height:800,minWidth:900,minHeight:600,backgroundColor:'#141518',titleBarStyle:'hiddenInset',webPreferences:{preload:join(__dirname,'../preload/index.js'),contextIsolation:true,nodeIntegration:false,sandbox:true,spellcheck:false}});mainWindow.on('closed',()=>{mainWindow=null});mainWindow.on('focus',()=>snapshot.refresh(false));if(process.env.ELECTRON_RENDERER_URL)void mainWindow.loadURL(process.env.ELECTRON_RENDERER_URL);else void mainWindow.loadFile(join(__dirname,'../renderer/index.html')) }
function registerIpc(){
 ipcMain.handle(IPC_CHANNELS.getStatus,()=>library.status()); ipcMain.handle(IPC_CHANNELS.refresh,()=>library.refresh()); ipcMain.handle(IPC_CHANNELS.getFolders,()=>library.folders()); ipcMain.handle(IPC_CHANNELS.getFavorites,()=>library.favorites()); ipcMain.handle(IPC_CHANNELS.getCollections,(_e,folderId:string|null,includeArchived?:boolean)=>library.collections(folderId,includeArchived)); ipcMain.handle(IPC_CHANNELS.getTracks,(_e,id:string,page?:number,size?:number)=>library.tracks(id,page,size)); ipcMain.handle(IPC_CHANNELS.getContinue,(_e,limit?:number)=>library.continueListening(limit)); ipcMain.handle(IPC_CHANNELS.search,(_e,q:string,limit?:number)=>library.search(q,limit)); ipcMain.handle(IPC_CHANNELS.getText,(_e,id:string)=>library.textContent(id)); ipcMain.handle(IPC_CHANNELS.resolvePlayback,(_e,id:string)=>library.media(id)); ipcMain.handle(IPC_CHANNELS.baiduStatus,()=>baidu.getStatus()); ipcMain.handle(IPC_CHANNELS.baiduLogin,()=>baidu.login(mainWindow)); ipcMain.handle(IPC_CHANNELS.baiduLogout,()=>baidu.logout());ipcMain.handle(IPC_CHANNELS.playbackPushState,(_e,state:PlaybackState)=>{setPlaybackState(state)});ipcMain.handle(IPC_CHANNELS.playbackAckCommand,(_e,commandId:string)=>{ackRemoteCommand(commandId)})
}
app.whenReady().then(()=>{ initUpdater();library=new LibraryService(snapshot);snapshot.initialize();registerIpc();setInterval(()=>snapshot.refresh(false),30000);startCliServer(library,baidu,()=>{if(mainWindow&&!mainWindow.isDestroyed())return mainWindow;createWindow();return mainWindow&&!mainWindow.isDestroyed()?mainWindow:null});protocol.handle('hb-cover',request=>{try{const u=new URL(request.url);const relative=decodeURIComponent(u.pathname).replace(/^\/+/, '');const root=dirname(SOURCE_DB);const file=join(root,relative);if(!(file===root||file.startsWith(root+sep))||!existsSync(file))return new Response('Not found',{status:404});return net.fetch(pathToFileURL(file).toString())}catch{return new Response('Bad request',{status:400})}});protocol.handle('hb-media',async request=>{try{const id=decodeURIComponent(new URL(request.url).pathname).replace(/^\/+/, '');const source=library.media(id);if(!source)return new Response('Not found',{status:404});if(source.kind==='baidu')return baidu.stream(source.value,request);const url=new URL(source.value);if(!['http:','https:'].includes(url.protocol))return new Response('Unsupported URL',{status:400});if(url.protocol==='http:')url.protocol='https:';const range=request.headers.get('Range');return net.fetch(url.toString(),{headers:range?{Range:range}:{}})}catch(error){return new Response(String(error),{status:502})}});createWindow()})
app.on('window-all-closed',()=>{if(process.platform!=='darwin'){stopCliServer();app.quit()}});app.on('before-quit',()=>{stopCliServer()});app.on('activate',()=>{if(BrowserWindow.getAllWindows().length===0)createWindow()})
