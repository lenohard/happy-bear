import { net } from 'electron'
import type {
  Collection,
  ContinueItem,
  Folder,
  LibraryProvider,
  LibraryStatus,
  PlaybackSource,
  SearchResult,
  Track,
  TrackDetail,
  TrackPage,
  TrackTranscript
} from '../shared/ipc'
import type { ServerConfig } from './server-config'

/** Reads the library from a PolarBear server (Mac mini) instead of the local iCloud snapshot. */
export class RemoteLibrary implements LibraryProvider {
  constructor(private readonly config: ServerConfig) {}

  private async request<T>(path: string): Promise<T> {
    const response = await net.fetch(`${this.config.baseUrl}${path}`)
    if (!response.ok) {
      const body = await response.text().catch(() => '')
      throw new Error(`服务器返回 ${response.status}${body ? `：${body.slice(0, 200)}` : ''}`)
    }
    return await response.json() as T
  }

  async status(): Promise<LibraryStatus> { return this.request<LibraryStatus>('/v1/library/status') }
  async refresh(): Promise<LibraryStatus> {
    const response = await net.fetch(`${this.config.baseUrl}/v1/library/refresh`, { method: 'POST' })
    if (!response.ok) throw new Error(`服务器返回 ${response.status}`)
    return await response.json() as LibraryStatus
  }
  async folders(): Promise<Folder[]> { return this.request<Folder[]>('/v1/library/folders') }
  async favorites(): Promise<Track[]> { return this.request<Track[]>('/v1/library/tracks/favorites') }
  async collections(folderId: string | null, includeArchived = false): Promise<Collection[]> {
    const query = new URLSearchParams()
    if (folderId) query.set('folderId', folderId)
    if (includeArchived) query.set('includeArchived', '1')
    const suffix = query.toString()
    return this.request<Collection[]>(`/v1/library/collections${suffix ? `?${suffix}` : ''}`)
  }
  async tracks(collectionId: string, page = 0, pageSize = 200, includeArchived = false): Promise<TrackPage> {
    const query = new URLSearchParams({ page: String(page), pageSize: String(pageSize) })
    if (includeArchived) query.set('includeArchived', '1')
    return this.request<TrackPage>(`/v1/library/collections/${encodeURIComponent(collectionId)}/tracks?${query}`)
  }
  async continueListening(limit = 20): Promise<ContinueItem[]> {
    return this.request<ContinueItem[]>(`/v1/library/tracks/continue?limit=${limit}`)
  }
  async search(query: string, limit = 50): Promise<SearchResult[]> {
    return this.request<SearchResult[]>(`/v1/library/search?q=${encodeURIComponent(query)}&limit=${limit}`)
  }
  async getTrack(trackId: string): Promise<Track | null> {
    const detail = await this.getTrackDetail(trackId)
    return detail ? detail.track : null
  }
  async getTrackDetail(trackId: string): Promise<TrackDetail | null> {
    const response = await net.fetch(`${this.config.baseUrl}/v1/library/tracks/${encodeURIComponent(trackId)}`)
    if (response.status === 404) return null
    if (!response.ok) throw new Error(`服务器返回 ${response.status}`)
    return await response.json() as TrackDetail
  }
  async getTranscript(trackId: string, includeFullText = false): Promise<TrackTranscript | null> {
    return this.request<TrackTranscript | null>(`/v1/library/tracks/${encodeURIComponent(trackId)}/transcript?fullText=${includeFullText ? 1 : 0}`)
  }
  async textContent(trackId: string): Promise<string | null> {
    const body = await this.request<{ content: string | null }>(`/v1/library/tracks/${encodeURIComponent(trackId)}/text`)
    return body.content
  }
  async media(trackId: string): Promise<PlaybackSource | null> {
    const response = await net.fetch(`${this.config.baseUrl}/v1/library/tracks/${encodeURIComponent(trackId)}/playback`)
    if (response.status === 404) return null
    if (!response.ok) throw new Error(`服务器返回 ${response.status}`)
    return await response.json() as PlaybackSource
  }
}
