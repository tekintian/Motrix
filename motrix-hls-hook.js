/**
 * motrix-hls-hook.js  —  Motrix aria2 RPC HLS 检测中间件
 * -----------------------------------------------------------------------------
 * 问题: aria2 RPC 的 addUri 方法不自动检测 HLS (即使 HTTP .m3u8 + Content-Type 正确)
 *       aria2 只下载 m3u8 文本本身, 不解析分片下载合并
 *       HLS 自动检测只在 aria2 命令行模式生效
 *
 * 方案: 拦截 aria2.addUri RPC 调用, 检测 .m3u8 URL → 改用 aria2c 命令行
 *       (aria2c 命令行原生支持 HLS: 解析 m3u8 → 多连接下载分片 → 合并)
 *
 * 集成: 在 Motrix 的 RPC 请求处理器里, 调用本模块的 hookAddUri()
 *       如果返回非 null → 用返回值作为 RPC 响应 (已用命令行处理)
 *       如果返回 null → 正常转发给 aria2 RPC (非 HLS)
 *
 * 用法 (在 Motrix 的 RPC 路由/中间件层):
 *   const { hookAddUri } = require('./motrix-hls-hook')
 *   // 在 aria2 RPC 请求处理前:
 *   const hlsResult = await hookAddUri(method, params, {
 *     aria2cPath: '/path/to/aria2c',  // aria2c 二进制路径
 *     defaultDir: '/Users/xxx/Downloads',  // 默认下载目录
 *   })
 *   if (hlsResult) return reply.send(hlsResult)  // 已用命令行处理
 *   // 否则继续走 aria2 RPC
 * -----------------------------------------------------------------------------
 */
const { execFile } = require('child_process')
const path = require('path')
const os = require('os')

/**
 * 拦截 aria2.addUri, 检测 HLS
 * @param {string} method - RPC 方法名 (如 'aria2.addUri')
 * @param {Array} params - RPC 参数 (可能含 token:secret + [uris] + options)
 * @param {object} opts - { aria2cPath, defaultDir }
 * @returns {Promise<object|null>} - 非 null = 已处理 (返回 mock RPC 响应); null = 非 HLS, 正常走 RPC
 */
async function hookAddUri (method, params, opts = {}) {
  if (method !== 'aria2.addUri') return null

  // 解析参数: 可能是 [token, [uris], options] 或 [[uris], options]
  let urisIdx = 0
  if (params[0] && typeof params[0] === 'string' && params[0].startsWith('token:')) {
    urisIdx = 1
  }
  const uris = params[urisIdx]
  const options = params[urisIdx + 1] || {}

  if (!Array.isArray(uris) || !uris.length) return null
  const url = uris[0]

  // 检测 HLS: URL 以 .m3u8 或 .m3u 结尾 (忽略 query params)
  if (!/\.m3u8?(\?|$)/i.test(url)) return null

  console.log(`[Motrix-HLS-Hook] HLS detected: ${url.slice(0, 100)}`)

  // 用 aria2c 命令行下载 (原生支持 HLS: 解析 m3u8 → 多连接下载分片 → 合并)
  const aria2cPath = opts.aria2cPath || findAria2c()
  const dir = options.dir || opts.defaultDir || path.join(os.homedir(), 'Downloads')
  const out = options.out || `video_${Date.now()}.ts`

  // aria2c 参数: 多连接加速 + 输出目录 + 文件名 + URL
  const args = [
    '-x', '16',           // 每服务器最大 16 连接
    '-s', '16',           // 分片 16 连接
    '-k', '1M',           // 分片大小 1MB
    '--file-allocation=none',
    '-d', dir,             // 下载目录
    '-o', out,             // 输出文件名
    url                    // HLS URL (HTTP 或 file://)
  ]

  console.log(`[Motrix-HLS-Hook] exec: ${aria2cPath} ${args.join(' ')}`)

  return new Promise((resolve) => {
    const child = execFile(aria2cPath, args, {
      cwd: dir,
      maxBuffer: 10 * 1024 * 1024,
      timeout: 600000  // 10 分钟超时
    }, (err, stdout, stderr) => {
      if (err) {
        console.error(`[Motrix-HLS-Hook] aria2c failed:`, err.message)
        resolve({
          jsonrpc: '2.0',
          id: Date.now(),
          error: { code: 1, message: `HLS download failed: ${err.message}` }
        })
      } else {
        console.log(`[Motrix-HLS-Hook] HLS download complete: ${path.join(dir, out)}`)
        resolve({
          jsonrpc: '2.0',
          id: Date.now(),
          result: `hls-${Date.now()}`  // mock gid
        })
      }
    })

    // 可选: 实时输出 aria2c 进度
    if (child.stdout) {
      child.stdout.on('data', (data) => {
        const lines = data.toString().split('\n').filter(l => l.trim())
        lines.forEach(l => {
          if (l.includes('%') || l.includes('DL:') || l.includes('completed')) {
            console.log(`[Motrix-HLS-Hook] ${l.trim()}`)
          }
        })
      })
    }
  })
}

/**
 * 查找 aria2c 二进制路径 (Motrix 内嵌的 aria2)
 */
function findAria2c () {
  const platform = process.platform
  const exeName = platform === 'win32' ? 'aria2c.exe' : 'aria2c'

  // Motrix 内嵌 aria2 的常见路径
  const candidates = [
    // Motrix v2.x (Electron extraResources)
    path.join(process.resourcesPath || '', 'extraResources', exeName),
    path.join(process.resourcesPath || '', 'aria2', exeName),
    // Motrix v1.x (node_modules)
    path.join(__dirname, 'node_modules', '.bin', exeName),
    // 系统 PATH
    exeName
  ]

  return candidates[0] || exeName  // 简化: 返回第一个候选
}

module.exports = { hookAddUri, findAria2c }
