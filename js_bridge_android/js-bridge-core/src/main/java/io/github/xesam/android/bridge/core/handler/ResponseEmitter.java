package io.github.xesam.android.bridge.core.handler;

import io.github.xesam.android.bridge.api.model.BridgeError;

/**
 * Response Emitter (统一 API v1.0): 异步多响应发送器
 */
public interface ResponseEmitter {
    /**
     * 发送成功响应
     * @param payload 响应数据（可以是任意 JSON 可序列化的对象）
     * @param done true 表示这是最后一帧，false 表示后续还有更多帧
     */
    void success(Object payload, boolean done);

    void fail(BridgeError error);
}
