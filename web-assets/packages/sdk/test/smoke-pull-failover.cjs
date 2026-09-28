// 冒烟测试 2：信道失败 / Bfcache 自愈 / 轮换关旧端口（独立 eval 上下文，绕开模块单例）
const fs = require('fs')
const path = require('path')

function loadSdk(win) {
    const code = fs.readFileSync(path.join(__dirname, '../dist/iife/jsbridge-sdk.js'), 'utf-8')
    return new Function('window', code + '; return JsBridgeSDK;')(win)
}

function makeWindow() {
    const listeners = { message: [], pageshow: [] }
    const win = {
        __jsbridge2__: {},
        addEventListener(type, fn) { listeners[type].push(fn) },
        removeEventListener() {},
        console, Math, Date, setTimeout, clearTimeout,
        __listeners: listeners,
    }
    return win
}

let assertCount = 0
function assert(cond, msg) {
    if (!cond) { throw new Error('FAIL: ' + msg) }
    assertCount++
    console.log('  ok -', msg)
}
const wait = ms => new Promise(r => setTimeout(r, ms))

function deliver(win, reqId) {
    const port = { closed: false, onmessage: null, sent: [], postMessage(m) { port.sent.push(m) }, close() { port.closed = true } }
    // 与真实 Native 投递一致：MessageEvent.source === window（C59 投递信任边界）
    const ev = { data: JSON.stringify({ type: 'bridge:channel', reqId }), ports: [port], source: win }
    for (const fn of win.__listeners.message) { fn(ev) }
    return port
}

;(async () => {
    console.log('A: 入口不存在（浏览器直开）→ E_CHANNEL_CLOSED')
    {
        const win = makeWindow()
        const SDK = loadSdk(win)
        const errors = []
        const t = SDK.createNativeTransport({ channelTimeoutMs: 30, maxChannelRetries: 2, retryBackoffMs: 20 })
        t.onChannelError(e => errors.push(e))
        t.send('{"hello":1}')
        await wait(400)
        assert(errors.length === 1, '信道建立失败产生一次 channel error')
        assert(errors[0].code === 'E_CHANNEL_CLOSED', '错误码为 E_CHANNEL_CLOSED')
        assert(errors[0].retryable === true, 'retryable=true（退避重试建通道）')
    }

    console.log('B: reqId 超时重试换新 reqId')
    {
        const win = makeWindow()
        const SDK = loadSdk(win)
        const requests = []
        win.__jsbridge2__.requestBridgeChannel = opts => {
            const o = JSON.parse(opts)
            requests.push(o.reqId)
            return JSON.stringify({ ok: true, reqId: o.reqId })
        }
        const t = SDK.createNativeTransport({ channelTimeoutMs: 30, maxChannelRetries: 99, retryBackoffMs: 200 })
        // 轮询等待第二次请求发出（仍在最新请求存活窗口内）
        while (requests.length < 2) { await wait(10) }
        assert(new Set(requests).size === requests.length, '每次重试换新 reqId')
        // 迟到的第一次请求投递 → 陈旧，须被丢弃
        const late = deliver(win, requests[0])
        assert(late.closed === true, '迟到旧投递被丢弃且关闭（迟到投递漏洞防护）')
        // 最新请求投递 → 采纳
        const fresh = deliver(win, requests[requests.length - 1])
        assert(fresh.closed !== true, '最新 reqId 投递被采纳')
    }

    console.log('C: Bfcache 恢复 → 旧端口关闭 + 新 reqId 重建（轮换粗语义）')
    {
        const win = makeWindow()
        const SDK = loadSdk(win)
        const requests = []
        win.__jsbridge2__.requestBridgeChannel = opts => {
            const o = JSON.parse(opts)
            requests.push(o.reqId)
            return JSON.stringify({ ok: true, reqId: o.reqId })
        }
        const t = SDK.createNativeTransport({ channelTimeoutMs: 50 })
        const p1 = deliver(win, requests[0])
        assert(p1.closed !== true, '初始端口采纳')
        // 触发 Bfcache 恢复
        const ev = { persisted: true }
        for (const fn of win.__listeners.pageshow) { fn(ev) }
        assert(p1.closed === true, 'pageshow(persisted) 后旧端口同步关闭')
        assert(requests.length === 2, '恢复后以新 reqId 重新请求')
        const p2 = deliver(win, requests[1])
        assert(p2.closed !== true, '新端口采纳（通道重建）')
        let got = []
        t.onMessage(m => got.push(m))
        t.send('{"after":1}')
        await wait(80)
        assert(p2.sent.includes('{"after":1}'), '消息经新端口出网')
    }

    console.log('\n全部通过，断言数:', assertCount)
    process.exit(0)
})().catch(e => { console.error(e); process.exit(1) })
