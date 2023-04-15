package io.github.xesam.example.bridge;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.os.Bundle;
import android.util.Log;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import androidx.core.graphics.Insets;
import androidx.core.view.ViewCompat;
import androidx.core.view.WindowInsetsCompat;

import io.github.xesam.android.bridge.extensions.registry.BridgeResultRegistry;
import io.github.xesam.android.bridge.extensions.registry.BridgeResultDispatcher;
import io.github.xesam.android.bridge.extensions.registry.CompatBridgeResultRegistry;
import io.github.xesam.android.bridge.extensions.lifecycle.LifecycleExtension;
import io.github.xesam.android.bridge.extensions.system.AndroidWebViewBridgeTransport;
import io.github.xesam.android.bridge.extensions.system.AndroidWebViewPageContextProvider;
import io.github.xesam.android.bridge.JsBridge;
import io.github.xesam.example.bridge.permissions.ActivityPermissionRegistry;
import io.github.xesam.example.bridge.permissions.PermissionRequestRegistry;
import io.github.xesam.example.bridge.databinding.ActivityBaseWebBinding;

public class CompatWebActivity extends Activity {

    private ActivityBaseWebBinding binding;
    private JsBridge mBridge;
    private BridgeResultRegistry mBridgeResultRegistry;
    private BridgeResultDispatcher mBridgeResultDispatcher;
    private PermissionRequestRegistry permissionRequestRegistry;
    private LifecycleExtension lifecycleExtension;

    @SuppressLint("SetJavaScriptEnabled")
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        binding = ActivityBaseWebBinding.inflate(getLayoutInflater());
        setContentView(binding.getRoot());
        ViewCompat.setOnApplyWindowInsetsListener(binding.getRoot(), (v, insets) -> {
            Insets systemBars = insets.getInsets(WindowInsetsCompat.Type.systemBars());
            binding.getRoot().setPadding(systemBars.left, systemBars.top, systemBars.right, systemBars.bottom);
            return insets;
        });
        mBridge = new JsBridge(
                new AndroidWebViewBridgeTransport(binding.webContainer),
                new AndroidWebViewPageContextProvider(binding.webContainer),
                BridgePolicyConfig.createKernelConfig(),
                BridgePolicyConfig.createSecurityConfig());
        lifecycleExtension = new LifecycleExtension(mBridge);
        mBridgeResultRegistry = new CompatBridgeResultRegistry(this);
        mBridgeResultDispatcher = (BridgeResultDispatcher) mBridgeResultRegistry;
        permissionRequestRegistry = new ActivityPermissionRegistry(this);
        binding.webContainer.getSettings().setJavaScriptEnabled(true);
        binding.webContainer.getSettings().setAllowFileAccess(true);
        binding.webContainer.getSettings().setAllowFileAccessFromFileURLs(true);
        binding.webContainer.getSettings().setAllowContentAccess(true);
        binding.webContainer.getSettings().setDomStorageEnabled(true);
        binding.webContainer.setWebViewClient(new WebViewClient() {
            @Override
            public void onPageFinished(WebView view, String url) {
                super.onPageFinished(view, url);
                Log.d("onPageFinished", url);
                mBridge.resetTransport();
                mBridge.resetForNewPage();
            }
        });
        WebActivities.setupBridge(mBridge, this, mBridgeResultRegistry, permissionRequestRegistry);
        binding.webContainer.loadUrl("file:///android_asset/web/index.html");
        lifecycleExtension.onHostEvent("created");
    }

    @Override
    protected void onStart() {
        super.onStart();
        lifecycleExtension.onHostEvent("started");
    }

    @Override
    protected void onResume() {
        super.onResume();
        lifecycleExtension.onHostEvent("resumed");
    }

    @Override
    protected void onPause() {
        super.onPause();
        lifecycleExtension.onHostEvent("paused");
    }

    @Override
    protected void onStop() {
        super.onStop();
        lifecycleExtension.onHostEvent("stopped");
    }

    @Override
    protected void onDestroy() {
        lifecycleExtension.onHostEvent("destroyed");
        mBridge.destroy();
        super.onDestroy();
        mBridgeResultRegistry.destroy();
        permissionRequestRegistry.destroy();
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, android.content.Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        mBridgeResultDispatcher.dispatchResult(requestCode, resultCode, data);
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        permissionRequestRegistry.dispatchResult(requestCode, permissions, grantResults);
    }
}
