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


/*
 * Типизированные массивы — только там, где их нет.
 *
 * До iOS 7 их давал не JavaScriptCore, а WebCore: в UIWebView они есть,
 * а в голом движке iOS 5/6 — нет. Плеер 11a45ffb уже при загрузке
 * спрашивает `typeof Uint8Array.prototype.slice`, а потом пишет байты
 * через DataView; без них он падал на первой же строке, решатель уходил
 * в веб-вид, и в памяти разом оказывались обе попытки (журнал 30.10.2026:
 * 96 МБ и просьба системы).
 *
 * Здесь это обычные массивы с методами типизированных. Байтовый вид на
 * весь буфер — сам массив байтов буфера, поэтому записанное через
 * DataView видно в нём сразу; вид на часть буфера — копия. Расшифровке
 * `n` этого хватает: она работает со строками, и ответы с этой заменой
 * сверены с настоящими массивами (tools/nsig-check.js).
 */
(function (g) {
    if (typeof g.Uint8Array !== "undefined") {
        return;
    }

    function zeros(count) {
        var out = [];

        for (var i = 0; i < count; i++) {
            out.push(0);
        }

        return out;
    }

    function Buffer(length) {
        this._bytes = zeros(length >>> 0);
        this.byteLength = this._bytes.length;
    }

    Buffer.prototype.slice = function (begin, end) {
        var copy = new Buffer(0);

        copy._bytes = Array.prototype.slice.call(this._bytes, begin, end);
        copy.byteLength = copy._bytes.length;

        return copy;
    };

    Buffer.isView = function (value) {
        return !!(value && value.buffer instanceof Buffer);
    };

    function adopt(items, View, size, buffer, offset) {
        items.__proto__ = View.prototype;
        items.byteOffset = offset;
        items.byteLength = items.length * size;

        if (!buffer) {
            buffer = new Buffer(0);
            buffer.byteLength = items.byteLength;

            if (size === 1) {
                buffer._bytes = items;
            }
        }

        items.buffer = buffer;

        return items;
    }

    function kind(size, mask) {
        function View(source, offset, length) {
            var items, i;

            if (source instanceof Buffer) {
                offset = offset || 0;

                var count = (length === undefined)
                    ? (source.byteLength - offset) / size : length;

                // Вид на весь буфер — сам буфер: запись через DataView видна сразу.
                if (size === 1 && offset === 0 && count === source._bytes.length) {
                    return adopt(source._bytes, View, 1, source, 0);
                }

                items = (size === 1)
                    ? Array.prototype.slice.call(source._bytes, offset, offset + count)
                    : zeros(count);

                return adopt(items, View, size, source, offset);
            }

            if (typeof source === "number") {
                items = zeros(source);
            } else if (source && typeof source.length === "number") {
                items = [];

                for (i = 0; i < source.length; i++) {
                    items.push(mask ? (source[i] & mask) : (Number(source[i]) || 0));
                }
            } else {
                items = [];
            }

            return adopt(items, View, size, null, 0);
        }

        View.BYTES_PER_ELEMENT = size;
        View.prototype = [];
        View.prototype.constructor = View;
        View.prototype.BYTES_PER_ELEMENT = size;

        View.prototype.set = function (source, offset) {
            offset = offset || 0;

            for (var i = 0; i < source.length; i++) {
                this[offset + i] = mask ? (source[i] & mask) : source[i];
            }
        };

        View.prototype.subarray = function (begin, end) {
            return new View(Array.prototype.slice.call(this, begin, end));
        };

        View.prototype.slice = View.prototype.subarray;

        View.prototype.fill = function (value, begin, end) {
            var stop = (end === undefined) ? this.length : end;

            for (var i = begin || 0; i < stop; i++) {
                this[i] = value;
            }

            return this;
        };

        return View;
    }

    function DataView(buffer, offset, length) {
        this.buffer = buffer;
        this.byteOffset = offset || 0;
        this.byteLength = (length === undefined)
            ? buffer.byteLength - this.byteOffset : length;
    }

    DataView.prototype._get = function (at, count, little) {
        var bytes = this.buffer._bytes;
        var value = 0;

        for (var i = 0; i < count; i++) {
            value = value * 256 +
                (bytes[this.byteOffset + at + (little ? count - 1 - i : i)] & 255);
        }

        return value;
    };

    DataView.prototype._set = function (at, count, value, little) {
        var bytes = this.buffer._bytes;

        for (var i = count - 1; i >= 0; i--) {
            bytes[this.byteOffset + at + (little ? count - 1 - i : i)] = value & 255;
            value = Math.floor(value / 256);
        }
    };

    function signed(value, bits) {
        var top = Math.pow(2, bits - 1);

        return value >= top ? value - top * 2 : value;
    }

    var P = DataView.prototype;

    P.getUint8 = function (at) { return this._get(at, 1, false); };
    P.getInt8 = function (at) { return signed(this._get(at, 1, false), 8); };
    P.getUint16 = function (at, little) { return this._get(at, 2, little); };
    P.getInt16 = function (at, little) { return signed(this._get(at, 2, little), 16); };
    P.getUint32 = function (at, little) { return this._get(at, 4, little); };
    P.getInt32 = function (at, little) { return signed(this._get(at, 4, little), 32); };
    P.setUint8 = function (at, value) { this._set(at, 1, value, false); };
    P.setInt8 = P.setUint8;
    P.setUint16 = function (at, value, little) { this._set(at, 2, value, little); };
    P.setInt16 = P.setUint16;
    P.setUint32 = function (at, value, little) { this._set(at, 4, value, little); };
    P.setInt32 = P.setUint32;

    g.ArrayBuffer = Buffer;
    g.DataView = DataView;
    g.Uint8Array = kind(1, 255);
    g.Int8Array = kind(1, 0);
    g.Uint8ClampedArray = kind(1, 255);
    g.Uint16Array = kind(2, 65535);
    g.Int16Array = kind(2, 0);
    g.Uint32Array = kind(4, 0);
    g.Int32Array = kind(4, 0);
    g.Float32Array = kind(4, 0);
    g.Float64Array = kind(8, 0);
})(this);
