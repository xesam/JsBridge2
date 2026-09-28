package io.github.xesam.android.bridge.core.handler;

import org.json.JSONObject;

import io.github.xesam.android.bridge.api.model.TrustedPageContext;

/**
 * Async Handler (统一 API v1.0): 带 ResponseEmitter 参数，可在返回后继续推帧。
 */
public interface AsyncHandler {
    /**
     * 处理请求并通过 emitter 异步发送多个响应
     * @param context 可信页面上下文（origin / pageInstanceId）
     * @param payload 请求 payload
     * @param emitter 响应发送器，用于在处理过程中随时发送响应帧
     * @throws Exception 处理异常，将被归一化为 E_INTERNAL
     */
    void handle(TrustedPageContext context, JSONObject payload, ResponseEmitter emitter) throws Exception;
}
