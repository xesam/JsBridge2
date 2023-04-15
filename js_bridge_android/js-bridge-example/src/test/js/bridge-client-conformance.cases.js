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
    const root = path.resolve(__dirname, "../../main/assets/web");
    const sdkPath = path.join(root, "jsbridge-sdk.js");

    const sandbox = vm.createContext(createSandbox());
    loadScript(sandbox, sdkPath);

    const sdk = sandbox.JsBridgeSDK;
    const BridgeClient = sdk.BridgeClient;
    const BridgeProtocol = sdk.BridgeProtocol;
    assert.ok(BridgeClient, "BridgeClient should be loaded");

    {
        const sent = [];
        const transport = { send: message => sent.push(message) };
        const client = new BridgeClient(transport, "s-timeout");
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
        const client = new BridgeClient(transport, "s-late");
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
        const client = new BridgeClient(transport, "s1");
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

    // C17: handshake-gate deny response routing
    {
        const sent = [];
        const transport = { send: msg => sent.push(msg) };
        const client = new BridgeClient(transport, "s-c17");
        let failError = null;
        let failCount = 0;

        client.callNativeApi("getUser", {
            success: () => {},
            fail: err => { failError = err; failCount++; }
        });

        const req = JSON.parse(sent[0]);
        const denyResp = buildResponse(
            req.id, "getUser", "s-c17", false, null,
            { code: "E_HANDSHAKE_REQUIRED", message: "handshake required", retryable: false },
            true
        );
        client.handleIncomingMessage(denyResp);

        assert.strictEqual(failCount, 1, "C17 fail callback should be triggered once");
        assert.ok(failError, "C17 error object should be present");
        assert.strictEqual(failError.code, "E_HANDSHAKE_REQUIRED", "C17 error code should match deny");
    }

    // C18: keep+streaming - multiple done:false + final done:true
    {
        const sent = [];
        const transport = { send: msg => sent.push(msg) };
        const client = new BridgeClient(transport, "s-c18");
        const successPayloads = [];

        client.callNativeApi("timerLog", {
            keep: true,
            timeoutMs: 10000,
            success: res => successPayloads.push(res),
            fail: () => {}
        });

        const req = JSON.parse(sent[0]);
        assert.strictEqual(req.keep, true, "C18 request should have keep:true");

        for (let i = 0; i < 2; i++) {
            const frame = buildResponse(req.id, "timerLog", "s-c18", true, { tick: i }, null, false);
            client.handleIncomingMessage(frame);
        }
        assert.strictEqual(successPayloads.length, 2, "C18 success should be called for each done:false frame");

        const finalFrame = buildResponse(req.id, "timerLog", "s-c18", true, { done: true }, null, true);
        client.handleIncomingMessage(finalFrame);
        assert.strictEqual(successPayloads.length, 3, "C18 success should be called for done:true frame");

        const lateFrame = buildResponse(req.id, "timerLog", "s-c18", true, { late: true }, null, true);
        client.handleIncomingMessage(lateFrame);
        assert.strictEqual(successPayloads.length, 3, "C18 late response after done:true should be ignored");
    }

    // C19: lifecycle seq 过滤 (out-of-order seq dropped)
    {
        const sandbox19 = vm.createContext(createSandbox());
        loadScript(sandbox19, sdkPath);

        const transport = { send: () => {} };
        const client = new sandbox19.JsBridgeSDK.BridgeClient(transport, "s-c19");
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
        const client = new BridgeClient(transport, "s-c20");
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
        const client = new sandbox21.JsBridgeSDK.BridgeClient(transport, "s-c21");
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
        const client = new BridgeClient(transport, "s1-c22");
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
        const client = new BridgeClient(transport, '');

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
        const client2 = new BridgeClient(transport2, '');
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
        const client = new BridgeClient(transport, "s-c24");
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
        const client = new BridgeClient(transport, "s-c25");
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
        const client = new BridgeClient(transport, "s-c26");
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
        const client = new BridgeClient(transport, "s-c27");
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

    console.log('BridgeClient conformance cases passed: C14, C15, C16, C17, C18, C19, C20, C21, C22, C23, C24, C25, C26, C27');
}

run().catch(error => {
    console.error(error);
    process.exit(1);
});
