import { net } from 'electron'

export function isAsciiHeaderValue(value: string): boolean { for (let i=0;i<value.length;i++) if (value.charCodeAt(i)>255) return false; return true }
export function fetchWithElectronNet(url: string, headers: Record<string,string> = {}): Promise<Response> {
  return new Promise((resolve,reject) => {
    const req = net.request({ url, method:'GET', headers })
    req.on('response', response => {
      const out = new Headers()
      for (const key of Object.keys(response.headers)) { const raw=response.headers[key]; if (raw===undefined) continue; const value=Array.isArray(raw)?raw.join(', '):String(raw); if (!isAsciiHeaderValue(key)||!isAsciiHeaderValue(value)) continue; try { out.set(key,value) } catch {} }
      const body = new ReadableStream<Uint8Array>({ start(controller) { response.on('data', chunk => controller.enqueue(new Uint8Array(chunk))); response.on('end',()=>controller.close()); response.on('error',e=>controller.error(e)) }, cancel(){req.abort()} })
      resolve(new Response(body,{status:response.statusCode || 502,headers:out}))
    }); req.on('error',reject); req.end()
  })
}
