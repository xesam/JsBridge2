(function () {
  "use strict";

  var I18N = {
    en: {
      "hero.kicker": "Multi-platform JS-Native bridge",
      "hero.line1": "One protocol.",
      "hero.line2": "Four platforms.",
      "hero.sub":
        "One message protocol, one session model, and one set of WebAssets — running on Android, iOS, Flutter and HarmonyOS. Not a shared runtime: a shared contract.",
      "hero.ctaPrimary": "View on GitHub",
      "hero.ctaSecondary": "Read the architecture",
      "problem.title": "The problem",
      "problem.c1.title": "Fragmented native channels",
      "problem.c1.body":
        "Android WebMessagePort, iOS WKScriptMessageHandler, Flutter JS channels, HarmonyOS ArkWeb — every platform speaks a different dialect of JS-Native messaging.",
      "problem.c2.title": "No session or handshake",
      "problem.c2.body":
        "Ad-hoc bridges lack a handshake, session lifecycle and cancellation semantics — every H5 page reinvents its own transport.",
      "problem.c3.title": "Security logic scattered",
      "problem.c3.body":
        "Origin checks, method whitelists and session validation end up duplicated and inconsistent across platforms and pages.",
      "problem.c4.title": "Four implementations, four behaviors",
      "problem.c4.body":
        "Without a common contract, each platform re-implements the bridge — and each drifted implementation raises integration costs.",
      "solution.title": "The JsBridge2 answer",
      "solution.c1.title": "Protocol v1",
      "solution.c1.body":
        "A single message envelope — request / response / event — with handshake, session, timeout and scope cancellation defined once, in the spec.",
      "solution.c2.title": "Security policy chain",
      "solution.c2.body":
        "A fixed evaluation order: shape → handshake gate → origin → method gate → session → host policies. Hosts extend, never override.",
      "solution.c3.title": "Shared WebAssets",
      "solution.c3.body":
        "One jsbridge-sdk.js bundle runs identically in all four native shells. One source of truth, synced to every platform.",
      "solution.note": "The goal is cross-platform protocol consistency — not a shared runtime.",
      "arch.title": "Three layered tiers",
      "arch.t3": "lifecycle · registry · system adapters",
      "arch.t2": "session · policies · handshake",
      "arch.t1": "pure protocol dispatch · handlers · transport",
      "arch.t0": "BridgeMessage · BridgeError · contracts",
      "arch.note":
        "Unidirectional dependencies: JsBridge → CoreBridge → api. CoreBridge has zero security dependencies; security has zero core dependencies.",
      "platforms.title": "Four platforms, one contract",
      "platforms.android":
        "Reference implementation. js-bridge-core + WebView transport adapter.",
      "platforms.ios":
        "Swift Package with Bridge core plus a WKWebView transport in BridgeSystem.",
      "platforms.flutter":
        "Core package plus host-app example. Transport injected via bindTransport().",
      "platforms.harmony":
        "Stage-model HAR core with the same envelope, handshake and policy chain.",
      "platforms.link": "Read integration guide →",
      "quickstart.title": "Quick start",
      "quickstart.comment": "# Build the JS SDK and sync it to all four platforms first",
      "quickstart.comment2": "# Then load the SDK from any WebView page",
      "quickstart.more": "Full quick start →",
      "docs.title": "Documentation",
      "docs.c1": "Design principles",
      "docs.c2": "Protocol v1 spec",
      "docs.c3": "Lifecycle layers",
      "docs.c4": "Channel establishment",
      "docs.c5": "Transport loop design",
      "docs.c6": "Conformance (C01–C66)",
      "footer.slogan": "One protocol. Four platforms."
    },
    zh: {
      "hero.kicker": "多端 JS-Native 桥接库",
      "hero.line1": "同一协议。",
      "hero.line2": "覆盖四端。",
      "hero.sub":
        "同一套消息协议、同一会话模型、同一套 WebAssets，运行在 Android / iOS / Flutter / HarmonyOS 四端。共享的不是运行时，而是契约。",
      "hero.ctaPrimary": "在 GitHub 查看",
      "hero.ctaSecondary": "阅读架构设计",
      "problem.title": "问题",
      "problem.c1.title": "原生信道碎片化",
      "problem.c1.body":
        "Android 的 WebMessagePort、iOS 的 WKScriptMessageHandler、Flutter 的 JS channel、HarmonyOS 的 ArkWeb——每端的 JS-Native 通信方言各不相同。",
      "problem.c2.title": "缺乏会话与握手机制",
      "problem.c2.body":
        "临时拼装的 bridge 没有握手、会话生命周期与取消语义，每个 H5 页面都要重新发明自己的传输层。",
      "problem.c3.title": "安全逻辑分散",
      "problem.c3.body":
        "origin 校验、方法白名单、session 验证在各端各页面重复实现，且行为不一致。",
      "problem.c4.title": "四端实现，四种行为",
      "problem.c4.body":
        "没有共同契约时，每端各自重造 bridge——每一处实现漂移都在推高集成成本。",
      "solution.title": "JsBridge2 的解法",
      "solution.c1.title": "Protocol v1",
      "solution.c1.body":
        "统一的消息信封——request / response / event——握手、会话、超时与 scope 取消都只在协议中定义一次。",
      "solution.c2.title": "安全策略链",
      "solution.c2.body":
        "固定求值顺序：结构 → 握手门 → origin → 方法门 → session → 宿主策略。宿主只扩展，不覆盖。",
      "solution.c3.title": "共享 WebAssets",
      "solution.c3.body":
        "同一份 jsbridge-sdk.js 在四端原生容器中行为一致。唯一正本，同步到每个平台。",
      "solution.note": "目标是跨端协议一致性——而非共享运行时。",
      "arch.title": "三层叠加架构",
      "arch.t3": "lifecycle · registry · system 适配器",
      "arch.t2": "session · 策略链 · 握手",
      "arch.t1": "纯协议分发 · handler · transport",
      "arch.t0": "BridgeMessage · BridgeError · 契约",
      "arch.note":
        "依赖方向单向：JsBridge → CoreBridge → api。CoreBridge 零 security 依赖，security 零 core 依赖。",
      "platforms.title": "四端实现，同一契约",
      "platforms.android": "参考实现：js-bridge-core + WebView transport 适配器。",
      "platforms.ios": "Swift Package：Bridge core + BridgeSystem 中的 WKWebView transport。",
      "platforms.flutter": "core package + 宿主示例 App，transport 经 bindTransport() 注入。",
      "platforms.harmony": "Stage 模型 HAR core，同样的信封、握手与策略链。",
      "platforms.link": "阅读集成指南 →",
      "quickstart.title": "快速开始",
      "quickstart.comment": "# 先构建 JS SDK 并同步到四端",
      "quickstart.comment2": "# 然后在任意 WebView 页面加载 SDK",
      "quickstart.more": "完整快速开始 →",
      "docs.title": "文档",
      "docs.c1": "设计原则",
      "docs.c2": "Protocol v1 规范",
      "docs.c3": "生命周期分层",
      "docs.c4": "信道建立",
      "docs.c5": "Transport 闭环设计",
      "docs.c6": "验收用例（C01–C66）",
      "footer.slogan": "同一协议。覆盖四端。"
    }
  };

  var STORAGE_KEY = "jsbridge2-lang";
  var nodes = Array.prototype.slice.call(
    document.querySelectorAll("[data-i18n]")
  );
  var toggleBtn = document.getElementById("langToggle");
  var current;

  function detectLang() {
    var stored = null;
    try {
      stored = localStorage.getItem(STORAGE_KEY);
    } catch (e) {}
    if (stored === "zh" || stored === "en") return stored;
    var nav = (navigator.language || "").toLowerCase();
    return nav.indexOf("zh") === 0 ? "zh" : "en";
  }

  function apply(lang) {
    current = lang;
    var dict = I18N[lang];
    nodes.forEach(function (node) {
      var key = node.getAttribute("data-i18n");
      if (dict[key]) node.textContent = dict[key];
    });
    document.documentElement.lang = lang;
    if (toggleBtn) toggleBtn.textContent = lang === "zh" ? "EN" : "中文";
    try {
      localStorage.setItem(STORAGE_KEY, lang);
    } catch (e) {}
  }

  if (toggleBtn) {
    toggleBtn.addEventListener("click", function () {
      apply(current === "zh" ? "en" : "zh");
    });
  }

  apply(detectLang());
})();
