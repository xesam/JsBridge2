(function(global) {
    function createBizApi(sessionApi) {
        const DEMO_METHOD = {
            SHOW_LOADING: 'showLoading',
            GET_USER: 'getUser',
            GET_CURRENT_LOCATION: 'getCurrentLocation',
            PICK_IMAGE: 'pickImage',
            PICK_INPUT: 'pickInput',
            TIMER_LOG: 'timerLog',
            REQUEST: 'request',
        }

        const ACTION_METHOD_MAP = {
            showNativeLoading: DEMO_METHOD.SHOW_LOADING,
            getLocationCoarse: DEMO_METHOD.GET_CURRENT_LOCATION,
            getLocationFine: DEMO_METHOD.GET_CURRENT_LOCATION,
            getUserSuccess: DEMO_METHOD.GET_USER,
            getUserFail: DEMO_METHOD.GET_USER,
            getUserBadSession: DEMO_METHOD.GET_USER,
            pickImage: DEMO_METHOD.PICK_IMAGE,
            pickInput: DEMO_METHOD.PICK_INPUT,
            timerStart: DEMO_METHOD.TIMER_LOG,
            timerStop: DEMO_METHOD.TIMER_LOG,
            requestSuccess: DEMO_METHOD.REQUEST,
            requestFail: DEMO_METHOD.REQUEST,
            requestTimeout: DEMO_METHOD.REQUEST,
            callUnauthorized: DEMO_METHOD.GET_USER,
        }

        function showLoading(title, content, opts) {
            sessionApi.callNativeApi(DEMO_METHOD.SHOW_LOADING, {
                title, content, success: opts.success, fail: opts.fail
            })
        }

        function getCurrentLocation(accuracy, timeoutMs, opts) {
            sessionApi.callNativeApi(DEMO_METHOD.GET_CURRENT_LOCATION, {
                accuracy, timeoutMs, success: opts.success, fail: opts.fail
            })
        }

        function getUser(userId, opts) {
            sessionApi.callNativeApi(DEMO_METHOD.GET_USER, {
                userId, success: opts.success, fail: opts.fail
            })
        }

        function getUserWithSession(userId, sessionId, opts) {
            sessionApi.callNativeApiWithSession(DEMO_METHOD.GET_USER, {
                userId, success: opts.success, fail: opts.fail
            }, sessionId)
        }

        function pickImage(opts) {
            sessionApi.callNativeApi(DEMO_METHOD.PICK_IMAGE, {
                type: 'image/*', success: opts.success, fail: opts.fail
            })
        }

        function pickInput(opts) {
            sessionApi.callNativeApi(DEMO_METHOD.PICK_INPUT, {
                success: opts.success, fail: opts.fail
            })
        }

        function timerStart(opts) {
            sessionApi.callNativeApi(DEMO_METHOD.TIMER_LOG, {
                action: 'start', keep: true, timeoutMs: 3600000,
                success: opts.success, fail: opts.fail
            })
        }

        function timerStop(opts) {
            sessionApi.callNativeApi(DEMO_METHOD.TIMER_LOG, {
                action: 'stop', success: opts.success, fail: opts.fail
            })
        }

        function request(url, opts) {
            sessionApi.callNativeApi(DEMO_METHOD.REQUEST, {
                url, success: opts.success, fail: opts.fail
            })
        }

        function requestWithTimeout(url, timeoutMs, opts) {
            sessionApi.callNativeApi(DEMO_METHOD.REQUEST, {
                url, timeoutMs, success: opts.success, fail: opts.fail
            })
        }

        function callUnauthorized(method, opts) {
            sessionApi.callNativeApi(method, {
                success: opts.success, fail: opts.fail
            })
        }

        return {
            ACTION_METHOD_MAP,
            showLoading,
            getCurrentLocation,
            getUser,
            getUserWithSession,
            pickImage,
            pickInput,
            timerStart,
            timerStop,
            request,
            requestWithTimeout,
            callUnauthorized,
        }
    }

    global.createBizApi = createBizApi
})(window)
