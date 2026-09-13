#!/usr/bin/env node
'use strict';

/**
 * Integration tests for the image service.
 *
 * This process is the ingress entry point: it serves the UI, accepts pasted
 * images and proxies the ttyd terminal (HTTP and WebSocket). None of that was
 * covered by a test before, which is how the "always healthy" readiness bug and
 * the localhost/127.0.0.1 proxy ambiguity survived.
 *
 * Runs against the real server.js with no mocking beyond a stub ttyd.
 */

const test = require('node:test');
const assert = require('node:assert');
const http = require('node:http');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');

const SERVICE_DIR = path.join(__dirname, '..', 'claude-terminal', 'image-service');
const SERVER = path.join(SERVICE_DIR, 'server.js');

// 1x1 transparent PNG
const PNG = Buffer.from(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
    'base64'
);

let uploadDir;
let child;
let ttyd;
let ttydUpgrades = 0;
let PORT;
let TTYD_PORT;

function freePort() {
    return new Promise((resolve, reject) => {
        const s = http.createServer();
        s.listen(0, '127.0.0.1', () => {
            const { port } = s.address();
            s.close(() => resolve(port));
        });
        s.on('error', reject);
    });
}

async function waitForHealth(port, attempts = 60) {
    for (let i = 0; i < attempts; i++) {
        try {
            const r = await fetch(`http://127.0.0.1:${port}/health`);
            if (r.ok) return true;
        } catch { /* not up yet */ }
        await new Promise((r) => setTimeout(r, 100));
    }
    return false;
}

function multipart(fieldName, filename, contentType, body) {
    const boundary = '----claudeterminaltest' + Date.now();
    const head = Buffer.from(
        `--${boundary}\r\n` +
        `Content-Disposition: form-data; name="${fieldName}"; filename="${filename}"\r\n` +
        `Content-Type: ${contentType}\r\n\r\n`
    );
    const tail = Buffer.from(`\r\n--${boundary}--\r\n`);
    return { boundary, payload: Buffer.concat([head, body, tail]) };
}

test.before(async () => {
    uploadDir = fs.mkdtempSync(path.join(os.tmpdir(), 'claude-img-'));
    PORT = await freePort();
    TTYD_PORT = await freePort();

    // Stub ttyd: answers HTTP and accepts WebSocket upgrades.
    ttyd = http.createServer((req, res) => {
        res.writeHead(200, { 'Content-Type': 'text/plain' });
        res.end(`ttyd-stub:${req.url}`);
    });
    ttyd.on('upgrade', (req, socket) => {
        ttydUpgrades++;
        socket.write(
            'HTTP/1.1 101 Switching Protocols\r\n' +
            'Upgrade: websocket\r\nConnection: Upgrade\r\n\r\n'
        );
        socket.end();
    });
    await new Promise((r) => ttyd.listen(TTYD_PORT, '127.0.0.1', r));

    child = spawn(process.execPath, [SERVER], {
        cwd: SERVICE_DIR,
        env: {
            ...process.env,
            IMAGE_SERVICE_PORT: String(PORT),
            TTYD_PORT: String(TTYD_PORT),
            UPLOAD_DIR: uploadDir
        },
        stdio: ['ignore', 'pipe', 'pipe']
    });
    child.stdout.on('data', () => {});
    child.stderr.on('data', (d) => process.stderr.write(`[service] ${d}`));

    assert.ok(await waitForHealth(PORT), 'image service never answered /health');
});

test.after(() => {
    if (child) child.kill('SIGKILL');
    if (ttyd) ttyd.close();
    if (uploadDir) fs.rmSync(uploadDir, { recursive: true, force: true });
});

test('/health reports ok and the active upload directory', async () => {
    const res = await fetch(`http://127.0.0.1:${PORT}/health`);
    assert.strictEqual(res.status, 200);
    const body = await res.json();
    assert.strictEqual(body.status, 'ok');
    assert.strictEqual(body.uploadDir, uploadDir);
});

test('/config exposes the ttyd port to the frontend', async () => {
    const res = await fetch(`http://127.0.0.1:${PORT}/config`);
    assert.strictEqual(res.status, 200);
    const body = await res.json();
    assert.strictEqual(String(body.ttydPort), String(TTYD_PORT));
});

test('/upload stores a pasted image and returns its path', async () => {
    const { boundary, payload } = multipart('image', 'clipboard.png', 'image/png', PNG);
    const res = await fetch(`http://127.0.0.1:${PORT}/upload`, {
        method: 'POST',
        headers: { 'Content-Type': `multipart/form-data; boundary=${boundary}` },
        body: payload
    });

    assert.strictEqual(res.status, 200);
    const body = await res.json();
    assert.strictEqual(body.success, true);
    assert.match(body.filename, /^pasted-\d+\.png$/);
    assert.strictEqual(body.path, path.join(uploadDir, body.filename));
    assert.ok(fs.existsSync(body.path), 'uploaded file was not written to disk');
    assert.strictEqual(fs.readFileSync(body.path).length, PNG.length);
});

test('/upload refuses a non-image payload', async () => {
    const { boundary, payload } = multipart(
        'image', 'payload.sh', 'application/x-sh', Buffer.from('#!/bin/sh\nid\n')
    );
    const res = await fetch(`http://127.0.0.1:${PORT}/upload`, {
        method: 'POST',
        headers: { 'Content-Type': `multipart/form-data; boundary=${boundary}` },
        body: payload
    });

    assert.notStrictEqual(res.status, 200);
    const written = fs.readdirSync(uploadDir).filter((f) => f.endsWith('.sh'));
    assert.deepStrictEqual(written, [], 'a rejected upload must not reach disk');
});

test('a hostile filename cannot escape the upload directory', async () => {
    const { boundary, payload } = multipart(
        'image', '../../../../etc/cron.d/pwned.png', 'image/png', PNG
    );
    const res = await fetch(`http://127.0.0.1:${PORT}/upload`, {
        method: 'POST',
        headers: { 'Content-Type': `multipart/form-data; boundary=${boundary}` },
        body: payload
    });

    assert.strictEqual(res.status, 200);
    const body = await res.json();
    assert.ok(
        path.resolve(body.path).startsWith(path.resolve(uploadDir) + path.sep),
        `upload escaped the upload directory: ${body.path}`
    );
    assert.ok(!body.filename.includes('/'), 'stored filename must not contain a separator');
});

test('/terminal proxies HTTP through to ttyd', async () => {
    const res = await fetch(`http://127.0.0.1:${PORT}/terminal/`);
    assert.strictEqual(res.status, 200);
    assert.match(await res.text(), /^ttyd-stub:/);
});

test('/terminal forwards a WebSocket upgrade to ttyd', async () => {
    const before = ttydUpgrades;

    const status = await new Promise((resolve, reject) => {
        const req = http.request({
            host: '127.0.0.1',
            port: PORT,
            path: '/terminal/ws',
            headers: {
                Connection: 'Upgrade',
                Upgrade: 'websocket',
                'Sec-WebSocket-Version': '13',
                'Sec-WebSocket-Key': 'dGhlIHNhbXBsZSBub25jZQ=='
            }
        });
        req.on('upgrade', (res, socket) => {
            socket.destroy();
            resolve(res.statusCode);
        });
        req.on('response', (res) => resolve(res.statusCode));
        req.on('error', reject);
        req.setTimeout(5000, () => reject(new Error('upgrade timed out')));
        req.end();
    });

    assert.strictEqual(status, 101, 'proxy did not complete the WebSocket handshake');
    assert.strictEqual(ttydUpgrades, before + 1, 'ttyd did not receive exactly one upgrade');
});

test('the static UI is served at the root', async () => {
    const res = await fetch(`http://127.0.0.1:${PORT}/`);
    assert.strictEqual(res.status, 200);
    assert.match(res.headers.get('content-type') || '', /text\/html/);
});

test('a WebSocket upgrade is proxied even as the very first proxy request', async () => {
    // Regression guard: http-proxy-middleware only subscribes to 'upgrade'
    // lazily, on the first HTTP request that reaches the middleware. Without an
    // explicit server.on('upgrade') the handshake below hangs until it times
    // out, which is what a browser sees when it reconnects to the terminal
    // before loading anything else. Verified: removing that line turns this
    // test from 101 into a timeout.
    const port = await freePort();
    const ttydPort = await freePort();
    let upgrades = 0;

    const stub = http.createServer((req, res) => res.end('stub'));
    stub.on('upgrade', (req, socket) => {
        upgrades++;
        socket.write(
            'HTTP/1.1 101 Switching Protocols\r\n' +
            'Upgrade: websocket\r\nConnection: Upgrade\r\n\r\n'
        );
        socket.end();
    });
    await new Promise((r) => stub.listen(ttydPort, '127.0.0.1', r));

    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'claude-ws-'));
    const proc = spawn(process.execPath, [SERVER], {
        cwd: SERVICE_DIR,
        env: {
            ...process.env,
            IMAGE_SERVICE_PORT: String(port),
            TTYD_PORT: String(ttydPort),
            UPLOAD_DIR: dir
        },
        stdio: 'ignore'
    });

    try {
        assert.ok(await waitForHealth(port), 'second instance never became healthy');

        const status = await new Promise((resolve, reject) => {
            const req = http.request({
                host: '127.0.0.1',
                port,
                path: '/terminal/ws',
                headers: {
                    Connection: 'Upgrade',
                    Upgrade: 'websocket',
                    'Sec-WebSocket-Version': '13',
                    'Sec-WebSocket-Key': 'dGhlIHNhbXBsZSBub25jZQ=='
                }
            });
            req.on('upgrade', (res, socket) => { socket.destroy(); resolve(res.statusCode); });
            req.on('response', (res) => resolve(res.statusCode));
            req.on('error', reject);
            req.setTimeout(5000, () => reject(new Error('WebSocket upgrade timed out')));
            req.end();
        });

        assert.strictEqual(status, 101, 'first-request WebSocket upgrade was not proxied');
        assert.strictEqual(upgrades, 1, 'ttyd should receive exactly one upgrade');
    } finally {
        proc.kill('SIGKILL');
        stub.close();
        fs.rmSync(dir, { recursive: true, force: true });
    }
});
