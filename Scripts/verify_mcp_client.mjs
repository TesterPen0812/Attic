#!/usr/bin/env node
// Read-only by default. Credentials stay in this process and are never printed.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';

const endpoint = new URL(process.env.ATTIC_MCP_ENDPOINT ?? 'http://127.0.0.1:7335/mcp');
assert.equal(endpoint.protocol, 'http:');
assert.equal(endpoint.hostname, '127.0.0.1', 'Credentials must stay on loopback');
assert.equal(endpoint.pathname, '/mcp');
assert.equal(endpoint.username + endpoint.password + endpoint.search + endpoint.hash, '');
const sdkRoot = process.env.ATTIC_MCP_SDK_ROOT;
assert.ok(sdkRoot, 'Set ATTIC_MCP_SDK_ROOT to an installed @modelcontextprotocol/sdk directory');
const { Client } = await import(pathToFileURL(resolve(sdkRoot, 'dist/esm/client/index.js')));
const { StreamableHTTPClientTransport } = await import(pathToFileURL(resolve(sdkRoot, 'dist/esm/client/streamableHttp.js')));

let token = process.env.ATTIC_MCP_TOKEN;
if (!token && process.env.ATTIC_MCP_BUNDLE_ID) {
    const identity = process.env.ATTIC_MCP_BUNDLE_ID;
    assert.match(identity, /^com\.taha\.Attic(?:\.[A-Za-z0-9.-]+)?$/);
    try {
        token = execFileSync('/usr/bin/security', [
            'find-generic-password', '-s', `${identity}.agent-access`,
            '-a', 'mcp-bearer-token', '-w'
        ], { stdio: ['ignore', 'pipe', 'pipe'], timeout: 15_000 }).toString().trim();
    } catch {
        throw new Error('Could not access this app identity’s MCP credential; no connection attempted');
    }
}
assert.ok(typeof token === 'string' && /^[A-Za-z0-9_-]{43}$/.test(token), 'A private MCP credential is required');
const exercise = process.argv.includes('--exercise-test-data');
const report = { endpoint: endpoint.href, authenticated: false, reconnect: false, rejectionChecks: [], tools: [], subtasksVerified: null, testDataRemoved: null };
const controller = new AbortController();
const timer = setTimeout(() => controller.abort(), 30_000);
let client;

async function connect() {
    const next = new Client({ name: 'attic-sdk-verification', version: '1.0.0' }, { capabilities: {} });
    await next.connect(new StreamableHTTPClientTransport(endpoint, {
        requestInit: { headers: { Authorization: `Bearer ${token}` } },
        fetch: (url, init) => fetch(url, { ...init, signal: controller.signal, redirect: 'error' })
    }));
    return next;
}

async function call(name, args = {}) {
    const result = await client.callTool({ name, arguments: args });
    assert.notEqual(result.isError, true, `${name} returned a tool error`);
    const text = result.content.find(item => item.type === 'text')?.text;
    assert.ok(text, `${name} did not return text content`);
    return JSON.parse(text);
}

try {
    for (const [name, credential, origin, expected] of [
        ['missing token', null, null, 401], ['wrong token', 'wrong', null, 401],
        ['old placeholder', 'attic-local-only-agent-disabled', null, 401],
        ['browser origin', token, 'https://example.com', 403]
    ]) {
        const headers = { 'Content-Type': 'application/json' };
        if (credential) headers.Authorization = `Bearer ${credential}`;
        if (origin) headers.Origin = origin;
        const response = await fetch(endpoint, {
            method: 'POST', headers, redirect: 'error', signal: controller.signal,
            body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/list' })
        });
        assert.equal(response.status, expected, `${name} rejection`);
        await response.arrayBuffer();
        report.rejectionChecks.push({ name, status: response.status });
    }
    client = await connect();
    report.authenticated = true;
    report.server = client.getServerVersion();
    const tools = await client.listTools();
    report.tools = tools.tools.map(tool => tool.name).sort();
    for (const name of ['list_tasks', 'create_task', 'update_task', 'delete_task', 'list_notes']) {
        assert.ok(report.tools.includes(name), `${name} missing`);
    }
    await call('list_tasks');
    await call('list_notes');

    if (exercise) {
        const title = `MCP verification ${randomUUID()}`;
        const created = await call('create_task', { title });
        const id = created.task?.id;
        assert.ok(id, 'Created test task must have an ID');
        let childID;
        try {
            const child = await call('create_task', { title: `${title} step`, parent_id: id });
            childID = child.task?.id;
            assert.ok(childID, 'Created test step must have an ID');
            assert.equal(child.task.parent_id, id);
            const prematureCompletion = await client.callTool({ name: 'update_task', arguments: { id, status: 'done' } });
            assert.equal(prematureCompletion.isError, true, 'Unfinished steps must prevent parent completion');
            await call('update_task', { id: childID, status: 'done' });
            const steps = await call('list_tasks', { parent_id: id });
            assert.equal(steps.count, 1);
            assert.equal(steps.tasks[0].id, childID);
            assert.equal(steps.tasks[0].status, 'done');
            const beforeCompletion = await call('list_tasks');
            assert.equal(beforeCompletion.tasks.find(task => task.id === id)?.status, 'todo');
            report.subtasksVerified = true;
            const updated = await call('update_task', { id, status: 'done' });
            assert.equal(updated.task?.status, 'done');
            // A separate SDK instance must reconnect and observe the change.
            await client.close();
            client = await connect();
            const listed = await call('list_tasks');
            assert.ok(listed.tasks.some(task => task.id === id && task.title === title && task.status === 'done'));
            assert.ok(listed.tasks.some(task => task.id === childID && task.parent_id === id && task.status === 'done'));
            report.reconnect = true;
        } finally {
            // Delete only the exact family created by this invocation, never user data.
            await call('delete_task', { id });
            const listed = await call('list_tasks');
            report.testDataRemoved = !listed.tasks.some(task => task.id === id || task.id === childID);
            assert.equal(report.testDataRemoved, true);
        }
    } else {
        await client.close();
        client = await connect();
        await call('list_tasks');
        report.reconnect = true;
    }
    console.log(JSON.stringify({ result: 'passed', ...report }, null, 2));
} catch (error) {
    // Never include raw SDK/network errors, which may contain request headers.
    console.error(JSON.stringify({ result: 'failed', stage: report.authenticated ? 'authenticated checks' : 'connection/authentication', errorType: error?.name ?? 'Error' }));
    process.exitCode = 1;
} finally {
    clearTimeout(timer);
    await client?.close();
}
