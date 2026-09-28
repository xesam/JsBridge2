// 冒烟测试：pull transport 的 C40/C41 语义（node + mocked window，直接跑 IIFE 产物）
const fs = require('fs')
const path = require('path')

function makeWindow() {
    const listeners = { message: [], pageshow: [] }
    const win = {
        __jsbridge2__: {},
        addEventListener(type, fn) { listeners[type].push(fn) },
        removeEventListener() {},
        console: console,
        Math, Date, setTimeout, clearTimeout,
    }
    win.__mkListeners = listeners
    return win
}

const g = makeWindow()
global.window = g
// IIFE 产物挂在 global
const code = fs.readFileSync(path.join(__dirname, '../dist/iife/jsbridge-sdk.js'), 'utf-8')
const SDK = new Function('window', code + '; return JsBridgeSDK;')(g)

if (!SDK) { throw new Error('JsBridgeSDK global missing') }

let assertCount = 0
function assert(cond, msg) {
    if (!cond) { throw new Error('FAIL: ' + msg) }
    assertCount++
    console.log('  ok -', msg)
}

const waits = []
const wait = ms => new Promise(r => waits.push(setTimeout(r, ms)))

function deliver(reqId, withPort) {
    const port = withPort
        ? { closed: false, onmessage: null, postMessage(m) { port.sent.push(m) }, close() { port.closed = true }, sent: [] }
        : null
    // 与真实 Native 投递一致：MessageEvent.source === window（C59 投递信任边界，
    // 恶意 iframe 构造的同形事件 source !== window 必须被拒）
    const ev = { data: JSON.stringify({ type: 'bridge:channel', reqId }), ports: port ? [port] : [], source: g }
    for (const fn of g.__mkListeners.message) { fn(ev) }
    return port
}

;(async () => {
    console.log('C40: 匹配 reqId 采纳 / 缺 reqId 拒绝')

    // 哑入口记录请求
    const requests = []
    g.__jsbridge2__.requestBridgeChannel = optsJson => {
        requests.push(JSON.parse(optsJson))
        return JSON.stringify({ ok: true, reqId: JSON.parse(optsJson).reqId })
    }

    const errors = []
    const t = SDK.createNativeTransport()
    t.onChannelError(e => errors.push(e))
    assert(requests.length === 1, '构造后即发出 pull 请求（因果序②）')
    const reqId1 = requests[0].reqId
    assert(typeof reqId1 === 'string' && reqId1.length > 0, '请求携带 reqId')

    // 缺 reqId 的投递 → 不采纳
    const p0 = deliver('', true)
    assert(p0.closed === true, '缺 reqId 投递被丢弃且端口关闭')

    // 匹配投递 → 采纳
    const p1 = deliver(reqId1, true)
    assert(p1.closed !== true, '匹配 reqId 投递被采纳')

    // 同 reqId 重复投递 → 幂等忽略 + 关闭重复端口
    const p1dup = deliver(reqId1, true)
    assert(p1dup.closed === true, '同 reqId 重复投递幂等忽略且关闭')

    // 消息经采纳端口出网
    let received = []
    t.onMessage(m => received.push(m))
    t.send('{"hello":1}')
    await wait(80)
    assert(p1.sent.includes('{"hello":1}'), '消息经采纳端口出网')

    console.log('C41: 陈旧 reqId 丢弃 + 轮换')
    // 第二次构造 transport 被双实例守卫复用，且不得重复发起 pull 请求
    const t2 = SDK.createNativeTransport()
    assert(t2 === t, '双实例守卫：第二次 createNativeTransport 复用既有实例')
    assert(requests.length === 1, '双实例守卫复用不重复发起 pull 请求')
    assert(errors.length === 0, '正常建链路径无 channel error 回执')

    // 陈旧投递：reqId 与任何当前请求都不匹配
    const stale = deliver('r-999-dead', true)
    assert(stale.closed === true, '陈旧 reqId 投递被丢弃且端口关闭')
    assert(p1.closed !== true, '当前端口不受陈旧投递影响')

    console.log('\n全部通过，断言数:', assertCount)
})().catch(e => { console.error(e); process.exit(1) })
