#!/usr/bin/env node
const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");

function sleep(ms) {
    return new Promise(resolve => setTimeout(resolve, ms));
}

function createSandbox() {
    const sandbox = {
        console: {
            log: () => {},
            warn: () => {},
            error: () => {}
        },
        setTimeout,
        clearTimeout,
        Date,
        Math,
        Map,
        JSON
    };
    sandbox.window = sandbox;
    return sandbox;
}

function loadScript(sandbox, filePath) {
    const code = fs.readFileSync(filePath, "utf8");
    vm.runInContext(code, sandbox, { filename: filePath });
}

function buildResponse(reqId, method, sessionId, ok, payload, error, done) {
    return JSON.stringify({
        id: "resp_" + Math.random().toString(36).slice(2),
        sessionId,
        kind: "response",
        method,
        ts: Date.now(),
        timeoutMs: 0,
        keep: false,
        payload: payload == null ? null : payload,
        reqId,
        done,
        ok,
        error: error == null ? null : error
    });
}

function buildEvent(method, sessionId, payload) {
    return JSON.stringify({
        id: "evt_" + Math.random().toString(36).slice(2),
        sessionId,
        kind: "event",
        method,
        ts: Date.now(),
        timeoutMs: 0,
        keep: false,
        payload,
        reqId: null,
        done: null,
        ok: null,
        error: null
    });
}

async function run() {
    const root = path.resolve(__dirname, "../../assets/web");
    const sdkPath = path.join(root, "jsbridge-sdk.js");

    const sandbox = vm.createContext(createSandbox());
    loadScript(sandbox, sdkPath);

    const sdk = sandbox.JsBridgeSDK;
    const CoreBridgeClient = sdk.CoreBridgeClient;
    const BridgeProtocol = sdk.BridgeProtocol;
    assert.ok(CoreBridgeClient, "CoreBridgeClient should be loaded");

    {
        const sent = [];
        const transport = { send: message => sent.push(message) };
        const client = new CoreBridgeClient(transport, "s-timeout");
        let failError = null;
        let successCount = 0;

        client.callNativeApi("echo", {
            timeoutMs: 20,
            success: () => {
                successCount += 1;
            },
            fail: err => {
                failError = err;
            }
        });

        await sleep(50);
        assert.strictEqual(sent.length, 1, "C14 request should be sent once");
        assert.ok(failError, "C14 should trigger fail callback");
        assert.strictEqual(failError.code, BridgeProtocol.ERR_TIMEOUT, "C14 should return timeout code");
        assert.strictEqual(successCount, 0, "C14 should not call success callback");
    }

    {
        const sent = [];
        const transport = { send: message => sent.push(message) };
        const client = new CoreBridgeClient(transport, "s-late");
        let failCount = 0;
        let successCount = 0;

        client.callNativeApi("echo", {
            timeoutMs: 20,
            success: () => {
                successCount += 1;
            },
            fail: () => {
                failCount += 1;
            }
        });

        const request = JSON.parse(sent[0]);
        await sleep(50);
        assert.strictEqual(failCount, 1, "C15 should fail once at timeout");
        assert.strictEqual(successCount, 0, "C15 should not succeed before timeout");

        const lateResponse = buildResponse(request.id, "echo", "s-late", true, { ok: 1 }, null, true);
        client.handleIncomingMessage(lateResponse);
        await sleep(10);

        assert.strictEqual(failCount, 1, "C15 should not fail twice");
        assert.strictEqual(successCount, 0, "C15 should ignore late success response");
    }

    {
        const transport = { send: () => {} };
        const client = new CoreBridgeClient(transport, "s1");
        let eventCount = 0;
        client.registerEventHandler(BridgeProtocol.METHOD_LIFECYCLE_STATE, () => {
            eventCount += 1;
        });

        const mismatch = buildEvent(BridgeProtocol.METHOD_LIFECYCLE_STATE, "s2", { state: "resumed" });
        client.handleIncomingMessage(mismatch);
        assert.strictEqual(eventCount, 0, "C16 should ignore event with mismatched session");

        const matched = buildEvent(BridgeProtocol.METHOD_LIFECYCLE_STATE, "s1", { state: "resumed" });
        client.handleIncomingMessage(matched);
        assert.strictEqual(eventCount, 1, "C16 sanity check: matched session should dispatch event");
    }

    // C31: handshake-gate deny response routing
    {
        const sent = [];
        const transport = { send: msg => sent.push(msg) };
        const client = new CoreBridgeClient(transport, "s-c31");
        let failError = null;
        let failCount = 0;

        client.callNativeApi("getUser", {
            success: () => {},
            fail: err => { failError = err; failCount++; }
        });

        const req = JSON.parse(sent[0]);
        const denyResp = buildResponse(
            req.id, "getUser", "s-c31", false, null,
            { code: BridgeProtocol.ERR_POLICY_DENY, message: "bridge handshake required", retryable: false },
            true
        );
        client.handleIncomingMessage(denyResp);

        assert.strictEqual(failCount, 1, "C31 fail callback should be triggered once");
        assert.ok(failError, "C31 error object should be present");
        assert.strictEqual(failError.code, BridgeProtocol.ERR_POLICY_DENY, "C31 error code should match deny");
    }

    // C32: keep+streaming - multiple done:false + final done:true
    {
        const sent = [];
        const transport = { send: msg => sent.push(msg) };
        const client = new CoreBridgeClient(transport, "s-c32");
        const successPayloads = [];

        client.callNativeApi("timerLog", {
            keep: true,
            timeoutMs: 10000,
            success: res => successPayloads.push(res),
            fail: () => {}
        });

        const req = JSON.parse(sent[0]);
        assert.strictEqual(req.keep, true, "C32 request should have keep:true");

        for (let i = 0; i < 2; i++) {
            const frame = buildResponse(req.id, "timerLog", "s-c32", true, { tick: i }, null, false);
            client.handleIncomingMessage(frame);
        }
        assert.strictEqual(successPayloads.length, 2, "C32 success should be called for each done:false frame");

        const finalFrame = buildResponse(req.id, "timerLog", "s-c32", true, { done: true }, null, true);
        client.handleIncomingMessage(finalFrame);
        assert.strictEqual(successPayloads.length, 3, "C32 success should be called for done:true frame");

        const lateFrame = buildResponse(req.id, "timerLog", "s-c32", true, { late: true }, null, true);
        client.handleIncomingMessage(lateFrame);
        assert.strictEqual(successPayloads.length, 3, "C32 late response after done:true should be ignored");
    }

    // C19: lifecycle seq 过滤 (out-of-order seq dropped)
    {
        const sandbox19 = vm.createContext(createSandbox());
        loadScript(sandbox19, sdkPath);

        const transport = { send: () => {} };
        const client = new sandbox19.JsBridgeSDK.CoreBridgeClient(transport, "s-c19");
        const lb = sandbox19.JsBridgeSDK.createLifecycleBridge(client, {
            lifecycleMethod: sandbox19.JsBridgeSDK.BridgeProtocol.METHOD_LIFECYCLE_STATE
        });
        const received = [];
        lb.on(payload => received.push(payload.seq));

        for (const seq of [1, 3, 2, 4]) {
            const evt = buildEvent(sandbox19.JsBridgeSDK.BridgeProtocol.METHOD_LIFECYCLE_STATE, "s-c19", { state: "active", seq });
            client.handleIncomingMessage(evt);
        }

        assert.deepStrictEqual(received, [1, 3, 4], "C19 seq=2 should be filtered (out of order)");
        assert.strictEqual(lb.getState(), "active", "C19 currentState should be set");
    }

    // C20: policy-deny error shape (code + message + retryable all present)
    {
        const sent = [];
        const transport = { send: msg => sent.push(msg) };
        const client = new CoreBridgeClient(transport, "s-c20");
        let failError = null;

        client.callNativeApi("badMethod", {
            success: () => {},
            fail: err => { failError = err; }
        });

        const req = JSON.parse(sent[0]);
        const denyShape = { code: "E_INVALID_MESSAGE", message: "missing required field", retryable: false, details: {} };
        const denyResp = buildResponse(req.id, "badMethod", "s-c20", false, null, denyShape, true);
        client.handleIncomingMessage(denyResp);

        assert.ok(failError, "C20 fail error should be set");
        assert.ok("code" in failError, "C20 error must have code");
        assert.ok("message" in failError, "C20 error must have message");
        assert.ok("retryable" in failError, "C20 error must have retryable");
        assert.strictEqual(failError.code, "E_INVALID_MESSAGE", "C20 error code should match");
    }

    // C21: settled-map TTL — entry cleared after 60s, late response reclassified
    {
        let nowOverride = null;
        const realDate = Date;
        const capturedLogs = [];

        const sandbox21 = vm.createContext({
            console: { log: (...args) => capturedLogs.push(args.map(String).join(" ")), warn: () => {}, error: () => {} },
            setTimeout,
            clearTimeout,
            Date: { now: () => nowOverride !== null ? nowOverride : realDate.now() },
            Math,
            Map,
            JSON
        });
        sandbox21.window = sandbox21;
        loadScript(sandbox21, sdkPath);

        const sent = [];
        const transport = { send: msg => sent.push(msg) };
        const client = new sandbox21.JsBridgeSDK.CoreBridgeClient(transport, "s-c21");
        let failCount = 0;
        client.callNativeApi("echo", { timeoutMs: 20, fail: () => failCount++ });

        const req = JSON.parse(sent[0]);
        await sleep(50);
        assert.strictEqual(failCount, 1, "C21 should have timed out");

        const lateResp = buildResponse(req.id, "echo", "s-c21", true, { ok: 1 }, null, true);
        capturedLogs.length = 0;
        client.handleIncomingMessage(lateResp);
        assert.ok(
            capturedLogs.some(l => l.includes("late response dropped")),
            "C21 within TTL: settled entry blocks late response"
        );

        nowOverride = realDate.now() + 70000;
        client.callNativeApi("dummy", { timeoutMs: 5000, success: () => {} });
        nowOverride = null;

        capturedLogs.length = 0;
        client.handleIncomingMessage(lateResp);
        assert.ok(
            capturedLogs.some(l => l.includes("pending callback not found")),
            "C21 after TTL: settled entry cleared, response reclassified to pending-not-found"
        );
    }

    // C22: event sessionId strict matching (including empty string compatibility)
    {
        const transport = { send: () => {} };
        const client = new CoreBridgeClient(transport, "s1-c22");
        let eventCount = 0;
        client.registerEventHandler("runtime.state", () => { eventCount++; });

        const wrongSession = buildEvent("runtime.state", "s2-wrong", { state: "resumed" });
        client.handleIncomingMessage(wrongSession);
        assert.strictEqual(eventCount, 0, "C22 event with wrong sessionId should be ignored");

        const rightSession = buildEvent("runtime.state", "s1-c22", { state: "resumed" });
        client.handleIncomingMessage(rightSession);
        assert.strictEqual(eventCount, 1, "C22 event with matching sessionId should be dispatched");

        const emptySession = buildEvent("runtime.state", "", { state: "paused" });
        client.handleIncomingMessage(emptySession);
        assert.strictEqual(eventCount, 2, "C22 event with empty sessionId should be dispatched (legacy compat)");
    }

    // C23: no-handshake bare dispatch (JS client does not enforce handshake)
    {
        const sent = [];
        const transport = { send: msg => sent.push(msg) };
        const client = new CoreBridgeClient(transport, '');

        let successPayload = null;
        let failError = null;

        client.callNativeApi('getUser', {
            success: res => { successPayload = res; },
            fail: err => { failError = err; }
        });

        assert.strictEqual(sent.length, 1, 'C23 request should be sent without handshake');
        const req = JSON.parse(sent[0]);
        assert.strictEqual(req.method, 'getUser', 'C23 request method should be getUser');

        const okResp = buildResponse(req.id, 'getUser', '', true, { name: 'test' }, null, true);
        client.handleIncomingMessage(okResp);
        assert.deepStrictEqual(successPayload, { name: 'test' }, 'C23 success should be called with payload');
        assert.strictEqual(failError, null, 'C23 fail should not be called on success response');

        const sent2 = [];
        const transport2 = { send: msg => sent2.push(msg) };
        const client2 = new CoreBridgeClient(transport2, '');
        let failError2 = null;
        client2.callNativeApi('getUser', {
            success: () => {},
            fail: err => { failError2 = err; }
        });
        const req2 = JSON.parse(sent2[0]);
        const failResp = buildResponse(req2.id, 'getUser', '', false, null,
            { code: 'E_NOT_FOUND', message: 'user not found', retryable: false }, true);
        client2.handleIncomingMessage(failResp);
        assert.ok(failError2, 'C23 fail callback should be called on error response');
        assert.strictEqual(failError2.code, 'E_NOT_FOUND', 'C23 fail error code should match');
    }

    // C24: AbortSignal cancels pending request
    {
        const sent = [];
        const transport = { send: message => sent.push(message) };
        const client = new CoreBridgeClient(transport, "s-c24");
        const controller = new AbortController();
        let failError = null;
        let successCount = 0;

        client.callNativeApi("echo", {
            signal: controller.signal,
            timeoutMs: 10000,
            success: () => { successCount += 1; },
            fail: err => { failError = err; }
        });

        assert.strictEqual(sent.length, 1, "C24 request should be sent");
        assert.strictEqual(successCount, 0, "C24 no success before abort");

        controller.abort();

        assert.ok(failError, "C24 abort should trigger fail callback");
        assert.strictEqual(failError.code, BridgeProtocol.ERR_CANCELED, "C24 error code should be E_CANCELED");
        assert.strictEqual(successCount, 0, "C24 no success after abort");

        // Late response should be ignored (pending entry removed)
        const req = JSON.parse(sent[0]);
        const lateResp = buildResponse(req.id, "echo", "s-c24", true, { ok: 1 }, null, true);
        client.handleIncomingMessage(lateResp);
        assert.strictEqual(successCount, 0, "C24 late response after abort should be ignored");
    }

    // C25: AbortSignal cancels streaming (keep=true) request
    {
        const sent = [];
        const transport = { send: message => sent.push(message) };
        const client = new CoreBridgeClient(transport, "s-c25");
        const controller = new AbortController();
        const successPayloads = [];
        let failError = null;

        client.callNativeApi("timerLog", {
            keep: true,
            signal: controller.signal,
            timeoutMs: 10000,
            success: res => successPayloads.push(res),
            fail: err => { failError = err; }
        });

        const req = JSON.parse(sent[0]);
        for (let i = 0; i < 2; i++) {
            const frame = buildResponse(req.id, "timerLog", "s-c25", true, { tick: i }, null, false);
            client.handleIncomingMessage(frame);
        }
        assert.strictEqual(successPayloads.length, 2, "C25 streaming frames should arrive before abort");

        controller.abort();
        assert.ok(failError, "C25 abort should trigger fail callback");
        assert.strictEqual(failError.code, BridgeProtocol.ERR_CANCELED, "C25 error code should be E_CANCELED");

        const lateFrame = buildResponse(req.id, "timerLog", "s-c25", true, { tick: 99 }, null, false);
        client.handleIncomingMessage(lateFrame);
        assert.strictEqual(successPayloads.length, 2, "C25 late frame after abort should be ignored");
    }

    // C26: AbortSignal unregisters event handler
    {
        const transport = { send: () => {} };
        const client = new CoreBridgeClient(transport, "s-c26");
        const controller = new AbortController();
        let eventCount = 0;

        client.registerEventHandler("biz.event", () => {
            eventCount += 1;
        }, controller.signal);

        const event1 = buildEvent("biz.event", "s-c26", { data: 1 });
        client.handleIncomingMessage(event1);
        assert.strictEqual(eventCount, 1, "C26 event should arrive before abort");

        controller.abort();

        const event2 = buildEvent("biz.event", "s-c26", { data: 2 });
        client.handleIncomingMessage(event2);
        assert.strictEqual(eventCount, 1, "C26 event after abort should be ignored (handler unregistered)");
    }

    // C27: Pre-aborted signal rejects immediately without sending
    {
        const sent = [];
        const transport = { send: message => sent.push(message) };
        const client = new CoreBridgeClient(transport, "s-c27");
        const controller = new AbortController();
        controller.abort();

        let failError = null;
        let successCount = 0;

        client.callNativeApi("echo", {
            signal: controller.signal,
            timeoutMs: 10000,
            success: () => { successCount += 1; },
            fail: err => { failError = err; }
        });

        assert.strictEqual(sent.length, 0, "C27 pre-aborted: no request should be sent");
        assert.ok(failError, "C27 pre-aborted: fail callback should be called");
        assert.strictEqual(failError.code, BridgeProtocol.ERR_CANCELED, "C27 pre-aborted: error code should be E_CANCELED");
        assert.strictEqual(successCount, 0, "C27 pre-aborted: no success callback");
    }

    // C39: timeoutMs<=0 disables client timeout (protocol v1: 0 = no timeout)
    {
        const sent = [];
        const transport = { send: msg => sent.push(msg) };
        const client = new CoreBridgeClient(transport, "s-c39");
        let failCount = 0;
        let successPayload = null;

        client.callNativeApi("echo", {
            timeoutMs: 0,
            success: res => { successPayload = res; },
            fail: () => { failCount += 1; }
        });

        assert.strictEqual(sent.length, 1, "C39 request should be sent once");
        const req = JSON.parse(sent[0]);

        await sleep(50);
        assert.strictEqual(failCount, 0, "C39 timeoutMs=0 should not trigger fail callback (no timeout)");

        const resp = buildResponse(req.id, "echo", "s-c39", true, { ok: 1 }, null, true);
        client.handleIncomingMessage(resp);
        assert.deepStrictEqual(successPayload, { ok: 1 }, "C39 success should still be delivered for a pending request");
        assert.strictEqual(failCount, 0, "C39 no fail callback expected");
    }


    // C40/C41: transport 层信道建立（pull 模型，v1 裁决 docs/06 / docs/09 C40-C41）
    {
        const eventListeners = { message: [], pageshow: [] };
        sandbox.addEventListener = (type, fn) => { (eventListeners[type] = eventListeners[type] || []).push(fn); };
        // MessageEvent 必须在 sandbox realm 内构造：真实浏览器中事件由页面 realm 创建、
        // source 即页面 window；vm 跨 realm 传入的 window 引用在 realm 内判等恒为 false。
        // sourceOverride !== undefined 模拟跨域 iframe 构造的同形事件（C59 代码侧）。
        sandbox.__makeChannelEvent = vm.runInContext(
            "(function (reqId, port, sourceOverride) {" +
            "  var ev = { data: JSON.stringify({ type: 'bridge:channel', reqId: reqId }), ports: [port] };" +
            "  ev.source = sourceOverride === undefined ? window : sourceOverride;" +
            "  return ev;" +
            "})",
            sandbox
        );
        const channelRequests = [];
        sandbox.__jsbridge2__ = {
            requestBridgeChannel: optsJson => {
                const o = JSON.parse(optsJson);
                channelRequests.push(o.reqId);
                return JSON.stringify({ ok: true, reqId: o.reqId });
            }
        };
        const channelErrors = [];
        const fast = { channelTimeoutMs: 30, maxChannelRetries: 99, retryBackoffMs: 10 };
        const transport = sdk.createNativeTransport(fast);
        transport.onChannelError(e => channelErrors.push(e));
        const deliveredPorts = [];
        const deliver = (reqId, forgedSource) => {
            const port = {
                closed: false, onmessage: null, sent: [],
                postMessage(m) { port.sent.push(m); },
                close() { port.closed = true; }
            };
            deliveredPorts.push(port);
            // 缺省 source = sandbox realm 的 window（与真实 Native 投递一致）；
            // 传入 forgedSource 模拟跨域 iframe 构造的伪造事件（C59 代码侧）
            const ev = sandbox.__makeChannelEvent(reqId, port, forgedSource);
            for (const fn of eventListeners.message) { fn(ev); }
            return port;
        };

        assert.strictEqual(channelRequests.length, 1, "C40 pull request should be sent on construction (causal order)");
        const firstReqId = channelRequests[0];
        assert.ok(typeof firstReqId === "string" && firstReqId.length > 0, "C40 request must carry reqId");

        // C59 代码侧（并入 C40/C41，不新编号）：reqId 泄露给恶意 iframe 后，其构造的
        // 同形投递（source !== window）必须被拒：端口关闭、不采纳、reqId 路径不受劫持
        //（docs/06 §2.2 投递信任边界——reqId 只作配对凭证，不作信任凭证）
        const forged = deliver(firstReqId, { fakeIframeWindow: true });
        assert.strictEqual(forged.closed, true, "C59 forged-source delivery must be rejected and port closed");

        const noReqId = deliver("");
        assert.strictEqual(noReqId.closed, true, "C40 delivery without reqId must be dropped and port closed");

        const adopted = deliver(firstReqId);
        assert.notStrictEqual(adopted.closed, true, "C40 matching reqId delivery must be adopted");

        const duplicate = deliver(firstReqId);
        assert.strictEqual(duplicate.closed, true, "C40 duplicate reqId delivery must be idempotently ignored and closed");

        let received = [];
        transport.onMessage(m => received.push(m));
        transport.send('{"c40":1}');
        await sleep(80);
        assert.ok(adopted.sent.indexOf('{"c40":1}') !== -1, "C40 messages must flow through adopted port");

        const guard = sdk.createNativeTransport(fast);
        assert.strictEqual(guard, transport, "C40 second createNativeTransport must reuse (singleton guard, docs/06 §5.1)");

        const stale = deliver("r-999-stale");
        assert.strictEqual(stale.closed, true, "C41 stale reqId delivery must be dropped and port closed");
        assert.notStrictEqual(adopted.closed, true, "C41 current port must survive stale delivery");

        // C41: retry with a new reqId — late delivery of the previous request must be rejected
        for (const fn of eventListeners.pageshow) { fn({ persisted: true }); }
        for (let i = 0; i < 200 && channelRequests.length < 2; i++) { await sleep(10); }
        assert.notStrictEqual(channelRequests[0], channelRequests[1], "C41 retry must rotate reqId");
        const late = deliver(channelRequests[0]);
        assert.strictEqual(late.closed, true, "C41 late delivery of rotated-out reqId must be dropped and closed");
        const fresh = deliver(channelRequests[channelRequests.length - 1]);
        assert.notStrictEqual(fresh.closed, true, "C41 delivery matching latest reqId must be adopted");
        assert.strictEqual(adopted.closed, true, "C41 rotation must close the old port synchronously");

        // C41: channel failure (entry missing) → E_CHANNEL_CLOSED with retryable=true
        const eventListeners2 = { message: [], pageshow: [] };
        const sandbox2raw = Object.assign(createSandbox(), {
            addEventListener: (type, fn) => { (eventListeners2[type] = eventListeners2[type] || []).push(fn); }
        });
        sandbox2raw.window = sandbox2raw;
        const sandbox2 = vm.createContext(sandbox2raw);
        loadScript(sandbox2, sdkPath);
        const errors2 = [];
        const t2 = sandbox2.JsBridgeSDK.createNativeTransport({ channelTimeoutMs: 10, maxChannelRetries: 2, retryBackoffMs: 5 });
        t2.onChannelError(e => errors2.push(e));
        await sleep(200);
        assert.strictEqual(errors2.length, 1, "C41 missing entry must fail channel once after retries");
        assert.strictEqual(errors2[0].code, "E_CHANNEL_CLOSED", "C41 channel failure code must be E_CHANNEL_CLOSED");
        assert.strictEqual(errors2[0].retryable, true, "C41 E_CHANNEL_CLOSED must be retryable");

        // C40/C41 附加（transport 监听器只增不减修复的验收，并入现有用例不新编号）：
        // 装载器失败重试（getBridge 落空后 readyPromise 清空重跑）会经 registerWebEntry
        // 对同一 shared transport 重复注册——重复注册必须幂等，不得累积 stale 分发
        {
            const mkStub = () => ({
                received: [],
                handleIncomingMessage(m) { this.received.push(m); },
                failAllPending() {}
            });
            const stubA = mkStub();
            const stubB = mkStub();
            sdk.registerWebEntry(stubA, transport);
            sandbox.__jsbridge2__.receive('{"stub":"a1"}');
            assert.strictEqual(stubA.received.length, 1, "web-entry wiring must dispatch incoming messages");
            sdk.registerWebEntry(stubB, transport);
            sandbox.__jsbridge2__.receive('{"stub":"b1"}');
            assert.strictEqual(stubB.received.length, 1, "re-registered web-entry must dispatch to the new client");
            assert.strictEqual(stubA.received.length, 1, "re-registered web-entry must not accumulate stale listeners (no duplicate dispatch)");
        }

        // C41 附加（legacy-only 宿主，并入现有用例不新编号）：仅 __jsbridge2__.callNativeApi
        // 的老宿主既无 MessagePort 也无常驻通道——send 必须立即经 onChannelError 以
        // E_CHANNEL_CLOSED 快速失败（message 注明 legacy host），且不得 50ms 无限轮询续期
        {
            const eventListeners3 = { message: [], pageshow: [] };
            const sandbox3raw = Object.assign(createSandbox(), {
                addEventListener: (type, fn) => { (eventListeners3[type] = eventListeners3[type] || []).push(fn); }
            });
            sandbox3raw.window = sandbox3raw;
            const sandbox3 = vm.createContext(sandbox3raw);
            loadScript(sandbox3, sdkPath);
            sandbox3.__jsbridge2__ = { callNativeApi: () => {} };
            const errors3 = [];
            const legacyTransport = sandbox3.JsBridgeSDK.createNativeTransport({ channelTimeoutMs: 50, maxChannelRetries: 2, retryBackoffMs: 10 });
            legacyTransport.onChannelError(e => errors3.push(e));
            legacyTransport.send('{"legacy":1}');
            assert.strictEqual(errors3.length, 1, "legacy-only host: send must fast-fail via onChannelError");
            assert.strictEqual(errors3[0].code, "E_CHANNEL_CLOSED", "legacy-only host: fail code must be E_CHANNEL_CLOSED");
            assert.notStrictEqual(errors3[0].message.toLowerCase().indexOf("legacy"), -1, "legacy-only host: error message must note legacy host");
            await sleep(150);
            assert.strictEqual(errors3.length, 1, "legacy-only host: flush polling must stop (exactly one channel error, no repeated emission)");
        }
    }

    {
        // C50: reqId 可关联但 kind 未知的响应 → 立即快速失败（E_INTERNAL），
        // 而非放任挂起请求等待超时（E_TIMEOUT 伪装归因）；无关联请求不受影响。
        const sent = [];
        const transport = { send: message => sent.push(message) };
        const client = new CoreBridgeClient(transport, "s-c50");
        let failError = null;
        let failCount = 0;
        let successCount = 0;

        client.callNativeApi("getUser", {
            timeoutMs: 100,
            success: () => {
                successCount += 1;
            },
            fail: err => {
                failCount += 1;
                failError = err;
            }
        });
        assert.strictEqual(sent.length, 1, "C50 pending request should be sent");
        const request = JSON.parse(sent[0]);

        const undeliverable = {
            id: "resp-c50",
            sessionId: "s-c50",
            kind: "not-a-valid-kind",
            method: "getUser",
            ts: Date.now(),
            timeoutMs: 0,
            keep: false,
            payload: null,
            reqId: request.id,
            done: true,
            ok: true,
            error: null
        };
        client.handleIncomingMessage(JSON.stringify(undeliverable));
        assert.ok(failError, "C50 unknown-kind response must fail the associated request synchronously");
        assert.strictEqual(failError.code, BridgeProtocol.ERR_INTERNAL, "C50 fail code must be E_INTERNAL, not E_TIMEOUT");
        assert.strictEqual(failCount, 1, "C50 associated request must fail exactly once");
        assert.strictEqual(successCount, 0, "C50 must not invoke success callback");

        const stray = Object.assign({}, undeliverable, { id: "resp-c50-stray", reqId: "req-c50-stray" });
        client.handleIncomingMessage(JSON.stringify(stray));
        assert.strictEqual(failCount, 1, "C50 stray undeliverable message must not fail unrelated requests");

        await sleep(150);
        assert.strictEqual(failCount, 1, "C50 no second failure after timeout window (pending already settled)");
    }

    {
        // C63: 响应帧落定收口（docs/03 §4.3 流式契约 / 对齐 C50 fail-fast 精神）：
        // (a) 流中失败帧（ok=false 且 done=false）属协议违例形态——SDK 必须按终帧行为
        //     落定：fail 至多触发一次，流不得因其续存（后续同 reqId 帧按迟到帧丢弃，
        //     不得二次失败、不得再补 E_TIMEOUT）；
        // (b) reqId 匹配但 sessionId 错配的响应 → 立即以 E_SESSION_INVALID 快速失败
        //     并落定，而非静默丢弃把跨会话串扰伪装成 E_TIMEOUT。
        const sent = [];
        const transport = { send: message => sent.push(message) };
        const client = new CoreBridgeClient(transport, "s-c63");
        let failCount = 0;
        let successCount = 0;
        let lastFail = null;

        client.callNativeApi("streamWork", {
            keep: true,
            timeoutMs: 120,
            success: () => { successCount += 1; },
            fail: err => { failCount += 1; lastFail = err; }
        });
        const request = JSON.parse(sent[0]);
        const frame = (id, over) => Object.assign({
            id: id,
            sessionId: "s-c63",
            kind: "response",
            method: "streamWork",
            ts: Date.now(),
            timeoutMs: 0,
            keep: true,
            payload: null,
            reqId: request.id,
            done: true,
            ok: true,
            error: null
        }, over);

        // (a) 流中失败帧：终结流，fail 恰好一次
        client.handleIncomingMessage(JSON.stringify(frame("f1", {
            done: false,
            ok: false,
            error: { code: "E_INTERNAL", message: "midstream boom" }
        })));
        assert.strictEqual(failCount, 1, "C63 midstream failure frame must invoke fail exactly once");
        assert.strictEqual(lastFail.code, "E_INTERNAL", "C63 midstream failure must surface the handler error code");

        // 流已落定：后续同 reqId 帧为迟到帧——不再触发任何回调
        client.handleIncomingMessage(JSON.stringify(frame("f2", { done: false, ok: true, payload: { tick: 1 } })));
        client.handleIncomingMessage(JSON.stringify(frame("f3", { done: true, ok: true, payload: { tick: 2 } })));
        assert.strictEqual(failCount, 1, "C63 settled stream must not fail again on late frames");
        assert.strictEqual(successCount, 0, "C63 settled stream must not invoke success on late frames");

        // (b) 会话错配：fail-fast E_SESSION_INVALID，而非静默丢弃
        let fail2Count = 0;
        let fail2 = null;
        client.callNativeApi("getUser", {
            timeoutMs: 100,
            success: () => {},
            fail: err => { fail2Count += 1; fail2 = err; }
        });
        const request2 = JSON.parse(sent[1]);
        const frame2 = (over) => Object.assign({
            id: "resp-c63-2",
            sessionId: "s-c63",
            kind: "response",
            method: "getUser",
            ts: Date.now(),
            timeoutMs: 0,
            keep: false,
            payload: { x: 1 },
            reqId: request2.id,
            done: true,
            ok: true,
            error: null
        }, over);
        client.handleIncomingMessage(JSON.stringify(frame2({ sessionId: "other-session" })));
        assert.strictEqual(fail2Count, 1, "C63 session-mismatch response must fail-fast synchronously");
        assert.strictEqual(fail2.code, "E_SESSION_INVALID", "C63 mismatch must surface E_SESSION_INVALID, not E_TIMEOUT");

        await sleep(160);
        assert.strictEqual(fail2Count, 1, "C63 session-mismatch settled: no timeout follow-up failure");
        assert.strictEqual(failCount, 1, "C63 stream request stays settled through the whole case");
    }

    {
        // C57: 用户回调抛异常不破坏落定状态——落定路径的清理先于/独立于用户回调执行
        //（docs/09 §3 C57）。变体断言（并入 C57，不新编号）：
        // ② payload 序列化失败（循环引用）→ 本地 fail E_INTERNAL 且零残留；
        // ③ transport.send 抛异常 → 完整清理 + fail E_INTERNAL，无僵尸定时器。
        const capturedErrors = [];
        const originalError = sandbox.console.error;
        sandbox.console.error = (...args) => {
            capturedErrors.push(args.map(a => String(a)).join(" "));
        };

        const sent = [];
        const transport = { send: message => sent.push(message) };
        const client = new CoreBridgeClient(transport, "s-c57");
        let successCount = 0;
        let failCount = 0;

        client.callNativeApi("getUser", {
            timeoutMs: 40,
            success: () => {
                successCount += 1;
                throw new Error("c57-boom");
            },
            fail: () => {
                failCount += 1;
            }
        });
        assert.strictEqual(sent.length, 1, "C57 pending request should be sent");
        const request = JSON.parse(sent[0]);

        const okResp = buildResponse(request.id, "getUser", "s-c57", true, { name: "test" }, null, true);
        client.handleIncomingMessage(okResp);
        assert.strictEqual(successCount, 1, "C57 success callback should be invoked exactly once");
        assert.ok(
            capturedErrors.some(l => l.indexOf("c57-boom") !== -1),
            "C57 callback exception must be caught by SDK (console.error), not propagate to transport caller"
        );
        assert.strictEqual(failCount, 0, "C57 success-path exception must not trigger fail");

        const lateResp = buildResponse(request.id, "getUser", "s-c57", true, { late: true }, null, true);
        client.handleIncomingMessage(lateResp);
        assert.strictEqual(successCount, 1, "C57 late same-reqId response must be dropped (pending settled before callback)");
        assert.strictEqual(failCount, 0, "C57 late response must not invoke fail");

        await sleep(80);
        assert.strictEqual(failCount, 0, "C57 timer must be cleared on settle: no fail when timeout window expires");

        sandbox.console.error = originalError;

        // C57 变体 ②：序列化失败 → 本地 fail E_INTERNAL、零残留（未发消息、未挂定时器）
        {
            const sent2 = [];
            const transport2 = { send: message => sent2.push(message) };
            const client2 = new CoreBridgeClient(transport2, "s-c57b");
            let failCount2 = 0;
            let failError2 = null;
            const cyclic = {};
            cyclic.self = cyclic;
            client2.callNativeApi("echo", {
                timeoutMs: 40,
                blob: cyclic,
                success: () => {},
                fail: err => {
                    failCount2 += 1;
                    failError2 = err;
                }
            });
            assert.strictEqual(sent2.length, 0, "C57 serialize failure: nothing should reach transport");
            assert.strictEqual(failCount2, 1, "C57 serialize failure must fail locally exactly once");
            assert.strictEqual(failError2.code, BridgeProtocol.ERR_INTERNAL, "C57 serialize failure code must be E_INTERNAL");
            await sleep(80);
            assert.strictEqual(failCount2, 1, "C57 serialize failure leaves no armed timer (no zombie pending)");
        }

        // C57 变体 ③：transport.send 抛异常 → 完整清理 + fail E_INTERNAL，定时器零残留
        {
            const transport3 = { send: () => { throw new Error("send-boom"); } };
            const client3 = new CoreBridgeClient(transport3, "s-c57c");
            let failCount3 = 0;
            let failError3 = null;
            client3.callNativeApi("echo", {
                timeoutMs: 40,
                success: () => {},
                fail: err => {
                    failCount3 += 1;
                    failError3 = err;
                }
            });
            assert.strictEqual(failCount3, 1, "C57 send failure must fail locally exactly once");
            assert.strictEqual(failError3.code, BridgeProtocol.ERR_INTERNAL, "C57 send failure code must be E_INTERNAL");
            await sleep(80);
            assert.strictEqual(failCount3, 1, "C57 send failure: zombie timer must not fire a second fail");
        }
    }

    console.log('CoreBridgeClient conformance cases passed: C14, C15, C16, C19, C20, C21, C22, C23, C24, C25, C26, C27, C31, C32, C39, C40, C41, C50, C57, C63');
}

run().catch(error => {
    console.error(error);
    process.exit(1);
});
