// 移植自 iOS TrackSummaryGenerator（摘要路径）。纯函数，不依赖 Electron，便于单测。
// JSON schema 必须与 AudiobookPlayer/TrackSummaryGenerator.swift 保持一致。

export interface PromptSegment { startMs: number; text: string }
export interface PromptContext {
  trackTitle: string
  trackDuration: number | null
  trackAuthor: string | null
  collectionTitle: string | null
  collectionDescription: string | null
  segments: PromptSegment[]
}
export interface SummaryPrompts { systemPrompt: string; userPrompt: string }

export interface ParsedSummarySection { orderIndex: number; startTimeMs: number; endTimeMs: number | null; title: string | null; summary: string; keywords: string[] }
export interface ParsedSummaryTranslation { orderIndex: number; startTimeMs: number; translation: string }
export interface ParsedTrackSummary {
  summaryTitle: string | null
  summaryBody: string
  keywords: string[]
  mentionedItems: string[]
  suggestedCorrections: Record<string, string>
  sections: ParsedSummarySection[]
  translations: ParsedSummaryTranslation[]
}

const SYSTEM_PROMPT = `You are an audiobook editor. Produce accurate summaries and outlines of narrated recordings.
The transcript may have some typos, try to fix them use the correct ones in your summary.
Output strictly valid JSON using the schema provided. Keep sections chronological, non-overlapping,
and representative of the actual transcript. Reuse the provided millisecond timestamps so the app can seek directly.
Reply in the same language as the transcript.
Use corrections in summary and sections.`

const SCHEMA = `{
  "summary": {
    "suggested_corrections": {
      "incorrect spelling": "correct spelling"
    },
    "title": "optional short title",
    "overview": "Summarizing the overall track",
    "keywords": ["keyword1", "keyword2"],
    "mentioned_items": ["《Book Title》(Author)", "《Movie Name》(Director, year)"],
  },
  "sections": [
    {
      "order": 1,
      "start_ms": 0,
      "end_ms": 180000,
      "title": "optional section title",
      "summary": "1-2 sentence blurb of the section",
      "keywords": ["topic", "theme"]
    }
  ],
  "translations":[ // optional, include when 1. this is a song or short transcript under 5 minute. 2. when the instruction explictly ask for it.
  {
  "order":1,
  "start_ms": xx,
  "translation": "xxxxxxx",
  }
  ]
}`

const pad2 = (n: number): string => String(n).padStart(2, '0')

export function timecodeFor(ms: number): string {
  const totalSeconds = Math.floor(ms / 1000)
  const hours = Math.floor(totalSeconds / 3600)
  const minutes = Math.floor((totalSeconds % 3600) / 60)
  const seconds = totalSeconds % 60
  return hours > 0 ? `${pad2(hours)}:${pad2(minutes)}:${pad2(seconds)}` : `${pad2(minutes)}:${pad2(seconds)}`
}

function formatDuration(duration: number): string {
  const totalSeconds = Math.floor(duration)
  const hours = Math.floor(totalSeconds / 3600)
  const minutes = Math.floor((totalSeconds % 3600) / 60)
  return hours > 0 ? `${hours}h ${pad2(minutes)}m` : `${minutes}m ${pad2(totalSeconds % 60)}s`
}

export function makeSummaryPrompts(context: PromptContext): SummaryPrompts {
  const metadata: string[] = [`Track title: ${context.trackTitle}`]
  if (context.trackAuthor) metadata.push(`Author/Narrator: ${context.trackAuthor}`)
  if (context.collectionTitle) metadata.push(`Collection: ${context.collectionTitle}`)
  if (context.trackDuration != null) metadata.push(`Duration: ${formatDuration(context.trackDuration)}`)
  if (context.collectionDescription) metadata.push(`Collection description: ${context.collectionDescription}`)

  const excerpt = (() => {
    const lines = [...context.segments]
      .sort((a, b) => a.startMs - b.startMs)
      .map(segment => {
        const sanitized = segment.text.replace(/\n/g, ' ').replace(/\t/g, ' ').trim()
        if (!sanitized) return null
        return `[${timecodeFor(segment.startMs)} | start_ms=${segment.startMs}] ${sanitized}`
      })
      .filter((line): line is string => line !== null)
    return lines.length ? lines.join('\n') : 'No transcript available.'
  })()

  const userPrompt = `You will receive ordered transcript segments with timestamps.
        

Metadata:
${metadata.join('\n')}

Requirements:
- Decide whether the transcript is primarily song lyrics or a regular narration.
- If it is a song or short transcript (under 5 minutes):
  - Keep using this template but describe the song (title, performer, release background, etc.) in \`summary.overview\`, adding any notable context when the track is well known.
  - Don't include \`sections\` field. Beacuse the audio is short or song, sections are not needed.
- If it is not a song, follow the normal audiobook summary workflow.

Translation Requirements:
- Only include \`translations\` when the track is a song or the transcript is under 5 minutes. For other cases, don't return 'translations' field.

Other Requirements:
- Provide a concise overview (2-3 sentences).
- Sections must have \`start_ms\` integers derived from the provided \`start_ms\` values (do not invent new times).
- Keep \`end_ms\` optional; omit if uncertain.
- Provide up to 5 concise keywords per section and globally.
- Extract any books or movies mentioned in the transcript into \`mentioned_items\`. Format: "Title (Author/Director, Year)" if author/director and year are mentioned in the transcript; otherwise just "Title".
- For correction, don't change the language, eg correct English into Chinese, you should correct within the same language.
- Identify frequent obvious typos in important terms (movie titles, book titles, people names) that appear repeatedly in the transcript.
- IMPORTANT: Only suggest corrections where the incorrect and correct spellings are DIFFERENT. Do NOT include entries where both sides are identical (e.g., "王家卫": "王家卫" is invalid).
- Return \`suggested_corrections\` as a dictionary: keys are incorrect spellings found in the transcript, values are their correct spellings. For common errors with variations (e.g., '错误1', '错误2', '错误h'), consolidate them into a single canonical correction entry (e.g., '错误': '正确').
- Only include important repeated errors that need fixing, not minor one-off typos.
- Use the corrected spellings in your summary and section texts.
- Output ONLY JSON, no prose, matching this schema exactly:
- Always use Chinese for the result no matter what the input language is.

${SCHEMA}

Transcript segments (format: [HH:MM:SS | start_ms=NNN] text):
${excerpt}
`
  return { systemPrompt: SYSTEM_PROMPT, userPrompt }
}

// ---------- 响应解析（对应 iOS parseResponse / decodeResponse） ----------

const trimToNull = (value: unknown): string | null => {
  if (typeof value !== 'string') return null
  const trimmed = value.trim()
  return trimmed ? trimmed : null
}

function parseTimecode(text: string): number | null {
  const trimmed = text.trim().replace(/seconds/g, '').replace(/s/g, '')
  if (trimmed.includes(':')) {
    const pieces = trimmed.split(':')
    let multiplier = 1
    let totalSeconds = 0
    for (let i = pieces.length - 1; i >= 0; i--) {
      const value = Number(pieces[i].replace(',', '.'))
      if (!Number.isFinite(value)) return null
      totalSeconds += value * multiplier
      multiplier *= 60
    }
    return Math.floor(totalSeconds * 1000)
  }
  const value = Number(trimmed.replace(',', '.'))
  return Number.isFinite(value) ? Math.floor(value * 1000) : null
}

interface RawTimingFields { start_ms?: unknown; start_time_ms?: unknown; start_seconds?: unknown; start_time?: unknown; end_ms?: unknown; end_time_ms?: unknown; end_seconds?: unknown; end_time?: unknown }

function normalizedMs(raw: unknown, prefix: 'start' | 'end'): number | null {
  const fields = raw as RawTimingFields
  const ms = prefix === 'start' ? fields.start_ms : fields.end_ms
  if (typeof ms === 'number' && Number.isFinite(ms)) return ms
  const timeMs = prefix === 'start' ? fields.start_time_ms : fields.end_time_ms
  if (typeof timeMs === 'number' && Number.isFinite(timeMs)) return timeMs
  const seconds = prefix === 'start' ? fields.start_seconds : fields.end_seconds
  if (typeof seconds === 'number' && Number.isFinite(seconds)) return Math.floor(seconds * 1000)
  const time = prefix === 'start' ? fields.start_time : fields.end_time
  if (typeof time === 'string') return parseTimecode(time)
  return null
}

export function cleanedJSON(raw: string): string {
  let trimmed = raw.trim()
  if (!trimmed) return ''
  if (trimmed.startsWith('```')) {
    const fence = trimmed.match(/^```(?:json|JSON)?/)
    if (fence) {
      const afterFence = trimmed.slice(fence[0].length)
      const closing = afterFence.indexOf('```')
      if (closing >= 0) trimmed = afterFence.slice(0, closing)
    }
  }
  const firstBrace = trimmed.indexOf('{')
  const lastBrace = trimmed.lastIndexOf('}')
  if (firstBrace === -1 || lastBrace === -1) return trimmed
  return trimmed.slice(firstBrace, lastBrace + 1)
}

const stringArray = (value: unknown): string[] => Array.isArray(value) ? value.filter((v): v is string => typeof v === 'string' && v.trim() !== '') : []

export function parseSummaryResponse(raw: string): ParsedTrackSummary {
  const cleaned = cleanedJSON(raw)
  if (!cleaned) throw new Error('AI 未返回任何摘要内容。')
  let payload: unknown
  try { payload = JSON.parse(cleaned) } catch { throw new Error('摘要响应不是有效的 JSON。') }
  const summary = (payload as { summary?: unknown })?.summary as Record<string, unknown> | undefined
  if (!summary || typeof summary !== 'object') throw new Error('摘要响应缺少 summary 字段。')

  const summaryBody = trimToNull(summary.overview)
  if (!summaryBody) throw new Error('摘要正文为空，请让模型重试。')

  const corrections: Record<string, string> = {}
  if (summary.suggested_corrections && typeof summary.suggested_corrections === 'object') {
    for (const [key, value] of Object.entries(summary.suggested_corrections)) {
      if (typeof value === 'string' && key.trim() && value.trim() && key.trim() !== value.trim()) corrections[key] = value
    }
  }

  const sectionsRaw = Array.isArray((payload as { sections?: unknown })?.sections) ? (payload as { sections: unknown[] }).sections : []
  const sections = sectionsRaw
    .map((section: unknown): ParsedSummarySection | null => {
      const s = section as Record<string, unknown>
      const startMs = normalizedMs(s, 'start')
      const blurb = trimToNull(s?.summary)
      if (startMs == null || !blurb) return null
      const endMs = normalizedMs(s, 'end')
      return {
        orderIndex: typeof s.order === 'number' ? s.order : 0,
        startTimeMs: Math.max(0, startMs),
        endTimeMs: endMs != null ? Math.max(0, endMs) : null,
        title: trimToNull(s.title),
        summary: blurb,
        keywords: stringArray(s.keywords)
      }
    })
    .filter((s): s is ParsedSummarySection => s !== null)
    .sort((a, b) => a.startTimeMs === b.startTimeMs ? a.orderIndex - b.orderIndex : a.startTimeMs - b.startTimeMs)
    .map((section, index) => ({ ...section, orderIndex: index }))

  const translationsRaw = Array.isArray((payload as { translations?: unknown })?.translations) ? (payload as { translations: unknown[] }).translations : []
  const translations = translationsRaw
    .map((entry: unknown): ParsedSummaryTranslation | null => {
      // 兼容 tuple 形式 [order, translation]（常规摘要路径缺少 start_ms，会被丢弃，与 iOS 一致）
      if (Array.isArray(entry)) {
        const tuple = entry as unknown[]
        const order = typeof tuple[0] === 'number' ? tuple[0] : 0
        const text = trimToNull(tuple[1])
        if (!text) return null
        return { orderIndex: order, startTimeMs: Number.NaN, translation: text }
      }
      if (!entry || typeof entry !== 'object') return null
      const obj = entry as Record<string, unknown>
      const startMs = normalizedMs(obj, 'start')
      const text = trimToNull(obj.translation)
      if (startMs == null || !text) return null
      return { orderIndex: typeof obj.order === 'number' ? obj.order : 0, startTimeMs: Math.max(0, startMs), translation: text }
    })
    .filter((t): t is ParsedSummaryTranslation => t !== null && Number.isFinite(t.startTimeMs))
    .sort((a, b) => a.startTimeMs === b.startTimeMs ? a.orderIndex - b.orderIndex : a.startTimeMs - b.startTimeMs)
    .map((t, index) => ({ ...t, orderIndex: index }))

  return {
    summaryTitle: trimToNull(summary.title),
    summaryBody,
    keywords: stringArray(summary.keywords),
    mentionedItems: stringArray(summary.mentioned_items),
    suggestedCorrections: corrections,
    sections,
    translations
  }
}
