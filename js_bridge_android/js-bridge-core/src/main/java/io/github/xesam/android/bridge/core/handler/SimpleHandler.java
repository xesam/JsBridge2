package io.github.xesam.android.bridge.core.handler;

import org.json.JSONObject;

import io.github.xesam.android.bridge.api.model.TrustedPageContext;

/**
 * Simple Handler (统一 API v1.0): 单返回值，通信在 handler 返回时结束。
 * 语义上恰好产生一帧响应（done 恒为 true）；需要多帧请改用 {@link AsyncHandler}。
 */
public interface SimpleHandler {
    /**
     * 处理请求并返回单个结果
     * @param context 可信页面上下文（origin / pageInstanceId）
     * @param payload 请求 payload
     * @return 响应结果（可以是任意 JSON 可序列化的对象）
     * @throws Exception 处理异常，将被归一化为 E_INTERNAL
     */
    Object handle(TrustedPageContext context, JSONObject payload) throws Exception;
}
