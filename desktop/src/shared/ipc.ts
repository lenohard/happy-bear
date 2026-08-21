export const IPC_CHANNELS = {
  getStatus: 'library:getStatus', refresh: 'library:refresh', getFolders: 'library:getFolders', getFavorites: 'library:getFavorites', getCollections: 'library:getCollections', getTracks: 'library:getTracks', getContinue: 'library:getContinueListening', search: 'library:search', getText: 'track:getTextContent', resolvePlayback: 'track:getPlayback', baiduStatus: 'baidu:getStatus', baiduLogin: 'baidu:login', baiduLogout: 'baidu:logout', playbackPushState: 'playback:pushState', playbackAckCommand: 'playback:ackCommand'
} as const

export const PLAYBACK_REMOTE_COMMAND_CHANNEL = 'playback:remoteCommand'

export type RemoteCommand = (
  | { action: 'play'; tracks: Track[] }
  | { action: 'playSingle'; track: Track }
  | { action: 'next' }
  | { action: 'prev' }
  | { action: 'togglePlay' }
  | { action: 'pause' }
  | { action: 'resume' }
  | { action: 'setVolume'; volume: number }
  | { action: 'seek'; positionSec: number }
) & { id?: string }

export interface PlaybackState {
  isPlaying: boolean
  currentTrack: Track | null
  queueLength: number
  currentIndex: number
  volume: number
  positionSec: number
  durationSec: number
}

export interface LibraryStatus { dbReady: boolean; snapshotTime: number | null; sourceMtime: number | null; tracks: number; collections: number; error?: string }
export interface Cover { kind: string | null; data: Record<string, unknown> | null; dominantColor: string | null }
export interface Folder { id: string; name: string; cover: Cover }
export interface Collection { id: string; title: string; author: string | null; description: string | null; folderId: string | null; sourceType: string; trackCount: number; listenedCount: number; progress: number; lastPlayed: string | null; cover: Cover }
export interface Playback { position: number; duration: number | null; updatedAt: string | null }
export interface Track { id: string; collectionId: string; displayName: string; filename: string; locationType: string; duration: number | null; trackNumber: number; chapter: string | null; mediaKind: string; isFavorite: boolean; playback: Playback | null; playable: boolean }
export interface TrackPage { tracks: Track[]; total: number; page: number; pageSize: number }
export interface ContinueItem extends Track { collectionTitle: string; collectionAuthor: string | null }
export interface PlaybackSource { kind: 'baidu' | 'external'; value: string }
export interface BaiduAuthStatus { configured: boolean; connected: boolean; expiresAt: number | null }
export interface IPCApi {
  libraryGetStatus(): Promise<LibraryStatus>; libraryRefresh(): Promise<LibraryStatus>; libraryGetFolders(): Promise<Folder[]>; libraryGetFavorites(): Promise<Track[]>; libraryGetCollections(folderId: string | null, includeArchived?: boolean): Promise<Collection[]>; libraryGetTracks(collectionId: string, page?: number, pageSize?: number): Promise<TrackPage>; libraryGetContinue(limit?: number): Promise<ContinueItem[]>; librarySearch(query: string, limit?: number): Promise<Track[]>; trackGetTextContent(trackId: string): Promise<string | null>; trackGetPlayback(trackId: string): Promise<PlaybackSource | null>; baiduGetStatus(): Promise<BaiduAuthStatus>; baiduLogin(): Promise<BaiduAuthStatus>; baiduLogout(): Promise<BaiduAuthStatus>; pushPlaybackState(state: PlaybackState): Promise<void>; ackRemoteCommand(commandId: string): Promise<void>; onRemoteCommand(listener: (command: RemoteCommand) => void): () => void
}

declare global { interface Window { api: IPCApi } }
