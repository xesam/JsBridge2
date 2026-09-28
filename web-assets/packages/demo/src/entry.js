(function(global) {
    const { CoreBridgeClient, BridgeProtocol, createNativeTransport,
            createJsBridgeClient, createReadyExtension, createLifecycleBridge,
            registerWebEntry } = window.JsBridgeSDK
    const readyStateNode = document.getElementById('readyState')
    const sessionStateNode = document.getElementById('sessionState')
    const transport = createNativeTransport()
    const coreBridgeClient = new CoreBridgeClient(transport)
    const jsBridgeClient = createJsBridgeClient(coreBridgeClient, {
        readyMethod: BridgeProtocol.METHOD_HANDSHAKE
    })
    const lifecycleBridge = createLifecycleBridge(coreBridgeClient, {
        lifecycleMethod: BridgeProtocol.METHOD_LIFECYCLE_STATE
    })
    const readyExtension = createReadyExtension(jsBridgeClient, {
        readyMethod: BridgeProtocol.METHOD_HANDSHAKE
    })

    registerWebEntry(coreBridgeClient, transport)
    global.bridgeLifecycle = lifecycleBridge

    const bizApi = createBizApi(jsBridgeClient)
    const demoPage = bindDemoPage(bizApi)
    bindLifecycleDisplay(lifecycleBridge)

    readyExtension.bootstrapReady({
        onSuccess(res) {
            readyStateNode.innerText = 'ready: true'
            sessionStateNode.innerText = `session: ${jsBridgeClient.getSessionId() || '-'}`
            demoPage.setActionsEnabled(true)
        },
        onFail(error) {
            readyStateNode.innerText = 'ready: false'
            sessionStateNode.innerText = `session: - (${error && error.code ? error.code : 'unknown'})`
            demoPage.setActionsEnabled(false)
        }
    })
})(window)
