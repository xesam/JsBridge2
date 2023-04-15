package io.github.xesam.example.bridge;

public interface PayloadParser<T> {
    T getPayload(String data);
}
