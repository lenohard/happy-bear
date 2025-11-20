# React Native + Tamagui 迁移计划

**创建日期**: 2025-11-12
**目标**: 将现有iOS原生应用迁移到React Native + Tamagui跨平台架构

---

## 📊 现状分析

### 当前代码库统计
- **总文件数**: 52个Swift文件
- **总代码量**: ~15,000行Swift代码
- **UI层**: 12个View文件 (~2,200行)
- **业务逻辑层**: 20个ViewModel/Manager/Store/Client文件 (~8,000行)
- **数据模型**: 10个Model文件 (~1,500行)
- **其他**: 配置、工具类等 (~3,300行)

### 核心功能模块
1. **音频播放引擎** - AVPlayer + 后台播放 + 锁屏控制
2. **百度云盘集成** - OAuth2认证 + 文件浏览 + 下载
3. **本地数据库** - GRDB + SQLite (collections, tracks, transcripts)
4. **音频缓存系统** - 渐进式缓存 + LRU清理
5. **语音转文字** - Soniox API集成 + 任务管理
6. **AI Gateway** - 模型调用 + 配额管理
7. **CloudKit同步** - 可选的iCloud数据同步

---

## 🎯 目标技术栈

### 核心框架
```json
{
  "framework": "React Native 0.73+",
  "toolchain": "Expo SDK 50+",
  "ui_library": "Tamagui 1.90+",
  "language": "TypeScript 5.3+"
}
```

### 关键依赖库

#### 音频系统
```bash
react-native-track-player  # 音频播放 + 后台 + 锁屏控制 (一站式解决方案)
```

#### 数据存储
```bash
@react-native-async-storage/async-storage  # 简单K-V存储
react-native-sqlite-storage                # SQLite数据库
# 或 WatermelonDB                          # 高性能响应式数据库 (推荐)
react-native-keychain                      # Keychain/Keystore安全存储
```

#### 网络与文件
```bash
axios                      # HTTP客户端
react-native-fs            # 文件系统操作
rn-fetch-blob              # 大文件下载/上传
react-native-background-upload  # 后台上传任务
```

#### UI与交互
```bash
tamagui                    # UI组件库 + 主题系统
@react-navigation/native   # 路由导航
# 或 expo-router            # 文件系统路由 (推荐)
react-native-reanimated    # 高性能动画
```

#### OAuth与认证
```bash
react-native-app-auth      # OAuth2/OIDC
# 或 expo-web-browser + expo-auth-session  # Expo方案 (推荐)
```

#### 状态管理
```bash
zustand                    # 轻量状态管理 (推荐)
# 或 @reduxjs/toolkit       # Redux (如需复杂状态逻辑)
```

---

## 🗺️ 迁移路线图

### 阶段1: 项目初始化 (Week 1)

#### 1.1 创建Expo项目
```bash
npx create-expo-app audiobook-player-rn --template blank-typescript
cd audiobook-player-rn
```

#### 1.2 安装核心依赖
```bash
# Tamagui
npx @tamagui/cli init
npm install tamagui @tamagui/config

# 导航
npx expo install expo-router react-native-safe-area-context react-native-screens

# 音频
npm install react-native-track-player
npx expo install expo-av  # 备选方案

# 数据库
npm install react-native-sqlite-storage
# 或 npm install @nozbe/watermelondb @nozbe/with-observables

# 状态管理
npm install zustand immer

# 网络与文件
npm install axios react-native-fs rn-fetch-blob
npx expo install expo-file-system  # Expo方案

# 安全存储
npm install react-native-keychain
npx expo install expo-secure-store  # Expo方案
```

#### 1.3 配置Tamagui
```typescript
// tamagui.config.ts
import { config as configBase } from '@tamagui/config/v3'
import { createTamagui } from 'tamagui'

const config = createTamagui({
  ...configBase,
  themes: {
    light: {
      background: '#FFFFFF',
      color: '#000000',
      // 根据现有iOS设计定义主题变量
    },
    dark: {
      background: '#000000',
      color: '#FFFFFF',
      // 暗黑模式配色
    }
  }
})

export type AppConfig = typeof config
declare module 'tamagui' {
  interface TamaguiCustomConfig extends AppConfig {}
}

export default config
```

#### 1.4 配置Expo Router
```typescript
// app/_layout.tsx
import { Stack } from 'expo-router';
import { TamaguiProvider } from 'tamagui';
import config from '../tamagui.config';

export default function RootLayout() {
  return (
    <TamaguiProvider config={config}>
      <Stack>
        <Stack.Screen name="(tabs)" options={{ headerShown: false }} />
      </Stack>
    </TamaguiProvider>
  );
}
```

---

### 阶段2: 业务逻辑迁移 (Week 2-3)

#### 2.1 数据模型定义 (优先级: 高)

**Swift → TypeScript 映射**:

```typescript
// src/models/library.ts
export interface AudiobookCollection {
  id: string;
  title: string;
  description?: string;
  coverUrl?: string;
  sourceType: 'baidu' | 'local';
  sourcePath: string;
  createdAt: Date;
  updatedAt: Date;
  tracks: AudiobookTrack[];
  playbackStates: Record<string, PlaybackState>;
}

export interface AudiobookTrack {
  id: string;
  collectionId: string;
  title: string;
  filename: string;
  fileUrl: string;
  duration: number;
  fileSize: number;
  md5?: string;
  isFavorite: boolean;
  addedAt: Date;
}

export interface PlaybackState {
  trackId: string;
  currentTime: number;
  lastPlayedAt: Date;
  completed: boolean;
}

// 对应 Swift 的:
// - LibraryModels.swift: AudiobookCollection, AudiobookTrack
// - TrackPlaybackState
```

```typescript
// src/models/transcript.ts
export interface Transcript {
  id: string;
  trackId: string;
  text: string;
  language: string;
  confidence: number;
  createdAt: Date;
  segments: TranscriptSegment[];
}

export interface TranscriptSegment {
  id: string;
  transcriptId: string;
  text: string;
  startTime: number;
  endTime: number;
  confidence: number;
}

// 对应 Swift 的:
// - TranscriptModels.swift
```

#### 2.2 API客户端迁移 (优先级: 高)

**Baidu网盘客户端**:

```typescript
// src/api/baiduClient.ts
import axios, { AxiosInstance } from 'axios';

export interface BaiduTokens {
  accessToken: string;
  refreshToken: string;
  expiresAt: Date;
}

export interface NetdiskEntry {
  fsId: string;
  path: string;
  serverFilename: string;
  size: number;
  isDir: boolean;
  mtime: number;
  category: number;
  md5?: string;
}

export class BaiduNetdiskClient {
  private client: AxiosInstance;

  constructor(private tokenStore: BaiduTokenStore) {
    this.client = axios.create({
      baseURL: 'https://pan.baidu.com/rest/2.0/xpan',
      timeout: 30000,
    });

    // 自动添加access_token
    this.client.interceptors.request.use(async (config) => {
      const token = await this.tokenStore.getAccessToken();
      config.params = { ...config.params, access_token: token };
      return config;
    });

    // Token过期自动刷新
    this.client.interceptors.response.use(
      (response) => response,
      async (error) => {
        if (error.response?.status === 401) {
          await this.tokenStore.refreshToken();
          return this.client.request(error.config);
        }
        throw error;
      }
    );
  }

  async listFiles(path: string, recursion = false): Promise<NetdiskEntry[]> {
    const response = await this.client.get('/file', {
      params: {
        method: 'list',
        dir: path,
        recursion: recursion ? 1 : 0,
        web: 1,
      }
    });
    return response.data.list || [];
  }

  async searchFiles(key: string, dir: string, recursion = true): Promise<NetdiskEntry[]> {
    const response = await this.client.get('/file', {
      params: {
        method: 'search',
        key,
        dir,
        recursion: recursion ? 1 : 0,
      }
    });
    return response.data.list || [];
  }

  async getDownloadUrl(fsId: string): Promise<string> {
    const response = await this.client.get('/multimedia', {
      params: {
        method: 'filemetas',
        fsids: JSON.stringify([fsId]),
        dlink: 1,
      }
    });
    return response.data.list[0]?.dlink;
  }
}

// 对应 Swift 的:
// - BaiduNetdiskClient.swift: 所有API方法 1:1映射
```

**Soniox语音转文字客户端**:

```typescript
// src/api/sonioxClient.ts
import axios, { AxiosInstance } from 'axios';

export interface TranscriptionJob {
  id: string;
  status: 'queued' | 'processing' | 'completed' | 'failed';
  text?: string;
  segments?: TranscriptSegment[];
  error?: string;
}

export class SonioxClient {
  private client: AxiosInstance;

  constructor(private apiKey: string) {
    this.client = axios.create({
      baseURL: 'https://api.soniox.com/v1',
      headers: { 'Authorization': `Bearer ${apiKey}` },
      timeout: 120000,
    });
  }

  async uploadAudio(audioUri: string): Promise<string> {
    const formData = new FormData();
    formData.append('audio', {
      uri: audioUri,
      type: 'audio/mpeg',
      name: 'audio.mp3',
    } as any);

    const response = await this.client.post('/transcribe', formData, {
      headers: { 'Content-Type': 'multipart/form-data' },
    });
    return response.data.job_id;
  }

  async getJobStatus(jobId: string): Promise<TranscriptionJob> {
    const response = await this.client.get(`/jobs/${jobId}`);
    return response.data;
  }

  async pollUntilComplete(jobId: string, maxWaitMs = 300000): Promise<TranscriptionJob> {
    const startTime = Date.now();

    while (Date.now() - startTime < maxWaitMs) {
      const job = await this.getJobStatus(jobId);

      if (job.status === 'completed' || job.status === 'failed') {
        return job;
      }

      await new Promise(resolve => setTimeout(resolve, 3000));
    }

    throw new Error('Transcription timeout');
  }
}

// 对应 Swift 的:
// - SonioxAPI.swift
// - TranscriptionManager.swift (部分逻辑)
```

#### 2.3 数据库层迁移 (优先级: 高)

**方案A: 使用WatermelonDB (推荐)**

```typescript
// src/database/schema.ts
import { appSchema, tableSchema } from '@nozbe/watermelondb';

export const schema = appSchema({
  version: 1,
  tables: [
    tableSchema({
      name: 'collections',
      columns: [
        { name: 'title', type: 'string' },
        { name: 'description', type: 'string', isOptional: true },
        { name: 'cover_url', type: 'string', isOptional: true },
        { name: 'source_type', type: 'string' },
        { name: 'source_path', type: 'string' },
        { name: 'created_at', type: 'number' },
        { name: 'updated_at', type: 'number' },
      ]
    }),
    tableSchema({
      name: 'tracks',
      columns: [
        { name: 'collection_id', type: 'string', isIndexed: true },
        { name: 'title', type: 'string' },
        { name: 'filename', type: 'string' },
        { name: 'file_url', type: 'string' },
        { name: 'duration', type: 'number' },
        { name: 'file_size', type: 'number' },
        { name: 'md5', type: 'string', isOptional: true },
        { name: 'is_favorite', type: 'boolean' },
        { name: 'added_at', type: 'number' },
      ]
    }),
    tableSchema({
      name: 'playback_states',
      columns: [
        { name: 'track_id', type: 'string', isIndexed: true },
        { name: 'current_time', type: 'number' },
        { name: 'last_played_at', type: 'number' },
        { name: 'completed', type: 'boolean' },
      ]
    }),
    tableSchema({
      name: 'transcripts',
      columns: [
        { name: 'track_id', type: 'string', isIndexed: true },
        { name: 'text', type: 'string' },
        { name: 'language', type: 'string' },
        { name: 'confidence', type: 'number' },
        { name: 'created_at', type: 'number' },
      ]
    }),
    tableSchema({
      name: 'transcript_segments',
      columns: [
        { name: 'transcript_id', type: 'string', isIndexed: true },
        { name: 'text', type: 'string' },
        { name: 'start_time', type: 'number' },
        { name: 'end_time', type: 'number' },
        { name: 'confidence', type: 'number' },
      ]
    }),
  ]
});

// 对应 Swift 的:
// - DatabaseSchema.swift
// - TranscriptionDatabaseSchema.swift
```

```typescript
// src/database/models.ts
import { Model, Q } from '@nozbe/watermelondb';
import { field, date, children, readonly } from '@nozbe/watermelondb/decorators';

export class Collection extends Model {
  static table = 'collections';
  static associations = {
    tracks: { type: 'has_many', foreignKey: 'collection_id' },
  };

  @field('title') title!: string;
  @field('description') description?: string;
  @field('cover_url') coverUrl?: string;
  @field('source_type') sourceType!: string;
  @field('source_path') sourcePath!: string;
  @readonly @date('created_at') createdAt!: Date;
  @readonly @date('updated_at') updatedAt!: Date;

  @children('tracks') tracks!: Query<Track>;
}

export class Track extends Model {
  static table = 'tracks';
  static associations = {
    collection: { type: 'belongs_to', key: 'collection_id' },
  };

  @field('collection_id') collectionId!: string;
  @field('title') title!: string;
  @field('filename') filename!: string;
  @field('file_url') fileUrl!: string;
  @field('duration') duration!: number;
  @field('file_size') fileSize!: number;
  @field('md5') md5?: string;
  @field('is_favorite') isFavorite!: boolean;
  @readonly @date('added_at') addedAt!: Date;
}
```

#### 2.4 安全存储迁移 (优先级: 高)

```typescript
// src/services/secureStorage.ts
import * as SecureStore from 'expo-secure-store';
// 或 import Keychain from 'react-native-keychain';

export class SecureStorage {
  async saveTokens(key: string, tokens: any): Promise<void> {
    await SecureStore.setItemAsync(key, JSON.stringify(tokens));
  }

  async getTokens(key: string): Promise<any | null> {
    const value = await SecureStore.getItemAsync(key);
    return value ? JSON.parse(value) : null;
  }

  async deleteTokens(key: string): Promise<void> {
    await SecureStore.deleteItemAsync(key);
  }
}

// 对应 Swift 的:
// - KeychainBaiduOAuthTokenStore.swift
// - AIGatewayKeychainStore.swift
// - SonioxKeychainStore.swift
```

---

### 阶段3: 音频系统迁移 (Week 3-4)

#### 3.1 播放器核心 (优先级: 最高)

```typescript
// src/services/audioPlayer.ts
import TrackPlayer, {
  Capability,
  Event,
  State,
  Track as PlayerTrack
} from 'react-native-track-player';

export class AudioPlayerService {
  private static instance: AudioPlayerService;

  static getInstance() {
    if (!this.instance) {
      this.instance = new AudioPlayerService();
    }
    return this.instance;
  }

  async initialize() {
    await TrackPlayer.setupPlayer({
      waitForBuffer: true,
    });

    await TrackPlayer.updateOptions({
      capabilities: [
        Capability.Play,
        Capability.Pause,
        Capability.SkipToNext,
        Capability.SkipToPrevious,
        Capability.SeekTo,
        Capability.JumpForward,
        Capability.JumpBackward,
      ],
      compactCapabilities: [
        Capability.Play,
        Capability.Pause,
        Capability.SkipToNext,
      ],
      notificationCapabilities: [
        Capability.Play,
        Capability.Pause,
      ],
    });

    // 监听播放事件
    TrackPlayer.addEventListener(Event.PlaybackState, this.onPlaybackStateChange);
    TrackPlayer.addEventListener(Event.PlaybackProgressUpdated, this.onProgressUpdate);
  }

  async loadPlaylist(tracks: AudiobookTrack[], startIndex = 0) {
    const playerTracks: PlayerTrack[] = tracks.map((track, index) => ({
      id: track.id,
      url: track.fileUrl,
      title: track.title,
      artist: 'Audiobook',
      duration: track.duration,
      artwork: track.coverUrl,
    }));

    await TrackPlayer.reset();
    await TrackPlayer.add(playerTracks);
    await TrackPlayer.skip(startIndex);
  }

  async play() {
    await TrackPlayer.play();
  }

  async pause() {
    await TrackPlayer.pause();
  }

  async seekTo(seconds: number) {
    await TrackPlayer.seekTo(seconds);
  }

  async skipToNext() {
    await TrackPlayer.skipToNext();
  }

  async skipToPrevious() {
    await TrackPlayer.skipToPrevious();
  }

  async getPosition(): Promise<number> {
    return await TrackPlayer.getPosition();
  }

  async getDuration(): Promise<number> {
    return await TrackPlayer.getDuration();
  }

  private onPlaybackStateChange = async (event: { state: State }) => {
    // 更新UI状态
    console.log('Playback state:', event.state);
  }

  private onProgressUpdate = async (event: { position: number; duration: number }) => {
    // 保存播放进度到数据库
    console.log('Progress:', event.position, '/', event.duration);
  }
}

// 对应 Swift 的:
// - AudioPlayerViewModel.swift (核心功能)
// - 自动处理: MPRemoteCommandCenter, MPNowPlayingInfoCenter
```

#### 3.2 缓存管理器 (优先级: 中)

```typescript
// src/services/cacheManager.ts
import RNFS from 'react-native-fs';
import RNFetchBlob from 'rn-fetch-blob';

export interface CacheMetadata {
  trackId: string;
  originalUrl: string;
  localPath: string;
  fileSize: number;
  downloadedSize: number;
  cacheStatus: 'none' | 'downloading' | 'partial' | 'complete';
  createdAt: Date;
  lastAccessedAt: Date;
}

export class CacheManager {
  private cacheDir: string;
  private maxCacheSizeBytes = 2 * 1024 * 1024 * 1024; // 2GB
  private cacheTTLDays = 10;

  constructor() {
    this.cacheDir = `${RNFS.DocumentDirectoryPath}/AudioCache`;
  }

  async initialize() {
    const exists = await RNFS.exists(this.cacheDir);
    if (!exists) {
      await RNFS.mkdir(this.cacheDir);
    }
  }

  async downloadAndCache(
    trackId: string,
    url: string,
    onProgress?: (progress: number) => void
  ): Promise<string> {
    const filename = this.getFilename(trackId, url);
    const localPath = `${this.cacheDir}/${filename}`;

    // 检查是否已缓存
    const exists = await RNFS.exists(localPath);
    if (exists) {
      await this.updateAccessTime(trackId);
      return localPath;
    }

    // 下载文件
    const download = RNFetchBlob.config({
      path: localPath,
      IOSBackgroundTask: true, // 支持后台下载
    }).fetch('GET', url);

    download.progress((received, total) => {
      const progress = received / total;
      onProgress?.(progress);
    });

    await download;

    // 保存元数据
    await this.saveCacheMetadata({
      trackId,
      originalUrl: url,
      localPath,
      fileSize: (await RNFS.stat(localPath)).size,
      downloadedSize: (await RNFS.stat(localPath)).size,
      cacheStatus: 'complete',
      createdAt: new Date(),
      lastAccessedAt: new Date(),
    });

    // 检查缓存大小限制
    await this.cleanupIfNeeded();

    return localPath;
  }

  async getCachedUrl(trackId: string): Promise<string | null> {
    const metadata = await this.getCacheMetadata(trackId);

    if (!metadata || metadata.cacheStatus !== 'complete') {
      return null;
    }

    const exists = await RNFS.exists(metadata.localPath);
    if (!exists) {
      await this.removeCacheMetadata(trackId);
      return null;
    }

    await this.updateAccessTime(trackId);
    return `file://${metadata.localPath}`;
  }

  async clearCache() {
    await RNFS.unlink(this.cacheDir);
    await this.initialize();
  }

  private async cleanupIfNeeded() {
    const totalSize = await this.getTotalCacheSize();

    if (totalSize > this.maxCacheSizeBytes) {
      // LRU清理: 删除最久未访问的文件
      const allMetadata = await this.getAllCacheMetadata();
      const sorted = allMetadata.sort(
        (a, b) => a.lastAccessedAt.getTime() - b.lastAccessedAt.getTime()
      );

      let freedSize = 0;
      const targetFreeSize = totalSize - this.maxCacheSizeBytes * 0.8;

      for (const meta of sorted) {
        await this.deleteCache(meta.trackId);
        freedSize += meta.fileSize;

        if (freedSize >= targetFreeSize) break;
      }
    }

    // TTL清理: 删除过期文件
    await this.cleanupExpiredCache();
  }

  private getFilename(trackId: string, url: string): string {
    const extension = url.split('.').pop()?.split('?')[0] || 'mp3';
    return `${trackId}.${extension}`;
  }

  // 元数据存储方法 (使用AsyncStorage或SQLite)
  private async saveCacheMetadata(metadata: CacheMetadata) { /* ... */ }
  private async getCacheMetadata(trackId: string): Promise<CacheMetadata | null> { /* ... */ }
  private async getAllCacheMetadata(): Promise<CacheMetadata[]> { /* ... */ }
  private async removeCacheMetadata(trackId: string) { /* ... */ }
  private async updateAccessTime(trackId: string) { /* ... */ }
  private async getTotalCacheSize(): Promise<number> { /* ... */ }
  private async cleanupExpiredCache() { /* ... */ }
  private async deleteCache(trackId: string) { /* ... */ }
}

// 对应 Swift 的:
// - AudioCacheManager.swift
// - AudioCacheDownloadManager.swift
// - CacheProgressTracker.swift
```

---

### 阶段4: UI层迁移 (Week 4-5)

#### 4.1 Tab导航结构

```typescript
// app/(tabs)/_layout.tsx
import { Tabs } from 'expo-router';
import { Library, PlayCircle, Cpu, Mic, Settings } from '@tamagui/lucide-icons';

export default function TabsLayout() {
  return (
    <Tabs
      screenOptions={{
        headerShown: false,
        tabBarActiveTintColor: '$blue10',
      }}
    >
      <Tabs.Screen
        name="library"
        options={{
          title: 'Library',
          tabBarIcon: ({ color, size }) => <Library size={size} color={color} />,
        }}
      />
      <Tabs.Screen
        name="playing"
        options={{
          title: 'Playing',
          tabBarIcon: ({ color, size }) => <PlayCircle size={size} color={color} />,
        }}
      />
      <Tabs.Screen
        name="ai"
        options={{
          title: 'AI',
          tabBarIcon: ({ color, size }) => <Cpu size={size} color={color} />,
        }}
      />
      <Tabs.Screen
        name="tts"
        options={{
          title: 'TTS',
          tabBarIcon: ({ color, size }) => <Mic size={size} color={color} />,
        }}
      />
      <Tabs.Screen
        name="settings"
        options={{
          title: 'Settings',
          tabBarIcon: ({ color, size }) => <Settings size={size} color={color} />,
        }}
      />
    </Tabs>
  );
}
```

#### 4.2 Library列表页面

```typescript
// app/(tabs)/library.tsx
import { useState } from 'react';
import { FlatList } from 'react-native';
import { YStack, XStack, Text, Button, Image, Card } from 'tamagui';
import { Plus } from '@tamagui/lucide-icons';
import { router } from 'expo-router';
import { useLibraryStore } from '@/stores/libraryStore';

export default function LibraryScreen() {
  const collections = useLibraryStore((state) => state.collections);
  const [showImport, setShowImport] = useState(false);

  return (
    <YStack flex={1} backgroundColor="$background">
      {/* 头部 */}
      <XStack padding="$4" alignItems="center" justifyContent="space-between">
        <Text fontSize="$8" fontWeight="bold">Library</Text>
        <Button
          icon={Plus}
          onPress={() => setShowImport(true)}
          circular
          size="$4"
        />
      </XStack>

      {/* 收藏快捷入口 */}
      <Card
        margin="$4"
        padding="$4"
        pressStyle={{ opacity: 0.8 }}
        onPress={() => router.push('/favorites')}
      >
        <XStack alignItems="center" gap="$3">
          <Text fontSize="$6">⭐</Text>
          <Text fontSize="$5" fontWeight="600">Favorite Tracks</Text>
        </XStack>
      </Card>

      {/* 集合列表 */}
      <FlatList
        data={collections}
        keyExtractor={(item) => item.id}
        contentContainerStyle={{ padding: 16 }}
        ItemSeparatorComponent={() => <YStack height="$2" />}
        renderItem={({ item: collection }) => (
          <Card
            pressStyle={{ opacity: 0.8, scale: 0.98 }}
            onPress={() => router.push(`/collection/${collection.id}`)}
          >
            <XStack padding="$3" gap="$3" alignItems="center">
              {/* 封面 */}
              <Image
                source={{ uri: collection.coverUrl }}
                width={80}
                height={80}
                borderRadius="$2"
                backgroundColor="$gray5"
              />

              {/* 信息 */}
              <YStack flex={1} gap="$1">
                <Text fontSize="$5" fontWeight="600" numberOfLines={2}>
                  {collection.title}
                </Text>
                <Text fontSize="$3" color="$gray10">
                  {collection.tracks.length} tracks
                </Text>

                {/* 快速播放按钮 */}
                <XStack gap="$2" marginTop="$2">
                  <Button
                    size="$2"
                    theme="blue"
                    onPress={() => handleQuickPlay(collection)}
                  >
                    Continue
                  </Button>
                </XStack>
              </YStack>
            </XStack>
          </Card>
        )}
      />

      {/* 导入对话框 */}
      {/* <ImportSheet visible={showImport} onClose={() => setShowImport(false)} /> */}
    </YStack>
  );
}

// 对应 Swift 的:
// - LibraryView.swift
```

#### 4.3 播放器详情页

```typescript
// app/(tabs)/playing.tsx
import { YStack, XStack, Text, Button, Image, Slider, Progress } from 'tamagui';
import { Play, Pause, SkipBack, SkipForward } from '@tamagui/lucide-icons';
import { useAudioPlayer } from '@/hooks/useAudioPlayer';

export default function PlayingScreen() {
  const {
    currentTrack,
    isPlaying,
    position,
    duration,
    play,
    pause,
    seekTo,
    skipToNext,
    skipToPrevious,
  } = useAudioPlayer();

  if (!currentTrack) {
    return (
      <YStack flex={1} alignItems="center" justifyContent="center">
        <Text color="$gray10">No track playing</Text>
      </YStack>
    );
  }

  return (
    <YStack flex={1} backgroundColor="$background" padding="$4" gap="$4">
      {/* 封面 */}
      <Image
        source={{ uri: currentTrack.coverUrl }}
        width="100%"
        height={400}
        borderRadius="$4"
        resizeMode="cover"
      />

      {/* 曲目信息 */}
      <YStack gap="$2">
        <Text fontSize="$7" fontWeight="bold" textAlign="center">
          {currentTrack.title}
        </Text>
        <Text fontSize="$4" color="$gray10" textAlign="center">
          Chapter {currentTrack.trackNumber}
        </Text>
      </YStack>

      {/* 进度条 */}
      <YStack gap="$2">
        <Slider
          value={[position]}
          max={duration}
          onValueChange={([value]) => seekTo(value)}
          size="$2"
        >
          <Slider.Track>
            <Slider.TrackActive />
          </Slider.Track>
          <Slider.Thumb circular index={0} />
        </Slider>

        <XStack justifyContent="space-between">
          <Text fontSize="$2" color="$gray10">
            {formatTime(position)}
          </Text>
          <Text fontSize="$2" color="$gray10">
            {formatTime(duration)}
          </Text>
        </XStack>
      </YStack>

      {/* 播放控制 */}
      <XStack justifyContent="center" alignItems="center" gap="$4">
        <Button
          circular
          size="$5"
          icon={SkipBack}
          onPress={skipToPrevious}
        />

        <Button
          circular
          size="$6"
          icon={isPlaying ? Pause : Play}
          onPress={isPlaying ? pause : play}
          theme="blue"
        />

        <Button
          circular
          size="$5"
          icon={SkipForward}
          onPress={skipToNext}
        />
      </XStack>

      {/* 其他控制: 倍速、睡眠定时器等 */}
    </YStack>
  );
}

function formatTime(seconds: number): string {
  const mins = Math.floor(seconds / 60);
  const secs = Math.floor(seconds % 60);
  return `${mins}:${secs.toString().padStart(2, '0')}`;
}

// 对应 Swift 的:
// - PlayingView (in ContentView.swift)
```

#### 4.4 集合详情页

```typescript
// app/collection/[id].tsx
import { useState, useEffect } from 'react';
import { FlatList } from 'react-native';
import { useLocalSearchParams } from 'expo-router';
import { YStack, XStack, Text, Button, Image, Card } from 'tamagui';
import { Play, Heart, MoreVertical } from '@tamagui/lucide-icons';
import { useLibraryStore } from '@/stores/libraryStore';
import { useAudioPlayer } from '@/hooks/useAudioPlayer';

export default function CollectionDetailScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const collection = useLibraryStore((state) =>
    state.collections.find((c) => c.id === id)
  );
  const { loadPlaylist, play } = useAudioPlayer();

  if (!collection) {
    return <Text>Collection not found</Text>;
  }

  const handlePlayAll = async () => {
    await loadPlaylist(collection.tracks, 0);
    await play();
  };

  return (
    <YStack flex={1} backgroundColor="$background">
      {/* 头部: 封面 + 标题 */}
      <YStack padding="$4" gap="$3">
        <Image
          source={{ uri: collection.coverUrl }}
          width="100%"
          height={200}
          borderRadius="$4"
        />

        <Text fontSize="$7" fontWeight="bold">
          {collection.title}
        </Text>

        <Text fontSize="$4" color="$gray10">
          {collection.tracks.length} tracks • {formatTotalDuration(collection)}
        </Text>

        {/* 操作按钮 */}
        <XStack gap="$2">
          <Button flex={1} theme="blue" icon={Play} onPress={handlePlayAll}>
            Play All
          </Button>
          <Button flex={1} theme="gray">
            Shuffle
          </Button>
        </XStack>
      </YStack>

      {/* 曲目列表 */}
      <FlatList
        data={collection.tracks}
        keyExtractor={(item) => item.id}
        contentContainerStyle={{ padding: 16 }}
        ItemSeparatorComponent={() => <YStack height="$1" />}
        renderItem={({ item: track, index }) => (
          <Card
            pressStyle={{ opacity: 0.8 }}
            onPress={() => handlePlayTrack(index)}
          >
            <XStack padding="$3" alignItems="center" gap="$3">
              {/* 曲目序号 */}
              <Text fontSize="$4" color="$gray10" width={30}>
                {index + 1}
              </Text>

              {/* 曲目信息 */}
              <YStack flex={1}>
                <Text fontSize="$4" fontWeight="500" numberOfLines={1}>
                  {track.title}
                </Text>
                <Text fontSize="$2" color="$gray10">
                  {formatDuration(track.duration)}
                </Text>
              </YStack>

              {/* 收藏按钮 */}
              <Button
                circular
                size="$3"
                icon={Heart}
                chromeless
                color={track.isFavorite ? '$red10' : '$gray10'}
                onPress={() => toggleFavorite(track.id)}
              />

              {/* 更多菜单 */}
              <Button circular size="$3" icon={MoreVertical} chromeless />
            </XStack>
          </Card>
        )}
      />
    </YStack>
  );
}

// 对应 Swift 的:
// - CollectionDetailView.swift
```

---

### 阶段5: 状态管理 (Week 5)

#### 5.1 Library Store (Zustand)

```typescript
// src/stores/libraryStore.ts
import { create } from 'zustand';
import { immer } from 'zustand/middleware/immer';
import { AudiobookCollection } from '@/models/library';
import { database } from '@/database';

interface LibraryState {
  collections: AudiobookCollection[];
  isLoading: boolean;
  error: string | null;

  // Actions
  loadCollections: () => Promise<void>;
  addCollection: (collection: AudiobookCollection) => Promise<void>;
  updateCollection: (id: string, updates: Partial<AudiobookCollection>) => Promise<void>;
  deleteCollection: (id: string) => Promise<void>;
  toggleFavorite: (trackId: string) => Promise<void>;
  recordPlaybackProgress: (trackId: string, position: number) => Promise<void>;
}

export const useLibraryStore = create<LibraryState>()(
  immer((set, get) => ({
    collections: [],
    isLoading: false,
    error: null,

    loadCollections: async () => {
      set({ isLoading: true, error: null });
      try {
        const collections = await database.collections
          .query()
          .fetch();

        set({ collections, isLoading: false });
      } catch (error) {
        set({ error: error.message, isLoading: false });
      }
    },

    addCollection: async (collection) => {
      try {
        await database.write(async () => {
          await database.collections.create((c) => {
            c.title = collection.title;
            c.description = collection.description;
            c.coverUrl = collection.coverUrl;
            // ...
          });
        });

        await get().loadCollections();
      } catch (error) {
        set({ error: error.message });
      }
    },

    toggleFavorite: async (trackId) => {
      set((state) => {
        const collection = state.collections.find((c) =>
          c.tracks.some((t) => t.id === trackId)
        );
        if (collection) {
          const track = collection.tracks.find((t) => t.id === trackId);
          if (track) {
            track.isFavorite = !track.isFavorite;
          }
        }
      });

      // 持久化到数据库
      await database.write(async () => {
        const track = await database.tracks.find(trackId);
        await track.update((t) => {
          t.isFavorite = !t.isFavorite;
        });
      });
    },

    recordPlaybackProgress: async (trackId, position) => {
      await database.write(async () => {
        const existingState = await database.playbackStates
          .query(Q.where('track_id', trackId))
          .fetch();

        if (existingState.length > 0) {
          await existingState[0].update((state) => {
            state.currentTime = position;
            state.lastPlayedAt = new Date();
          });
        } else {
          await database.playbackStates.create((state) => {
            state.trackId = trackId;
            state.currentTime = position;
            state.lastPlayedAt = new Date();
            state.completed = false;
          });
        }
      });
    },
  }))
);

// 对应 Swift 的:
// - LibraryStore.swift
```

#### 5.2 Audio Player Store

```typescript
// src/stores/playerStore.ts
import { create } from 'zustand';
import TrackPlayer, { State, Event } from 'react-native-track-player';
import { AudiobookTrack } from '@/models/library';
import { useLibraryStore } from './libraryStore';

interface PlayerState {
  currentTrack: AudiobookTrack | null;
  playlist: AudiobookTrack[];
  currentIndex: number;
  isPlaying: boolean;
  position: number;
  duration: number;

  // Actions
  loadPlaylist: (tracks: AudiobookTrack[], startIndex?: number) => Promise<void>;
  play: () => Promise<void>;
  pause: () => Promise<void>;
  seekTo: (seconds: number) => Promise<void>;
  skipToNext: () => Promise<void>;
  skipToPrevious: () => Promise<void>;
  updateProgress: (position: number, duration: number) => void;
}

export const usePlayerStore = create<PlayerState>()((set, get) => ({
  currentTrack: null,
  playlist: [],
  currentIndex: 0,
  isPlaying: false,
  position: 0,
  duration: 0,

  loadPlaylist: async (tracks, startIndex = 0) => {
    const playerTracks = tracks.map((track) => ({
      id: track.id,
      url: track.fileUrl,
      title: track.title,
      duration: track.duration,
      artwork: track.coverUrl,
    }));

    await TrackPlayer.reset();
    await TrackPlayer.add(playerTracks);
    await TrackPlayer.skip(startIndex);

    set({
      playlist: tracks,
      currentIndex: startIndex,
      currentTrack: tracks[startIndex],
    });
  },

  play: async () => {
    await TrackPlayer.play();
    set({ isPlaying: true });
  },

  pause: async () => {
    await TrackPlayer.pause();
    set({ isPlaying: false });
  },

  seekTo: async (seconds) => {
    await TrackPlayer.seekTo(seconds);
    set({ position: seconds });
  },

  skipToNext: async () => {
    const { currentIndex, playlist } = get();
    if (currentIndex < playlist.length - 1) {
      await TrackPlayer.skipToNext();
      set({
        currentIndex: currentIndex + 1,
        currentTrack: playlist[currentIndex + 1],
      });
    }
  },

  skipToPrevious: async () => {
    const { currentIndex, playlist } = get();
    if (currentIndex > 0) {
      await TrackPlayer.skipToPrevious();
      set({
        currentIndex: currentIndex - 1,
        currentTrack: playlist[currentIndex - 1],
      });
    }
  },

  updateProgress: (position, duration) => {
    set({ position, duration });

    // 每10秒保存一次进度
    if (Math.floor(position) % 10 === 0) {
      const { currentTrack } = get();
      if (currentTrack) {
        useLibraryStore.getState().recordPlaybackProgress(currentTrack.id, position);
      }
    }
  },
}));

// 初始化播放器事件监听
TrackPlayer.addEventListener(Event.PlaybackState, (event) => {
  usePlayerStore.setState({
    isPlaying: event.state === State.Playing,
  });
});

TrackPlayer.addEventListener(Event.PlaybackProgressUpdated, (event) => {
  usePlayerStore.getState().updateProgress(event.position, event.duration);
});

// 对应 Swift 的:
// - AudioPlayerViewModel.swift
```

---

### 阶段6: 测试与优化 (Week 6)

#### 6.1 单元测试

```typescript
// __tests__/baiduClient.test.ts
import { BaiduNetdiskClient } from '@/api/baiduClient';

describe('BaiduNetdiskClient', () => {
  let client: BaiduNetdiskClient;

  beforeEach(() => {
    client = new BaiduNetdiskClient(mockTokenStore);
  });

  it('should list files in directory', async () => {
    const files = await client.listFiles('/audiobooks');
    expect(files).toBeInstanceOf(Array);
    expect(files[0]).toHaveProperty('path');
  });

  it('should handle token refresh on 401', async () => {
    // Mock 401 response
    // ...
  });
});
```

#### 6.2 集成测试

```typescript
// e2e/library.test.ts (使用Detox)
describe('Library Screen', () => {
  beforeAll(async () => {
    await device.launchApp();
  });

  it('should display collection list', async () => {
    await expect(element(by.text('Library'))).toBeVisible();
    await expect(element(by.id('collection-list'))).toBeVisible();
  });

  it('should navigate to collection detail', async () => {
    await element(by.id('collection-0')).tap();
    await expect(element(by.id('collection-detail'))).toBeVisible();
  });

  it('should play track', async () => {
    await element(by.id('track-0')).tap();
    await expect(element(by.id('play-button'))).toBeVisible();
    await element(by.id('play-button')).tap();
    // Assert playing state
  });
});
```

#### 6.3 性能优化

- **列表虚拟化**: FlatList自动处理
- **图片懒加载**: 使用`react-native-fast-image`
- **数据库查询优化**: WatermelonDB索引优化
- **缓存策略**: React Query或SWR
- **Code Splitting**: 使用`React.lazy` + `Suspense`

---

## 📦 关键模块映射表

### Swift → React Native 完整对照

| Swift文件 | React Native等效 | 库依赖 | 迁移难度 |
|-----------|------------------|--------|----------|
| **AudioPlayerViewModel.swift** | `src/services/audioPlayer.ts` | react-native-track-player | ⭐⭐⭐ 中等 |
| **LibraryStore.swift** | `src/stores/libraryStore.ts` | zustand | ⭐⭐ 中等 |
| **GRDBDatabaseManager.swift** | `src/database/index.ts` | WatermelonDB | ⭐⭐⭐ 中等 |
| **BaiduNetdiskClient.swift** | `src/api/baiduClient.ts` | axios | ⭐ 简单 |
| **BaiduAuthViewModel.swift** | `src/services/baiduAuth.ts` | expo-auth-session | ⭐⭐ 中等 |
| **AudioCacheManager.swift** | `src/services/cacheManager.ts` | react-native-fs | ⭐⭐⭐ 中等 |
| **TranscriptionManager.swift** | `src/services/transcriptionManager.ts` | axios | ⭐⭐ 中等 |
| **AIGatewayClient.swift** | `src/api/aiClient.ts` | axios | ⭐ 简单 |
| **LibraryView.swift** | `app/(tabs)/library.tsx` | Tamagui | ⭐⭐ 中等 |
| **CollectionDetailView.swift** | `app/collection/[id].tsx` | Tamagui | ⭐⭐ 中等 |
| **PlayingView** | `app/(tabs)/playing.tsx` | Tamagui | ⭐⭐ 中等 |
| **BaiduNetdiskBrowserView.swift** | `components/BaiduBrowser.tsx` | Tamagui | ⭐⭐⭐ 复杂 |
| **SettingsTabView.swift** | `app/(tabs)/settings.tsx` | Tamagui | ⭐ 简单 |
| **AITabView.swift** | `app/(tabs)/ai.tsx` | Tamagui | ⭐ 简单 |
| **TTSTabView** | `app/(tabs)/tts.tsx` | Tamagui | ⭐⭐ 中等 |
| **KeychainStores** | `src/services/secureStorage.ts` | expo-secure-store | ⭐ 简单 |
| **CloudKitLibrarySync.swift** | `src/services/cloudSync.ts` | Firebase/Supabase | ⭐⭐⭐⭐ 需重新设计 |

---

## 🚀 迁移优先级建议

### Phase 1: MVP (可运行的基础版本)
**目标**: 能够浏览、播放音频，保存进度

1. ✅ 项目初始化 + Tamagui配置
2. ✅ 数据模型定义 (TypeScript interfaces)
3. ✅ 数据库层 (WatermelonDB schema + models)
4. ✅ 音频播放器核心 (react-native-track-player)
5. ✅ Library UI (列表 + 详情)
6. ✅ Playing UI (基础播放控制)

### Phase 2: 完整功能
**目标**: 达到Swift版本功能对等

7. ✅ Baidu OAuth + 文件浏览
8. ✅ 音频缓存系统
9. ✅ 收藏功能
10. ✅ Settings页面
11. ✅ 播放进度持久化

### Phase 3: 高级特性
**目标**: STT、AI等增值功能

12. ✅ Soniox语音转文字
13. ✅ AI Gateway集成
14. ✅ 转录文本查看器
15. ✅ 后台上传任务

### Phase 4: 优化与发布
**目标**: 性能优化、测试、上线

16. ✅ 性能优化 (列表虚拟化、图片缓存)
17. ✅ 错误处理与重试机制
18. ✅ 单元测试 + 集成测试
19. ✅ App Store + Google Play发布

---

## 🎓 学习资源

### 官方文档
- **React Native**: https://reactnative.dev/docs/getting-started
- **Expo**: https://docs.expo.dev/
- **Tamagui**: https://tamagui.dev/docs/intro/introduction
- **WatermelonDB**: https://nozbe.github.io/WatermelonDB/
- **Track Player**: https://react-native-track-player.js.org/

### 推荐教程
- [React Native完整课程](https://www.youtube.com/watch?v=0-S5a0eXPoc) (FreeCodeCamp)
- [Tamagui快速入门](https://www.youtube.com/watch?v=OXJQeO1ynXA)
- [WatermelonDB实战](https://www.youtube.com/watch?v=rO9KZMnmjmY)

### 社区支持
- React Native Discord: https://discord.gg/reactnative
- Tamagui Discord: https://discord.gg/4qh6tdcVDa
- Stack Overflow: `[react-native]` 标签

---

## ⚠️ 注意事项与限制

### 功能损失
1. ❌ **App Intents / Siri Shortcuts**: React Native不支持
   - **替代方案**: 保留iOS原生版本用于Siri，或放弃此功能

2. ❌ **CloudKit同步**: 需替换为第三方服务
   - **替代方案**: Firebase Realtime Database 或 Supabase

3. ⚠️ **锁屏控制**: 功能完整但需原生模块
   - **解决方案**: react-native-track-player已内置支持

### 平台差异
- **iOS**: 完全支持，接近原生体验
- **Android**:
  - 后台音频限制更严格 (需处理Android 12+前台服务限制)
  - Material Design vs iOS风格 (Tamagui可统一)
  - 文件权限管理不同

### 性能考虑
- **JS Bridge开销**: 对于音频播放影响不大 (原生模块处理)
- **大列表渲染**: FlatList + WindowedList优化后可达原生90%性能
- **内存管理**: JS垃圾回收机制与Swift ARC不同，需注意循环引用

---

## 📅 时间线与里程碑

### Week 1: 基础搭建
- [ ] Expo项目初始化
- [ ] Tamagui配置完成
- [ ] 数据模型定义完成
- [ ] 数据库Schema设计

### Week 2-3: 业务逻辑
- [ ] Baidu API客户端完成
- [ ] 数据库CRUD完成
- [ ] 音频播放器核心完成
- [ ] 缓存管理器完成

### Week 4-5: UI实现
- [ ] Library + Collection Detail页面
- [ ] Playing页面
- [ ] Settings页面
- [ ] Baidu文件浏览器

### Week 6: 测试与优化
- [ ] 单元测试覆盖率 > 70%
- [ ] E2E测试核心流程
- [ ] 性能优化完成
- [ ] Bug修复

### Week 7-8: 高级功能
- [ ] STT集成
- [ ] AI Gateway
- [ ] 后台任务管理

### Week 9-10: 发布准备
- [ ] App Store审核材料
- [ ] Google Play审核材料
- [ ] 用户文档
- [ ] 发布上线

---

## 🛠️ 开发环境准备

### 必需工具
```bash
# Node.js (推荐 v18+)
brew install node

# Watchman (文件监控)
brew install watchman

# Xcode (iOS开发)
# 从App Store安装

# Android Studio (Android开发)
# https://developer.android.com/studio

# Expo CLI
npm install -g expo-cli

# iOS模拟器
xcode-select --install
```

### VSCode插件推荐
- ES7+ React/Redux/React-Native snippets
- React Native Tools
- Tamagui IntelliSense
- Prettier
- ESLint
- TypeScript Vue Plugin (Volar)

---

## 📞 下一步行动

1. **决策时间**: 评估是否开始迁移
2. **技术验证**: 创建概念验证原型 (1-2天)
3. **详细规划**: 细化每个模块的迁移方案
4. **开始迁移**: 按阶段执行迁移计划

---

**文档版本**: 1.0
**最后更新**: 2025-11-12
**维护者**: [Your Name]

---

## 附录: 快速启动命令

```bash
# 1. 创建项目
npx create-expo-app audiobook-player-rn --template blank-typescript
cd audiobook-player-rn

# 2. 安装依赖
npm install tamagui @tamagui/config expo-router react-native-track-player zustand

# 3. 启动开发服务器
npx expo start

# 4. 在iOS模拟器中运行
npx expo run:ios

# 5. 在Android模拟器中运行
npx expo run:android
```

---

## 附录: 问题诊断

### 常见问题

#### Q: Metro bundler无法启动
```bash
# 清理缓存
npx expo start --clear

# 重置Metro
rm -rf node_modules/.cache
```

#### Q: iOS构建失败
```bash
# 清理Xcode
cd ios
pod deintegrate
pod install
cd ..
```

#### Q: Android构建失败
```bash
# 清理Gradle
cd android
./gradlew clean
cd ..
```

#### Q: Track Player初始化失败
```bash
# 确保在AppRegistry.registerComponent之前调用
TrackPlayer.setupPlayer()
```
