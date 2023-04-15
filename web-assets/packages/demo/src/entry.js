(function(global) {
    const { BridgeClient, BridgeProtocol, createNativeTransport,
            createSessionApi, createReadyExtension, createLifecycleBridge,
            registerWebEntry } = window.JsBridgeSDK
    const readyStateNode = document.getElementById('readyState')
    const sessionStateNode = document.getElementById('sessionState')
    const transport = createNativeTransport()
    const bridgeClient = new BridgeClient(transport)
    const sessionApi = createSessionApi(bridgeClient, {
        readyMethod: BridgeProtocol.METHOD_HANDSHAKE
    })
    const lifecycleBridge = createLifecycleBridge(bridgeClient, {
        lifecycleMethod: BridgeProtocol.METHOD_LIFECYCLE_STATE
    })
    const readyExtension = createReadyExtension(sessionApi, {
        readyMethod: BridgeProtocol.METHOD_HANDSHAKE
    })

    registerWebEntry(bridgeClient, transport)
    global.bridgeLifecycle = lifecycleBridge

    const bizApi = createBizApi(sessionApi)
    const demoPage = bindDemoPage(bizApi)
    bindLifecycleDisplay(lifecycleBridge)

    readyExtension.bootstrapReady({
        onSuccess(res) {
            readyStateNode.innerText = 'ready: true'
            sessionStateNode.innerText = `session: ${sessionApi.getSessionId() || '-'}`
            const capabilities = Array.isArray(res && res.capabilities) ? res.capabilities : []
            demoPage.setEnabledCapabilities(capabilities)
        },
        onFail(error) {
            readyStateNode.innerText = 'ready: false'
            sessionStateNode.innerText = `session: - (${error && error.code ? error.code : 'unknown'})`
            demoPage.setActionsEnabled(false)
        }
    })
})(window)
