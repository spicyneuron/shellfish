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
    this.focusCount = 0;
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

  focus() {
    this.focusCount++;
  }

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
    posts.push({ path: target, body: JSON.parse(options.body), authorization });
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
    sessionStorage: {
      getItem: (key) => storage.get(key) ?? null,
      setItem: (key, value) => storage.set(key, String(value)),
      removeItem: (key) => storage.delete(key),
    },
    window: { location: { reload: () => reloads++ } },
  });
  vm.runInContext(source, context);

  // A frame can await a fetch whose answer schedules more work, so settling
  // takes several turns of the event loop rather than one.
  const settle = async () => {
    for (let i = 0; i < 4; i++) await new Promise((resolve) => setImmediate(resolve));
  };
  const submit = async (text) => {
    elements.get("entry").value = text;
    elements.get("prompt").dispatch("submit");
    await settle();
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
    settle,
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
      await settle();
    },
    async send(...frames) {
      for (const frame of frames) {
        deliver({ done: false, value: encoder.encode("data: " + JSON.stringify(frame) + "\n\n") });
      }
      await settle();
    },
    async endStream() {
      deliver({ done: true });
      await settle();
    },
    // Runs the reload the page scheduled, if it scheduled one.
    async reconnect() {
      const scheduled = timers.splice(0, timers.length);
      for (const timer of scheduled) timer();
      await settle();
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
  await page.settle();
  assert.deepEqual(page.opens, ["Bearer 123456"]);
});

test("forgets a restored access code the service rejects", async () => {
  const page = load("123456", 401);
  await page.settle();
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
    ["system", "user"],
  );
  assert.equal(find(page.output, "user").length, 1);
  assert.equal(find(page.output, "user")[0].textContent, "**hello**");
  assert.equal(findTag(find(page.output, "user")[0], "strong")[0].textContent, "**hello**");
  assert.equal(page.model.textContent, "test/test-model");
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

  // Deltas of either kind, at any sequence, neither create nor mutate a node.
  await page.send(
    { type: "_assistant_delta", text: "", seq: 0 },
    { type: "_assistant_delta", text: "par", seq: 1 },
    { type: "_assistant_reasoning_delta", text: "thinking", seq: 2 },
    { type: "_assistant_delta", text: "tial", seq: 7 },
  );
  assert.equal(find(page.output, "assistant").length, 0);
  assert.equal(find(page.output, "text").length, 1); // The user record, alone.
  assert.equal(findTag(page.output, "details").length, 0);
  assert.equal(find(page.output, "activity").length, 1);
  assert.equal(page.output.children.length, drawn);

  // The durable record is the only thing that draws the response.
  await page.send(ASSISTANT);
  const committed = find(page.output, "assistant");
  assert.equal(committed.length, 1);
  assert.equal(committed[0].textContent, "committed");
  assert.equal(find(page.output, "section").length, 2);
  assert.equal(find(page.output, "section")[1].textContent, "agent");
  assert.equal(find(page.output, "activity").length, 1);
  assert.equal(page.usage.textContent, "10 ↑ 2 ↓");
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
    ["user", "agent"],
  );
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

test("answers the pending permission request once", async () => {
  const page = await idle();
  await page.send(
    { type: "state", working: true },
    {
      type: "_tool_permission_request",
      id: "permission_1",
      tool: { name: "shell", input: { command: "ls" } },
      reason: "not allowed by policy",
    },
  );
  const request = find(page.output, "permission")[0];
  assert.match(request.textContent, /permission · shell/);
  assert.match(request.textContent, /ls/);
  assert.match(request.textContent, /not allowed by policy/);

  const [approve] = find(page.output, "actions")[0].children;
  approve.dispatch("click");
  await page.settle();
  assert.deepEqual(page.posts, [
    {
      path: "/permission",
      body: { type: "_tool_permission_response", id: "permission_1", decision: "approve" },
      authorization: "Bearer 123456",
    },
  ]);
  // The buttons are gone, so a second decision cannot be sent.
  assert.equal(find(page.output, "actions").length, 0);
});

test("keeps a tool call and its result together", async () => {
  const page = await idle();
  await page.send({ type: "state", working: true });
  await page.send({
    type: "message",
    role: "assistant",
    stop: "tool_calls",
    content: [{ type: "tool_call", id: "call_1", name: "shell", input: { command: "pwd" } }],
  });
  assert.equal(find(page.output, "call").length, 1);
  assert.equal(find(page.output, "activity").length, 1);

  await page.send({
    type: "message",
    role: "tool_result",
    call_id: "call_1",
    name: "shell",
    content: "/project",
    exit_code: 0,
  });
  const call = find(page.output, "call")[0];
  assert.equal(find(call, "result").length, 1);
  assert.equal(call.textContent, "shellpwd/project");
  assert.equal(find(page.output, "activity").length, 1);
});

test("serializes turns and cancellation", async () => {
  const page = await idle();
  const focused = page.entry.focusCount;
  page.entry.value = "do the thing";
  page.entry.scrollHeight = 42;
  page.entry.dispatch("input");
  assert.equal(page.entry.style.height, "42px");
  page.entry.dispatch("keydown", { key: "Enter", shiftKey: true });
  await page.settle();
  assert.equal(page.posts.length, 0);
  page.entry.value += "\nwith detail";
  page.entry.dispatch("keydown", { key: "Enter", shiftKey: false });
  await page.settle();
  assert.ok(page.entry.focusCount > focused);
  assert.deepEqual(page.posts.map((post) => post.path), ["/turn"]);
  assert.deepEqual(page.posts[0].body, {
    type: "message",
    role: "user",
    content: [{ type: "text", text: "do the thing\nwith detail" }],
  });
  assert.equal(page.entry.style.height, "");
  assert.equal(find(page.output, "activity").length, 1);
  await page.send({
    type: "message",
    role: "user",
    content: [{ type: "text", text: "do the thing\nwith detail" }],
  });
  assert.equal(find(page.output, "activity").length, 1);
  // A turn is running until a state frame says otherwise, so a second message
  // waits in the prompt rather than reaching the service.
  assert.equal(page.entry.disabled, false);
  await page.submit("too soon");
  assert.equal(page.posts.length, 1);
  assert.equal(page.entry.value, "too soon");

  page.cancel.dispatch("click");
  await page.settle();
  assert.deepEqual(page.posts.map((post) => post.path), ["/turn", "/cancel"]);

  await page.send({ type: "state", working: false });
  assert.equal(page.entry.disabled, false);
  assert.equal(page.cancel.hidden, true);
});

test("reopens the stream when an action is refused", async () => {
  const page = await idle();
  page.failActions();
  await page.submit("go");
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
  assert.equal(findTag(text, "strong")[0].textContent, "**bold**");
  assert.equal(findTag(text, "em")[0].textContent, "*italic*");
  assert.equal(findTag(text, "code")[0].textContent, "`code`");
  assert.equal(find(text, "comment")[0].textContent, "# comment");
  assert.equal(find(text, "string")[0].textContent, '"hello"');
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
