(function(global) {
    function bindDemoPage(bizApi) {
        let timerRunning = false
        const resultNode = document.getElementById('lastResult')

        const writeResult = (title, value) => {
            const text = typeof value === 'string' ? value : JSON.stringify(value, null, 2)
            resultNode.innerText = `${title}\n${text}`
        }

        const setActionsEnabled = (enabled) => {
            for (const id of Object.keys(bizApi.ACTION_METHOD_MAP)) {
                const el = document.getElementById(id)
                if (!el) continue
                el.disabled = !enabled
                el.style.opacity = enabled ? '1' : '0.5'
            }
        }

        document.getElementById('showNativeLoading').addEventListener('click', () => {
            bizApi.showLoading('xesam', 'xesam@outlook.com', {
                success(res) { writeResult('showNativeLoading:success', res) },
                fail(err) { writeResult('showNativeLoading:fail', err) }
            })
        }, false)

        document.getElementById('getLocationCoarse').addEventListener('click', () => {
            bizApi.getCurrentLocation('coarse', 10000, {
                success(res) { writeResult('getLocationCoarse:success', res) },
                fail(err) { writeResult('getLocationCoarse:fail', err) }
            })
        }, false)

        document.getElementById('getLocationFine').addEventListener('click', () => {
            bizApi.getCurrentLocation('fine', 12000, {
                success(res) { writeResult('getLocationFine:success', res) },
                fail(err) { writeResult('getLocationFine:fail', err) }
            })
        }, false)

        document.getElementById('getUserSuccess').addEventListener('click', () => {
            bizApi.getUser('001', {
                success(res) { writeResult('getUserSuccess:success', res) },
                fail(err) { writeResult('getUserSuccess:fail', err) }
            })
        }, false)

        document.getElementById('getUserFail').addEventListener('click', () => {
            bizApi.getUser('002', {
                success(res) { writeResult('getUserFail:success', res) },
                fail(err) { writeResult('getUserFail:fail', err) }
            })
        }, false)

        document.getElementById('getUserBadSession').addEventListener('click', () => {
            bizApi.getUserWithSession('001', 'invalid-session-id', {
                success(res) { writeResult('getUserBadSession:success', res) },
                fail(err) { writeResult('getUserBadSession:fail', err) }
            })
        }, false)

        document.getElementById('pickImage').addEventListener('click', () => {
            bizApi.pickImage({
                success(res) { writeResult('pickImage:success', res) },
                fail(err) { writeResult('pickImage:fail', err) }
            })
        }, false)

        document.getElementById('pickInput').addEventListener('click', () => {
            bizApi.pickInput({
                success(res) { writeResult('pickInput:success', res) },
                fail(err) { writeResult('pickInput:fail', err) }
            })
        }, false)

        document.getElementById('timerStart').addEventListener('click', () => {
            if (timerRunning) { writeResult('timer:start', 'already running'); return }
            timerRunning = true
            const streamNode = document.getElementById('timerStreamLog')
            const streamLines = []
            if (streamNode) { streamNode.innerText = 'stream: running...' }
            bizApi.timerStart({
                success(res) {
                    if (res && res.event === 'stopped') {
                        timerRunning = false
                        writeResult('timer:stopped', res)
                        if (streamNode) { streamNode.innerText = streamLines.join('\n') + '\n→ stopped' }
                    } else {
                        const line = `tick #${res && res.seq} value=${res && res.value}`
                        streamLines.push(line)
                        if (streamNode) {
                            streamNode.innerText = streamLines.join('\n')
                            streamNode.scrollTop = streamNode.scrollHeight
                        }
                    }
                },
                fail(err) { writeResult('timer:fail', err); timerRunning = false }
            })
        }, false)

        document.getElementById('timerStop').addEventListener('click', () => {
            bizApi.timerStop({
                success(res) { writeResult('timer:stop:success', res); timerRunning = false },
                fail(err) { writeResult('timer:stop:fail', err); timerRunning = false }
            })
        }, false)

        document.getElementById('requestSuccess').addEventListener('click', () => {
            bizApi.request('https://httpbin.org/get?source=jsbridge', {
                success(res) { writeResult('request:success', res) },
                fail(err) { writeResult('request:fail', err) }
            })
        }, false)

        document.getElementById('requestFail').addEventListener('click', () => {
            bizApi.request('https://httpbin.org/status/500', {
                success(res) { writeResult('requestFailPath:success', res) },
                fail(err) { writeResult('requestFailPath:fail', err) }
            })
        }, false)

        document.getElementById('requestTimeout').addEventListener('click', () => {
            bizApi.requestWithTimeout('https://httpbin.org/delay/10', 3000, {
                success(res) { writeResult('requestTimeout:success', res) },
                fail(err) { writeResult('requestTimeout:fail', err) }
            })
        }, false)

        document.getElementById('callUnauthorized').addEventListener('click', () => {
            bizApi.callUnauthorized('admin.privileged', {
                success(res) { writeResult('callUnauthorized:success', res) },
                fail(err) { writeResult('callUnauthorized:fail', err) }
            })
        }, false)

        setActionsEnabled(false)
        return { setActionsEnabled }
    }

    function bindLifecycleDisplay(lifecycleBridge) {
        const stateElement = document.getElementById('lifecycleState')
        const logElement = document.getElementById('lifecycleLog')
        const logLines = []
        const handler = payload => {
            const seq = typeof payload.seq === 'number' ? payload.seq : 0
            if (stateElement) {
                stateElement.innerText = `lifecycle: ${payload.state} (#${seq})`
            }
            if (logElement) {
                const details = JSON.stringify(payload)
                logLines.push(`[${logLines.length + 1}] ${payload.state} (#${seq}) ${details}`)
                if (logLines.length > 20) {
                    logLines.shift()
                }
                logElement.innerText = logLines.join('\n')
                logElement.scrollTop = logElement.scrollHeight
            }
        }
        lifecycleBridge.on(handler)
        return { off: () => lifecycleBridge.off(handler) }
    }

    global.bindDemoPage = bindDemoPage
    global.bindLifecycleDisplay = bindLifecycleDisplay
})(window)
