/*
 * Окружение для скрипта плеера без браузера — для решателя `n` в голом
 * движке (YTJSEngine). Только ES5: это JavaScriptCore iOS 5.
 *
 * Здесь ровно то, что плеер трогает, пока загружается: окно, документ,
 * навигатор, адрес, замеры времени, таймеры. Набор снят разведкой
 * (Proxy, отмечающий каждое обращение) на плеере dce23b30. Ни один вызов
 * ничего не делает: решателю нужно лишь, чтобы плеер дошёл до конца
 * и завёл свои функции, а работать с документом ему незачем.
 *
 * Понадобится плееру что-то ещё — `nsig.js` напишет в отчёте, на чём
 * упало, и решатель поднимется прежним путём, в веб-виде.
 */
var window = this, self = this, top = this, parent = this;

(function (g) {
    function noop() {}

    function node() {
        return {
            style: {},
            children: [],
            childNodes: [],
            setAttribute: noop,
            getAttribute: function () { return null; },
            appendChild: function (child) { return child; },
            removeChild: noop,
            addEventListener: noop,
            removeEventListener: noop
        };
    }

    g.navigator = {
        userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
            "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
        cookieEnabled: false,
        language: "en-US",
        languages: ["en-US"],
        platform: ""
    };

    g.location = {
        hash: "",
        protocol: "https:",
        hostname: "www.youtube.com",
        host: "www.youtube.com",
        href: "https://www.youtube.com/tv",
        origin: "https://www.youtube.com",
        pathname: "/tv",
        search: "",
        port: ""
    };

    var doc = node();

    doc.readyState = "complete";
    doc.URL = "https://www.youtube.com/tv";
    doc.cookie = "";
    doc.createElement = node;
    doc.createTextNode = node;
    doc.getElementById = function () { return null; };
    doc.getElementsByTagName = function () { return []; };
    doc.querySelector = function () { return null; };
    doc.querySelectorAll = function () { return []; };
    doc.documentElement = node();
    doc.head = node();
    doc.body = node();

    g.document = doc;

    var started = new Date().getTime();

    g.performance = {
        now: function () { return new Date().getTime() - started; },
        timing: { navigationStart: started },
        mark: noop,
        measure: noop,
        clearMarks: noop,
        clearMeasures: noop,
        clearResourceTimings: noop,
        getEntriesByType: function () { return []; }
    };

    g.XMLHttpRequest = function () {};
    g.XMLHttpRequest.prototype = { open: noop, send: noop, setRequestHeader: noop };

    // Таймеры не исполняются: решателю отложенное не нужно.
    g.setTimeout = function () { return 0; };
    g.clearTimeout = noop;
    g.setInterval = function () { return 0; };
    g.clearInterval = noop;

    g.addEventListener = noop;
    g.removeEventListener = noop;
})(this);
