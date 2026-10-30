#!/usr/bin/env node
/*
 * Сверка решателя `n` без устройства.
 *
 * Берёт скрипт плеера (tv-player-ias.js) и заводит Resources/nsig.js
 * с окружением Resources/nsig-env.js дважды:
 *
 *   как есть    — в контексте Node, где типизированные массивы настоящие;
 *   как iOS 5   — тот же контекст, но без всего, чего нет в голом
 *                 JavaScriptCore iOS 5/6: типизированных массивов (их
 *                 давал WebCore), Map, Set, Promise, Symbol и прочего ES2015.
 *
 * Ответы обоих прогонов должны совпасть между собой и с тем, что пишет
 * в журнал веб-вид на устройстве («Готово: … DhpWuaCJRFiGbHK → …»).
 *
 * Запуск:
 *
 *     curl -o player.js https://www.youtube.com/s/player/<сборка>/tv-player-ias.vflset/tv-player-ias.js
 *     node tools/nsig-check.js player.js [n …]
 */
'use strict';

const vm = require('vm');
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..', 'Resources');
const env = fs.readFileSync(path.join(root, 'nsig-env.js'), 'utf8');
const solver = fs.readFileSync(path.join(root, 'nsig.js'), 'utf8');

const playerPath = process.argv[2];

if (!playerPath) {
    console.error('Нужен путь к скрипту плеера — см. начало файла');
    process.exit(2);
}

const player = fs.readFileSync(playerPath, 'utf8');
const samples = ['DhpWuaCJRFiGbHK'].concat(process.argv.slice(3));

const IOS5_MISSING = [
    'Uint8Array', 'Int8Array', 'Uint8ClampedArray', 'Uint16Array', 'Int16Array',
    'Uint32Array', 'Int32Array', 'Float32Array', 'Float64Array', 'BigInt64Array',
    'BigUint64Array', 'ArrayBuffer', 'SharedArrayBuffer', 'DataView', 'Map', 'Set',
    'WeakMap', 'WeakSet', 'Promise', 'Symbol', 'Proxy', 'Reflect', 'WeakRef',
    'FinalizationRegistry', 'Atomics', 'BigInt', 'globalThis', 'queueMicrotask',
    'structuredClone', 'Intl', 'AggregateError',
];

// Плеер оставляет за собой отложенные обещания; к расшифровке они отношения не имеют.
process.on('unhandledRejection', () => {});

function run(label, strip) {
    const context = vm.createContext({ console: { log: () => {} } });

    if (strip) {
        vm.runInContext('(' + JSON.stringify(IOS5_MISSING) +
            ').forEach(function (n) { try { delete this[n]; } catch (e) {} }, this);', context);
    }

    vm.runInContext(env, context);
    vm.runInContext(solver, context);

    context.__text = player;

    const started = Date.now();
    const report = vm.runInContext('YTSolver.boot(__text)', context);
    const answers = {};

    if (/^ok /.test(report)) {
        for (const n of samples) {
            answers[n] = vm.runInContext('YTn(' + JSON.stringify(n) + ')', context);
        }
    }

    console.log(label + ': ' + report.slice(0, 300) + ' (' + (Date.now() - started) + ' мс)');

    for (const n of Object.keys(answers)) {
        console.log('    ' + n + ' → ' + answers[n]);
    }

    return answers;
}

const plain = run('как есть', false);
const ios5 = run('как iOS 5', true);

const same = samples.every((n) => plain[n] && plain[n] === ios5[n]);

console.log(same ? 'Совпало' : 'РАЗОШЛОСЬ');
process.exit(same ? 0 : 1);
