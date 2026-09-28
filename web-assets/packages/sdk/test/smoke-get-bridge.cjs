// 冒烟测试：官方装载器 getBridge（node + mocked window/document，直接跑 IIFE 产物）。
// 覆盖此前零执行路径的三个核心声称（sdk README getBridge / docs/06 §6.3）：
//   ① 动态注入失败 → 拒绝且落定后清缓存（缓存清除发生在 promise 落定之后——executor 内置空缓存是无效操作）
//   ② 失败后可重试：清缓存后再次调用重新编排（第二个 <script> 元素）
//   ③ 成功路径：文件→通道→会话三层折叠为单例 ready 信号，resolve 已握手 client 三件套
const fs = require('fs')
const path = require('path')

function makeWindow() {
    const listeners = { message: [], pageshow: [] }
    const scripts = []
    const win = {
        __jsbridge2__: {},
        addEventListener(type, fn) { listeners[type].push(fn) },
        removeEventListener() {},
        console,
        Math, Date, setTimeout, clearTimeout,
        document: {
            head: { appendChild(el) { scripts.push(el) } },
            createElement() {
                return { src: '', remove() {}, onload: null, onerror: null }
            },
        },
    }
    win.__mkListeners = listeners
    win.__mkScripts = scripts
    return win
}

const g = makeWindow()
global.window = g
global.document = g.document
const code = fs.readFileSync(path.join(__dirname, '../dist/iife/jsbridge-sdk.js'), 'utf-8')
const SDK = new Function('window', code + '; return JsBridgeSDK;')(g)

if (!SDK) { throw new Error('JsBridgeSDK global missing') }
if (typeof SDK.getBridge !== 'function') { throw new Error('getBridge not exported') }

let assertCount = 0
function assert(cond, msg) {
    if (!cond) { throw new Error('FAIL: ' + msg) }
    assertCount++
    console.log('  ok -', msg)
}

const wait = ms => new Promise(r => setTimeout(r, ms))

function deliverChannel(reqId) {
    const port = { closed: false, onmessage: null, postMessage(m) { port.sent.push(m) }, close() { port.closed = true }, sent: [] }
    const ev = { data: JSON.stringify({ type: 'bridge:channel', reqId }), ports: [port], source: g }
    for (const fn of g.__mkListeners.message) { fn(ev) }
    return port
}

// 握手成功响应帧（响应关联：reqId 回显请求 id，docs/03 §2）
function handshakeResponse(reqId, payload) {
    return JSON.stringify({
        id: 'resp_' + Math.random().toString(36).slice(2),
        sessionId: payload.sessionId,
        kind: 'response',
        method: 'bridge.handshake',
        ts: Date.now(),
        timeoutMs: 0,
        keep: false,
        payload,
        reqId,
        done: true,
        ok: true,
        error: null,
    })
}

;(async () => {
    console.log('阶段①: 动态注入失败 → 拒绝并清缓存')
    const failP = SDK.getBridge({ sdkUrl: '/sdk-missing.js', loadTimeoutMs: 100 })
    assert(g.__mkScripts.length === 1, '给出 sdkUrl 时经 <script> 动态注入')
    assert(g.__mkScripts[0].src === '/sdk-missing.js', '注入地址取 sdkUrl')
    g.__mkScripts[0].onerror() // 模拟加载失败（onerror 先于超时定时器触发）
    const failErr = await failP.then(
        () => { throw new Error('注入失败必须 reject') },
        (err) => err,
    )
    assert(/jsbridge-sdk load failed/.test(String(failErr)), '拒绝原因携带 load failed：' + failErr)

    console.log('阶段②: 失败后缓存已清——再次调用重新编排')
    g.JsBridgeSDK = SDK // 模拟随后 SDK 已就位（跳过注入直用 SdkEntry）
    const pullRequests = []
    g.__jsbridge2__.requestBridgeChannel = optsJson => {
        const req = JSON.parse(optsJson)
        pullRequests.push(req)
        return JSON.stringify({ ok: true, reqId: req.reqId })
    }
    const readyP = SDK.getBridge()
    assert(g.__mkScripts.length === 1, 'JsBridgeSDK 已就位时不再注入 <script>')
    await wait(20)
    assert(pullRequests.length === 1, '装载器经 createNativeTransport 发起唯一 pull 请求')

    console.log('阶段③: 通道就绪 + 握手响应 → ready 三件套')
    const port = deliverChannel(pullRequests[0].reqId)
    assert(port.closed !== true, 'reqId 匹配投递被采纳')
    assert(port.sent.length === 1, '信道采纳同步冲刷待发队列（握手请求出网）')
    const handshakeFrame = JSON.parse(port.sent[0])
    assert(handshakeFrame.method === 'bridge.handshake', '装载器发出的首个请求是握手')
    const sessionId = 's-smoke-loader'
    port.onmessage({ data: handshakeResponse(handshakeFrame.id, {
        sessionId, sessionTtlMs: 60000, policyVersion: 'v1', origin: 'https://arbitrary.example', accepted: true,
    }) })
    const ready = await readyP
    assert(ready !== null && typeof ready === 'object', 'ready resolve 为对象')
    assert(ready.client && ready.transport && ready.bridgeClient, 'BridgeReadyResult 三件套齐备（client/transport/bridgeClient）')
    assert(typeof ready.client.callNativeApi === 'function' && typeof ready.transport.send === 'function',
        'client 是门控 JsBridgeClient、transport 是 NativeTransport')
    assert(SDK.getBridge() === readyP, '单例：后续 getBridge() 复用同一 ready 信号')

    console.log('\n全部通过，断言数:', assertCount)
})().catch(e => { console.error(e); process.exit(1) })
