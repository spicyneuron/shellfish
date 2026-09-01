// Browser tests for the session client. The page is loaded into a fresh realm
// over a DOM small enough to read: enough of an element to render a transcript,
// and stand-ins for the stream and the actions it posts. Tests drive it the way
// the service does, one frame at a time, and read back the page.
"use strict";

const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "ui.js"), "utf8");
const HEADER = {
  type: "session",
  format_version: 1,
  cwd: "/project",
  backend: { name: "test" },
  profile: { request: { model: "test-model" } },
  harness: {
    tools: [
      {
        name: "shell",
        manifest: {
          display: {
            summary: [],
            call: { content: ["$command"], format: "sh" },
            permission_preview: { content: ["$command"], format: "sh" },
            result: { content: ["$result_preview", "$exit_code"], format: "plain" },
          },
        },
      },
      {
        name: "read_file",
        manifest: {
          display: {
            summary: ["$file_path"],
            call: { content: [], format: "plain" },
            permission_preview: { content: ["$file_path"], format: "plain" },
            result: { content: ["$result_preview"], format: "plain" },
          },
        },
      },
      {
        name: "edit_file",
        manifest: {
          display: {
            summary: ["$file_path"],
            call: { content: [], format: "plain" },
            permission_preview: { content: ["$file_path"], format: "plain" },
            result: { content: ["$result_full"], format: "file_diff" },
          },
        },
      },
      { name: "fallback", manifest: {} },
    ],
  },
};
const ASSISTANT = {
  type: "message",
  role: "assistant",
  stop: "end",
  content: [{ type: "text", text: "committed" }],
  usage: { input_tokens: 10, output_tokens: 2 },
};

// ----------------------------------------------------------------------- DOM

class Element {
  constructor(tag) {
    this.tagName = tag;
    this.className = "";
    this.children = [];
    this.parent = null;
    this.own = "";
    this.listeners = new Map();
    this.scrollHeight = 0;
    this.scrollTop = 0;
    this.clientHeight = 0;
    this.disabled = false;
    this.style = {};
  }

  get textContent() {
    return this.own + this.children.map((child) => child.textContent).join("");
  }

  set textContent(value) {
    this.children = [];
    this.own = String(value);
  }

  get isConnected() {
    let node = this;
    while (node.parent) node = node.parent;
    return node.tagName === "body";
  }

  append(...nodes) {
    for (const node of nodes) {
      node.parent = this;
      this.children.push(node);
    }
  }

  remove() {
    if (!this.parent) return;
    this.parent.children = this.parent.children.filter((child) => child !== this);
    this.parent = null;
  }

  replaceChildren() {
    for (const child of this.children) child.parent = null;
    this.children = [];
  }

  setAttribute(name, value) {
    this[name] = value;
  }

  focus() {}

  requestSubmit() {
    this.dispatch("submit");
  }

  addEventListener(type, listener) {
    if (!this.listeners.has(type)) this.listeners.set(type, []);
    this.listeners.get(type).push(listener);
  }

  dispatch(type, event = {}) {
    for (const listener of this.listeners.get(type) || []) {
      listener({ preventDefault() {}, ...event });
    }
  }

  // Supports the descendant-by-class selectors the page uses.
  querySelectorAll(selector) {
    const classes = selector.split(" ").map((name) => name.slice(1));
    const matches = [];
    const walk = (node, depth) => {
      const hit = node.className.split(" ").includes(classes[depth]);
      const next = hit ? depth + 1 : depth;
      if (hit && next === classes.length) matches.push(node);
      else for (const child of node.children) walk(child, next);
    };
    for (const child of this.children) walk(child, 0);
    return matches;
  }
}

// find returns every element carrying a class, in document order.
function find(node, className) {
  return collect(node, (current) => current.className.split(" ").includes(className));
}

function findTag(node, tag) {
  return collect(node, (current) => current.tagName === tag);
}

function collect(node, matches) {
  const found = [];
  const walk = (current) => {
    if (matches(current)) found.push(current);
    for (const child of current.children) walk(child);
  };
  walk(node);
  return found;
}

// --------------------------------------------------------------------- page

// load runs the client over a fake DOM and service, and hands back the handles
// a test needs: the page's elements, the frames it can push, and the actions it
// has posted.
function load(savedCode, initialSessionStatus = 200) {
  const body = new Element("body");
  const elements = new Map();
  for (const id of ["output", "prompt", "code", "entry", "label", "model", "usage", "cancel", "detach"]) {
    const tag = id === "prompt" ? "form" : id === "code" ? "input" : id === "entry" ? "textarea" : "div";
    const element = new Element(tag);
    element.value = "";
    elements.set(id, element);
    body.append(element);
  }

  const encoder = new TextEncoder();
  const posts = [];
  const opens = [];
  const copied = [];
  const timers = [];
  const storage = new Map(savedCode === undefined ? [] : [["shellfish.access-code", savedCode]]);
  let reloads = 0;
  let queue = [];
  let waiting = [];
  const deliver = (chunk) => {
    if (waiting.length) waiting.shift()(chunk);
    else queue.push(chunk);
  };
  const reader = {
    read() {
      if (queue.length) return Promise.resolve(queue.shift());
      return new Promise((resolve) => waiting.push(resolve));
    },
  };
  // The status the next /session connection answers with.
  let sessionStatus = initialSessionStatus;
  let actionStatus = 204;

  const fetchStub = async (target, options = {}) => {
    const authorization = (options.headers || {}).Authorization;
    if (target === "/session") {
      opens.push(authorization);
      // A reopened stream starts from an empty queue, as a new connection does.
      queue = [];
      waiting = [];
      return {
        ok: sessionStatus === 200,
        status: sessionStatus,
        body: sessionStatus === 200 ? { getReader: () => reader } : null,
      };
    }
    const body = options.body === undefined ? undefined : JSON.parse(options.body);
    posts.push({ path: target, body, authorization });
    return { ok: actionStatus < 400, status: actionStatus };
  };

  const context = vm.createContext({
    document: {
      title: "",
      getElementById: (id) => elements.get(id),
      createElement: (tag) => new Element(tag),
      createTextNode: (text) => {
        const node = new Element("#text");
        node.textContent = text;
        return node;
      },
      addEventListener() {},
    },
    fetch: fetchStub,
    AbortController: class {
      abort() {}
    },
    TextDecoder,
    // Two tests make the page reload on purpose, and its own report of why is
    // noise here; the assertions cover what it did about it.
    console: { error() {} },
    setTimeout: (fn) => timers.push(fn),
    navigator: { clipboard: { writeText: async (text) => copied.push(text) } },
    sessionStorage: {
      getItem: (key) => storage.get(key) ?? null,
      setItem: (key, value) => storage.set(key, String(value)),
      removeItem: (key) => storage.delete(key),
    },
    window: { location: { reload: () => reloads++ } },
  });
  vm.runInContext(source, context);

  const waitFor = async (predicate, description) => {
    for (let i = 0; i < 50; i++) {
      await new Promise((resolve) => setImmediate(resolve));
      if (predicate()) return;
    }
    assert.fail(`timed out waiting for ${description}`);
  };
  const submit = (text) => {
    elements.get("entry").value = text;
    elements.get("prompt").dispatch("submit");
  };
  return {
    output: elements.get("output"),
    entry: elements.get("entry"),
    cancel: elements.get("cancel"),
    detach: elements.get("detach"),
    model: elements.get("model"),
    usage: elements.get("usage"),
    posts,
    opens,
    copied,
    waitFor,
    storage,
    get reloads() {
      return reloads;
    },
    submit,
    // The first submission is the access code, whatever it types after that is
    // a message.
    authenticate: async (code = "123456") => {
      elements.get("code").value = code;
      elements.get("prompt").dispatch("submit");
      await waitFor(() => waiting.length === 1, "session stream");
    },
    async send(...frames) {
      for (const frame of frames) {
        deliver({ done: false, value: encoder.encode("data: " + JSON.stringify(frame) + "\n\n") });
      }
      await waitFor(
        () => queue.length === 0 && (waiting.length === 1 || timers.length > 0),
        "frames to render",
      );
    },
    async endStream() {
      deliver({ done: true });
      await waitFor(() => timers.length > 0, "stream reconnect");
    },
    // Runs the reload the page scheduled, if it scheduled one.
    async reconnect() {
      const scheduled = timers.splice(0, timers.length);
      for (const timer of scheduled) timer();
      await waitFor(
        () => waiting.length === 1 || timers.length > 0,
        "session stream or reconnect",
      );
      return scheduled.length;
    },
    refuse(status) {
      sessionStatus = status;
    },
    failActions() {
      actionStatus = 409;
    },
  };
}

// A page that has replayed a session and is idle.
async function idle() {
  const page = load();
  await page.authenticate();
  await page.send(HEADER, { type: "state", working: false });
  return page;
}

// --------------------------------------------------------------------- tests

test("normalizes the access code", async () => {
  const page = load();
  await page.authenticate(" 12a3-456 ");
  assert.deepEqual(page.opens, ["Bearer 123456"]);
});

test("restores the tab's saved access code", async () => {
  const page = load("123456");
  await page.waitFor(() => page.opens.length === 1, "restored session stream");
  assert.deepEqual(page.opens, ["Bearer 123456"]);
});

test("forgets a restored access code the service rejects", async () => {
  const page = load("123456", 401);
  await page.waitFor(
    () => !page.storage.has("shellfish.access-code"),
    "rejected access code cleanup",
  );
  assert.equal(page.storage.has("shellfish.access-code"), false);
});

test("detaching forgets the saved access code and reloads", async () => {
  const page = load();
  await page.authenticate();
  page.detach.dispatch("click");
  assert.equal(page.storage.has("shellfish.access-code"), false);
  assert.equal(page.reloads, 1);
});

test("replays the durable session before live work", async () => {
  const page = load();
  await page.authenticate();
  assert.deepEqual(page.opens, ["Bearer 123456"]);
  await page.send(
    HEADER,
    { type: "system", content: "instructions" },
    {
      type: "message",
      role: "user",
      content: [{ type: "text", text: "**hello**" }],
    },
    { type: "state", working: false },
  );
  assert.deepEqual(
    find(page.output, "section").map((heading) => heading.textContent),
    ["system", "user1"],
  );
  assert.equal(find(page.output, "user").length, 1);
  assert.equal(find(page.output, "user")[0].textContent, "**hello**");
  assert.equal(findTag(find(page.output, "user")[0], "strong")[0].textContent, "**hello**");
  assert.equal(page.model.textContent, "test/test-model");
});

test("copies the latest or selected derived section locally", async () => {
  const page = await idle();
  await page.send(
    { type: "message", role: "user", content: [{ type: "text", text: "\n  question\t\n" }] },
    {
      ...ASSISTANT,
      stop: "tool_calls",
      content: [{ type: "tool_call", id: "copy_call", name: "shell", input: {} }],
    },
    {
      type: "message",
      role: "tool_result",
      call_id: "copy_call",
      name: "shell",
      content: "",
      exit_code: 0,
    },
    {
      ...ASSISTANT,
      content: [
        { type: "text", text: "\n" },
        { type: "text", text: "\tanswer" },
        { type: "text", text: "continued\n\n" },
      ],
    },
    { type: "state", working: false },
  );
  assert.equal(find(page.output, "user")[0].textContent, "  question\t");
  assert.equal(find(page.output, "assistant")[1].textContent, "\tanswercontinued");
  page.submit("/copy 1");
  await page.waitFor(() => page.copied.length === 1, "selected clipboard write");
  page.submit("/copy");
  await page.waitFor(() => page.copied.length === 2, "latest clipboard write");
  assert.deepEqual(page.copied, ["\n  question\t\n", "\n\n\n\tanswer\n\ncontinued\n\n"]);
  assert.equal(findTag(find(page.output, "note")[0], "h2")[0].textContent, "ℹCopied.");
  assert.equal(page.posts.length, 0);
});

test("labels context with its script, hook, and prompt", async () => {
  const page = await idle();
  await page.send({
    type: "context",
    hook: "session_start",
    script: "project_environment",
    prompt: "  project\n context ",
    status: 0,
    content: "environment",
  });
  const summary = findTag(find(page.output, "context")[0], "summary")[0];
  assert.equal(summary.textContent, "↪project_environment · session_start · project context");
});

test("puts prompt context under a user heading", async () => {
  const page = await idle();
  await page.send(
    { type: "state", working: true },
    {
      type: "context",
      hook: "user_prompt_submit",
      script: "add_context",
      content: "injected",
    },
    { type: "message", role: "user", content: [{ type: "text", text: "prompt" }] },
  );
  assert.deepEqual(
    find(page.output, "section").map((heading) => heading.textContent),
    ["user1", "agent2"],
  );
  assert.equal(find(page.output, "activity").length, 1);
});

test("decorates reasoning and tools like the terminal", async () => {
  const page = await idle();
  await page.send({
    ...ASSISTANT,
    stop: "tool_calls",
    content: [
      { type: "reasoning", text: "thinking" },
      {
        type: "tool_call",
        id: "call_1",
        name: "shell",
        input: { command: "if true; then pwd; fi" },
      },
      {
        type: "tool_call",
        id: "call_2",
        name: "read_file",
        input: {
          file_path: "outside.txt",
          request_sandbox_bypass: true,
          sandbox_bypass_reason: "outside project",
        },
      },
      {
        type: "tool_call",
        id: "call_3",
        name: "fallback",
        input: {
          value: 1,
          request_sandbox_bypass: true,
          sandbox_bypass_reason: "outside project",
        },
      },
    ],
  });
  assert.equal(findTag(find(page.output, "reasoning")[0], "summary")[0].textContent, "✎Reasoning");
  const calls = find(page.output, "call");
  assert.equal(findTag(calls[0], "summary")[0].textContent, "⛭shell");
  assert.equal(find(calls[0], "input")[0].textContent, "if true; then pwd; fi");
  assert.equal(find(calls[0], "word").length, 3);
  assert.equal(findTag(calls[1], "summary")[0].textContent, "⛭read_file · outside.txt · unsandboxed");
  assert.equal(find(calls[1], "input")[0].textContent, "");
  assert.equal(findTag(calls[2], "summary")[0].textContent, "⛭fallback · unsandboxed");
  assert.equal(find(calls[2], "input")[0].textContent, '{"value":1}');
});

test("leaves deltas out of the transcript and draws the record once", async () => {
  const page = await idle();
  await page.send(
    {
      type: "message",
      role: "user",
      content: [{ type: "text", text: "hello" }],
    },
    { type: "state", working: true },
  );
  assert.equal(find(page.output, "activity").length, 1);
  const drawn = page.output.children.length;

  // Transient deltas do not alter the durable transcript.
  await page.send(
    { type: "_assistant_delta", text: "", seq: 0 },
    { type: "_assistant_delta", text: "par", seq: 1 },
    { type: "_assistant_reasoning_delta", text: "thinking", seq: 2 },
    { type: "_assistant_delta", text: "tial", seq: 7 },
  );
  assert.equal(find(page.output, "assistant").length, 0);
  assert.equal(page.output.children.length, drawn);

  // The durable record is the only thing that draws the response.
  await page.send(ASSISTANT);
  const committed = find(page.output, "assistant");
  assert.equal(committed.length, 1);
  assert.equal(committed[0].textContent, "committed");
  assert.equal(find(page.output, "activity").length, 1);
  assert.equal(page.usage.textContent, " · 10 ↑ 2 ↓");
  await page.send({ ...ASSISTANT, content: [{ type: "text", text: "\n\n" }] });
  assert.equal(find(page.output, "assistant").length, 2);
  assert.equal(find(page.output, "assistant")[1].textContent, "");
  await page.send({ type: "state", working: false });
  assert.equal(find(page.output, "activity").length, 0);
});

test("does not strand a divider before a delayed user record", async () => {
  const page = await idle();
  const user = {
    type: "message",
    role: "user",
    content: [{ type: "text", text: "hello" }],
  };
  await page.send(user, { type: "state", working: true }, user);
  assert.deepEqual(
    find(page.output, "section").map((heading) => heading.textContent),
    ["user1", "agent2"],
  );
});

test("separates notice titles from their bodies", async () => {
  const page = await idle();
  await page.send(
    { type: "_hook_display", hook: "stop", script: "/tmp/\u0001check", text: "done" },
    { type: "_exec_error", message: "recoverable" },
  );
  const notes = find(page.output, "note");
  assert.equal(findTag(notes[0], "h2")[0].textContent, "ℹ\ufffdcheck · stop");
  assert.equal(findTag(findTag(notes[0], "h2")[0], "strong")[0].textContent, "\ufffdcheck");
  assert.equal(findTag(notes[0], "pre")[0].textContent, "done");
  assert.equal(findTag(notes[1], "h2")[0].textContent, "✕Turn failed");
  assert.equal(findTag(notes[1], "pre")[0].textContent, "recoverable");
});

test("labels actionable exec errors", async () => {
  const page = await idle();
  const errors = [
    [
      "provider request limit reached: 50",
      "Turn limit reached",
      "This turn reached the maximum of 50 provider requests.",
    ],
    ["openai: credentials rejected (HTTP 401)", "Authentication failed"],
    ["openai: credentials rejected (HTTP 401); no API key was supplied", "API key required"],
    [
      "codex: Codex credentials are unavailable; authenticate using Codex and retry",
      "Authentication required",
    ],
    ["openai: request timed out (curl status 28)", "Request timed out"],
    ["openai: could not connect to the provider (curl status 7)", "Provider connection failed"],
    ["openai: HTTP 429: slow down", "Provider rate limit reached"],
    ["openai: HTTP 400: bad request", "Provider request failed"],
    ["session is busy: /tmp/session.jsonl", "Session busy"],
    [
      "session working directory is unavailable: /tmp/gone",
      "Working directory unavailable",
    ],
    ["user_prompt_submit hook script halted without a handoff action", "Hook failed"],
  ];
  for (const [message, heading, body = message] of errors) {
    await page.send({ type: "_exec_error", message });
    const shown = find(page.output, "note").at(-1);
    assert.equal(findTag(findTag(shown, "h2")[0], "strong")[0].textContent, heading);
    assert.equal(findTag(shown, "pre")[0].textContent, body);
  }
});

test("reopens the stream when it ends", async () => {
  const page = await idle();
  await page.endStream();
  assert.equal(await page.reconnect(), 1);
  assert.equal(page.opens.length, 2);
});

test("retries a refused connection", async () => {
  const page = await idle();
  page.refuse(503);
  await page.endStream();
  assert.equal(await page.reconnect(), 1);
  assert.equal(page.opens.length, 2);
  assert.equal(await page.reconnect(), 1);
  assert.equal(page.opens.length, 3);
});

test("answers and removes permission prompts", async () => {
  for (const [decision, button, name, input, preview] of [
    ["approve", 0, "shell", { command: "ls", request_sandbox_bypass: true }, "ls"],
    [
      "deny",
      1,
      "read_file",
      { file_path: "outside.txt", request_sandbox_bypass: true },
      "outside.txt",
    ],
  ]) {
    const page = await idle();
    await page.send(
      { type: "state", working: true },
      {
        type: "message",
        role: "assistant",
        stop: "tool_calls",
        content: [
          {
            type: "tool_call",
            id: "call_1",
            name,
            input,
          },
        ],
      },
      {
        type: "_tool_permission_request",
        id: "permission_1",
        tool: { call_id: "call_1", name, input },
        reason: "not allowed by policy",
      },
    );
    const request = find(page.output, "permission")[0];
    assert.match(request.textContent, new RegExp("Run " + name + " outside of sandbox\\?"));
    assert.equal(find(request, "input")[0].textContent, preview);
    assert.match(request.textContent, /Reason: not allowed by policy/);
    assert.equal(find(request, "input")[0].tagName, "pre");
    assert.match(findTag(find(page.output, "call")[0], "summary")[0].textContent, /unsandboxed$/);
    assert.equal(page.cancel.hidden, false);

    find(page.output, "actions")[0].children[button].dispatch("click");
    await page.waitFor(() => page.posts.length === 1, "permission response");
    assert.deepEqual(page.posts, [
      {
        path: "/permission",
        body: { type: "_tool_permission_response", id: "permission_1", decision },
        authorization: "Bearer 123456",
      },
    ]);
    // The prompt is gone, so a second decision cannot be sent.
    assert.equal(find(page.output, "permission").length, 0);
  }
});

test("keeps a tool result together with its sandbox notice", async () => {
  const page = await idle();
  await page.send({ type: "state", working: true }, { type: "_backend_request_start" });
  assert.equal(page.cancel.hidden, false);
  await page.send({
    type: "message",
    role: "assistant",
    stop: "tool_calls",
    content: [
      {
        type: "tool_call",
        id: "call_1",
        name: "edit_file",
        input: { file_path: "notes.txt", old_string: "old", new_string: "new" },
      },
    ],
  });
  assert.equal(find(page.output, "call").length, 1);
  assert.equal(find(page.output, "activity").length, 1);
  assert.equal(page.cancel.hidden, false);

  await page.send({
    type: "message",
    role: "tool_result",
    call_id: "call_1",
    name: "edit_file",
    content: "@@ -1 +1 @@\n-old\n+new",
    exit_code: 0,
    sandbox_denial_detected: true,
  });
  const call = find(page.output, "call")[0];
  const result = find(call, "result");
  assert.equal(result.length, 1);
  assert.equal(result[0].tagName, "pre");
  assert.match(result[0].textContent, /\+new$/);
  assert.equal(find(result[0], "diff-removed").length, 1);
  assert.equal(find(result[0], "diff-added").length, 1);
  assert.equal(find(result[0], "notes")[0].textContent, "sandbox denial detected");
  assert.equal(find(page.output, "note").length, 0);
  assert.equal(find(page.output, "activity").length, 1);
  assert.equal(page.cancel.hidden, false);
});

test("serializes turn submissions", async () => {
  const page = await idle();
  page.entry.value = "do the thing";
  page.entry.dispatch("keydown", { key: "Enter", shiftKey: true });
  assert.equal(page.posts.length, 0);
  page.entry.value += "\nwith detail";
  page.entry.dispatch("keydown", { key: "Enter", shiftKey: false });
  await page.waitFor(() => page.posts.length === 1, "turn submission");
  assert.deepEqual(page.posts.map((post) => post.path), ["/turn"]);
  assert.deepEqual(page.posts[0].body, {
    type: "message",
    role: "user",
    content: [{ type: "text", text: "do the thing\nwith detail" }],
  });
  assert.equal(find(page.output, "activity").length, 1);
  await page.send({
    type: "message",
    role: "user",
    content: [{ type: "text", text: "do the thing\nwith detail" }],
  });
  assert.equal(find(page.output, "activity").length, 1);
  await page.send({ type: "_backend_request_start" });
  assert.equal(page.cancel.hidden, false);
  // A turn is running until a state frame says otherwise, so a second message
  // waits in the prompt rather than reaching the service.
  assert.equal(page.entry.disabled, false);
  page.submit("too soon");
  assert.equal(page.posts.length, 1);
  assert.equal(page.entry.value, "too soon");
});

test("cancels an active turn", async () => {
  const page = await idle();
  page.submit("do the thing");
  await page.waitFor(() => page.posts.length === 1, "turn submission");
  assert.equal(page.cancel.hidden, false);
  page.cancel.dispatch("click");
  await page.waitFor(() => page.posts.length === 2, "turn cancellation");
  assert.deepEqual(page.posts.map((post) => post.path), ["/turn", "/cancel"]);
  assert.equal(page.posts[1].body, undefined);

  await page.send({ type: "state", working: false });
  assert.equal(page.entry.disabled, false);
  assert.equal(page.cancel.hidden, true);
});

test("reopens the stream when an action is refused", async () => {
  const page = await idle();
  page.failActions();
  page.submit("go");
  await page.waitFor(() => page.posts.length === 1, "refused turn submission");
  assert.equal(await page.reconnect(), 1);
  assert.equal(page.opens.length, 2);
});

test("styles markdown without hiding its source", async () => {
  const page = await idle();
  await page.send({
    type: "message",
    role: "assistant",
    stop: "end",
    content: [
      {
        type: "text",
        text: [
          "## Heading",
          "",
          "A line with **bold**, *italic*, and `code`.",
          "The user_prompt_submit hook keeps its underscores; _italic_ works.",
          "",
          "- first",
          "- second",
          "",
          "> quoted",
          "",
          "```sh",
          "# comment",
          'echo "hello"',
          "```",
        ].join("\n"),
      },
    ],
  });
  const text = find(page.output, "text")[0];
  assert.equal(text.textContent, [
    "## Heading",
    "",
    "A line with **bold**, *italic*, and `code`.",
    "The user_prompt_submit hook keeps its underscores; _italic_ works.",
    "",
    "- first",
    "- second",
    "",
    "> quoted",
    "",
    "```sh",
    "# comment",
    'echo "hello"',
    "```",
  ].join("\n"));
  assert.equal(findTag(text, "strong")[0].textContent, "## Heading");
  assert.equal(findTag(text, "strong")[0].className, "heading");
  assert.equal(findTag(text, "strong")[1].textContent, "**bold**");
  assert.equal(findTag(text, "strong")[1].className, "");
  assert.equal(findTag(text, "em")[0].textContent, "*italic*");
  assert.equal(findTag(text, "em")[1].textContent, "_italic_");
  assert.equal(findTag(text, "em").length, 2);
  assert.equal(findTag(text, "code")[0].textContent, "`code`");
  assert.equal(find(text, "comment")[0].textContent, "# comment");
  assert.equal(find(text, "string")[0].textContent, '"hello"');
  assert.deepEqual(find(text, "fence").map((node) => node.textContent), ["```sh", "```"]);
});

test("leaves generated links inert", async () => {
  const page = await idle();
  await page.send({
    type: "message",
    role: "assistant",
    stop: "end",
    content: [
      { type: "text", text: "[docs](https://example.invalid) and [trap](javascript:steal())" },
    ],
  });
  const text = find(page.output, "text")[0];
  assert.equal(findTag(text, "a").length, 0);
  assert.equal(find(text, "link")[0].textContent, "[docs](https://example.invalid)");
  assert.equal(
    text.textContent,
    "[docs](https://example.invalid) and [trap](javascript:steal())",
  );
});

test("highlights representative language-family syntax", async () => {
  const page = await idle();
  const source = [
    "```typescript",
    "interface User { readonly name: string; count: 12 }",
    "```",
    "```python",
    'def greet():\n    """First line\n    second line."""',
    "```",
    "```yaml",
    "parent:\n  child-key: value\n# not: a key",
    "```",
  ].join("\n");
  await page.send({
    type: "message",
    role: "assistant",
    stop: "end",
    content: [{ type: "text", text: source }],
  });
  const text = find(page.output, "text")[0];
  assert.equal(text.textContent, source);
  assert.ok(find(text, "word").some((node) => node.textContent === "interface"));
  assert.ok(find(text, "tag").some((node) => node.textContent === "child-key"));
  assert.ok(find(text, "number").some((node) => node.textContent === "12"));
  assert.ok(find(text, "string").some((node) => node.textContent.includes("second line")));
  assert.ok(find(text, "comment").some((node) => node.textContent === "# not: a key"));
});

test("keeps HTML source readable and highlights quoted attributes", async () => {
  const page = await idle();
  const source = [
    "```html",
    "<strong>text</strong>",
    '<main id="content">text</main>',
    '<item name="a > b" />',
    "1 > 0",
    "```",
  ].join("\n");
  await page.send({
    type: "message",
    role: "assistant",
    stop: "end",
    content: [{ type: "text", text: source }],
  });
  const text = find(page.output, "text")[0];
  assert.equal(text.textContent, source);
  assert.equal(findTag(text, "main").length, 0);
  assert.ok(find(text, "tag").some((node) => node.textContent === "<main"));
  assert.ok(find(text, "string").some((node) => node.textContent === '"a > b"'));
});

test("leaves unknown fenced languages readable", async () => {
  const page = await idle();
  await page.send({
    type: "message",
    role: "assistant",
    stop: "end",
    content: [{ type: "text", text: "```constructor\nstill here\n```" }],
  });
  assert.equal(find(page.output, "text")[0].textContent, "```constructor\nstill here\n```");
});

test("reopens the stream on an unexpected frame", async () => {
  const page = await idle();
  await page.send({ type: "_invented" });
  assert.equal(await page.reconnect(), 1);
  assert.equal(page.opens.length, 2);
});
