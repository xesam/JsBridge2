package io.github.xesam.example.bridge;

import com.fasterxml.jackson.databind.ObjectMapper;

import java.net.URLDecoder;

public abstract class JsonPayloadParser<T> implements PayloadParser<T> {
    @Override
    public T getPayload(String dataString) {
        try {
            String decodeDataString = URLDecoder.decode(dataString, "UTF-8");
            return new ObjectMapper().readValue(decodeDataString, this.getValueType());
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }

    protected abstract Class<T> getValueType();
}
