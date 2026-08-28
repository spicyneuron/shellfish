// A browser client for one served session.
//
// The session stream is the whole model: it replays the durable transcript,
// closes that replay with a state frame, and then carries live exec events.
// Reopening it is the only recovery, so this page keeps no state that a replay
// cannot rebuild and reloads whenever a frame surprises it.
//
// Every value below comes from a session an agent can influence, so it reaches
// the page as textContent. Nothing here builds markup from session content.
"use strict";

const output = document.getElementById("output");
const form = document.getElementById("prompt");
const codeEntry = document.getElementById("code");
const entry = document.getElementById("entry");
const label = document.getElementById("label");
const model = document.getElementById("model");
const usage = document.getElementById("usage");
const cancelButton = document.getElementById("cancel");
const detachButton = document.getElementById("detach");

const RELOAD_DELAY = 1000;
const FOLLOW_DISTANCE = 120;
const CODE_STORAGE_KEY = "shellfish.access-code";

// The access code, or null while the page is asking for one.
let code = null;
// Aborts the open session stream, and the generation a stream belongs to, so a
// superseded reader stops touching the page.
let reader = null;
let generation = 0;
// Whether a turn is running, as the last state frame reported it.
let working = false;
// Whether the backend is currently handling a request within the active turn.
let requesting = false;
// Set while an action is on its way to the service. Actions are serialized: the
// service answers about whatever is current, so overlapping them is meaningless.
let busy = false;
// The permission request waiting for a decision, by ID.
let pending = null;
// The working indicator standing in for a turn in progress, or null.
let indicator = null;
// The last transcript section shown, matching the terminal's grouped roles.
let lastRole = null;
// Tool calls waiting for their result, by call ID.
const calls = new Map();

// -------------------------------------------------------------------- the DOM

// Control characters are inert in a browser but still garble a transcript.
function safe(value) {
  return String(value === undefined || value === null ? "" : value).replace(
    /[\u0000-\u0008\u000b-\u001f\u007f-\u009f]/g,
    "\ufffd",
  );
}

function el(parent, tag, className, text) {
  const created = document.createElement(tag);
  if (className) created.className = className;
  if (text !== undefined) created.textContent = text;
  parent.append(created);
  return created;
}

// place shows a block and keeps a reader who is at the end of the transcript
// there, without moving one who has scrolled away.
function place(node) {
  const pinned =
    output.scrollHeight - output.scrollTop - output.clientHeight < FOLLOW_DISTANCE;
  if (!node.isConnected) output.append(node);
  if (pinned) output.scrollTop = output.scrollHeight;
}

function record(kind, heading) {
  const article = document.createElement("article");
  article.className = "record " + kind;
  if (heading) el(article, "h2", null, heading);
  return article;
}

function section(role) {
  if (lastRole === role) return null;
  lastRole = role;
  const heading = document.createElement("h2");
  heading.className = "section section-" + role;
  heading.textContent = role;
  place(heading);
  return heading;
}

function showIndicator() {
  if (indicator) return;
  const previousRole = lastRole;
  indicator = {
    article: record("activity", null),
    heading: lastRole === "user" ? section("agent") : null,
    previousRole,
  };
  const pulse = el(indicator.article, "pre");
  pulse.setAttribute("role", "img");
  pulse.setAttribute("aria-label", "working");
  place(indicator.article);
  refresh();
}

// The indicator stands between records, so it withdraws before anything is
// placed, taking any heading it introduced with it.
function hideIndicator() {
  if (!indicator) return;
  if (indicator.heading) {
    indicator.heading.remove();
    lastRole = indicator.previousRole;
  }
  indicator.article.remove();
  indicator = null;
}

function collapsible(parent, summary, text, kind, secondary) {
  const details = el(parent, "details", kind);
  const heading = el(details, "summary");
  if (secondary !== undefined) {
    el(heading, "strong", null, summary);
    heading.append(document.createTextNode(" " + secondary));
  } else {
    heading.textContent = summary;
  }
  el(details, "pre", null, safe(text));
}

function note(text, kind, heading) {
  hideIndicator();
  const article = record(kind ? "note " + kind : "note", heading ? safe(heading) : null);
  el(article, "pre", null, safe(text));
  place(article);
  if (working) showIndicator();
}

// A shell command is the whole of what a call does; anything else reads better
// as its own arguments.
function inputText(input) {
  if (input && typeof input.command === "string") return input.command;
  return JSON.stringify(input, null, 2);
}

// -------------------------------------------------------------------- markdown

const FENCE = /^ {0,3}(```+|~~~+)[ \t]*(\S*)/;
const LEADER = /^( {0,3})(#{1,6}|>|[-*+]|\d{1,9}[.)])(\s+)(.*)$/;
const INLINE =
  /(`+)([\s\S]*?)\1|(\[[^\]]+\]\([^\s)]+\))|(\*\*|__)([\s\S]+?)\4|([*_])([\s\S]+?)\6/;

// Markdown stays source text, as it does in the terminal. Recognized syntax is
// styled with elements, but no characters become markup or links.
function markdown(parent, text) {
  parent.replaceChildren();
  const lines = safe(text).split("\n");
  for (let index = 0; index < lines.length; index++) {
    const line = lines[index];
    const fence = FENCE.exec(line);
    if (fence) {
      markup(parent, line, "fence");
      if (index < lines.length - 1) parent.append(document.createTextNode("\n"));
      const code = [];
      while (++index < lines.length && !lines[index].trimStart().startsWith(fence[1])) {
        code.push(lines[index]);
      }
      highlight(parent, code.join("\n"), fence[2]);
      if (index < lines.length) {
        parent.append(document.createTextNode("\n"));
        markup(parent, lines[index], "fence");
      }
      if (index < lines.length - 1) parent.append(document.createTextNode("\n"));
      continue;
    }
    const leader = LEADER.exec(line);
    if (leader) {
      parent.append(document.createTextNode(leader[1]));
      const content = leader[2].startsWith("#") ? el(parent, "strong") : parent;
      markup(content, leader[2] + leader[3]);
      inline(content, leader[4]);
    } else {
      inline(parent, line);
    }
    if (index < lines.length - 1) parent.append(document.createTextNode("\n"));
  }
}

function markup(parent, text, kind) {
  el(parent, "span", kind ? "markup " + kind : "markup", text);
}

function inline(parent, text) {
  for (let match; (match = INLINE.exec(text)); ) {
    if (match.index) parent.append(document.createTextNode(text.slice(0, match.index)));
    if (match[3]) {
      el(parent, "span", "link", match[3]);
      text = text.slice(match.index + match[0].length);
      continue;
    }
    const delimiter = match[1] || match[4] || match[6];
    const content = match[2] ?? match[5] ?? match[7];
    const formatted = el(parent, match[1] ? "code" : match[4] ? "strong" : "em");
    markup(formatted, delimiter);
    inline(formatted, content);
    markup(formatted, delimiter);
    text = text.slice(match.index + match[0].length);
  }
  if (text) parent.append(document.createTextNode(text));
}

// ----------------------------------------------------------------- highlighting

// Enough of each language to tell code apart at a glance: what is a comment,
// what is text, and what the language itself reserves.
const LANGUAGES = {
  js: {
    comments: ["//.*", "/\\*[\\s\\S]*?\\*/"],
    quotes: "\"'`",
    words: "async|await|boolean|break|case|catch|class|const|continue|default|delete|do|else|enum|export|extends|false|finally|for|from|function|if|implements|import|in|instanceof|interface|let|new|null|number|of|private|protected|public|readonly|return|string|super|switch|this|throw|true|try|type|typeof|undefined|var|void|while|yield",
  },
  sh: {
    comments: ["#.*"],
    quotes: "\"'",
    words: "case|do|done|elif|else|esac|export|fi|for|function|if|in|local|return|then|until|while",
  },
  go: {
    comments: ["//.*", "/\\*[\\s\\S]*?\\*/"],
    quotes: "\"'`",
    words: "break|case|chan|const|continue|default|defer|else|fallthrough|false|for|func|go|goto|if|import|interface|map|nil|package|range|return|select|struct|switch|true|type|var",
  },
  python: {
    comments: ["#.*"],
    strings: ['"""[\\s\\S]*?"""'],
    quotes: "\"'",
    words: "and|as|assert|async|await|break|class|continue|def|del|elif|else|except|False|finally|for|from|global|if|import|in|is|lambda|None|nonlocal|not|or|pass|raise|return|True|try|while|with|yield",
  },
  json: { comments: ["//.*", "/\\*[\\s\\S]*?\\*/"], quotes: '"', words: "true|false|null" },
  yaml: {
    comments: ["#.*"],
    keys: "[A-Za-z0-9_.-]+",
    quotes: "\"'",
    words: "true|false|null",
  },
  css: { comments: ["/\\*[\\s\\S]*?\\*/"], quotes: "\"'" },
  html: {
    comments: ["<!--[\\s\\S]*?-->"],
    quotes: "\"'",
    tags: ["</[A-Za-z][\\w:-]*>", "</?[A-Za-z][\\w:-]*", "/?>"],
  },
};

const ALIASES = {
  javascript: "js", typescript: "js", ts: "js", jsx: "js", tsx: "js", node: "js",
  bash: "sh", zsh: "sh", shell: "sh", console: "sh", py: "python", yml: "yaml",
  jsonc: "json", xml: "html", svg: "html",
};

const patterns = new Map();

function pattern(name) {
  if (!patterns.has(name)) {
    const language = LANGUAGES[name];
    const quotes = (language.quotes || "").split("");
    patterns.set(
      name,
      new RegExp(
        [
          language.keys ? "^[ \\t]*(" + language.keys + ")(?=[ \\t]*:)" : null,
          ...language.comments,
          ...(language.strings || []),
          ...quotes.map((quote) => quote + "(?:\\\\.|[^" + quote + "\\\\])*" + quote),
          ...(language.tags || []),
          "\\b\\d[\\w.]*",
          language.words ? "\\b(?:" + language.words + ")\\b" : null,
        ]
          .filter(Boolean)
          .join("|"),
        "gm",
      ),
    );
  }
  return patterns.get(name);
}

function tokenKind(token, language) {
  if (language.quotes && language.quotes.includes(token[0])) return "string";
  if (/^\d/.test(token)) return "number";
  if (/^[A-Za-z_]/.test(token)) return "word";
  if (token.startsWith("<") && !token.startsWith("<!--")) return "tag";
  return "comment";
}

// highlight appends code with spans for the tokens it recognizes. An unknown
// language is still perfectly readable as text.
function highlight(parent, code, language) {
  const name = Object.hasOwn(ALIASES, language) ? ALIASES[language] : language;
  if (!Object.hasOwn(LANGUAGES, name)) {
    parent.append(document.createTextNode(code));
    return;
  }
  let last = 0;
  let tagOpen = false;
  for (const match of code.matchAll(pattern(name))) {
    const token = match[1] || match[0];
    const index = match.index + match[0].length - token.length;
    if (index > last) parent.append(document.createTextNode(code.slice(last, index)));
    let kind = match[1] ? "tag" : tokenKind(token, LANGUAGES[name]);
    if (name === "html") {
      if (token === ">" || token === "/>") {
        kind = tagOpen ? "tag" : null;
        tagOpen = false;
      } else if (kind === "tag") {
        tagOpen = !token.endsWith(">");
      }
    }
    if (kind) el(parent, "span", kind, token);
    else parent.append(document.createTextNode(token));
    last = index + token.length;
  }
  parent.append(document.createTextNode(code.slice(last)));
}

// ------------------------------------------------------------------- the frames

function apply(frame) {
  switch (frame.type) {
    case "session": {
      const name = safe(((frame.profile || {}).request || {}).model);
      const backend = safe((frame.backend || {}).name);
      model.textContent = backend ? backend + "/" + name : name;
      document.title = "shellfish " + safe(frame.cwd);
      return;
    }
    case "system":
      section("system");
      return renderCollapsed("system", "system prompt", frame.content);
    case "context":
      return renderCollapsed("context", frame.hook, frame.content, frame.tag);
    case "message":
      return renderMessage(frame);
    case "state":
      return applyState(frame);
    case "_backend_request_start":
      requesting = true;
      refresh();
      return showIndicator();
    case "_assistant_delta":
    case "_assistant_reasoning_delta":
      // Provisional output. Assistant text and reasoning are drawn only from
      // the record that commits them, which arrives on this same stream.
      return;
    case "_turn_usage":
      return showUsage(frame);
    case "_tool_permission_request":
      return askPermission(frame);
    case "_hook_display":
      return note(frame.text, null, frame.event + ": " + frame.hook);
    case "_exec_error":
      return note(frame.message, "error", "Exec error");
    case "_handoff":
      // A hook asked to replace the process, which only a terminal can honour.
      return note("the turn requested a handoff, which a served session cannot run", "error");
    default:
      throw new Error("unexpected frame: " + frame.type);
  }
}

// A prompt and its injected context are reference material: present, but folded
// away until a reader asks for them.
function renderCollapsed(kind, heading, content, secondary) {
  hideIndicator();
  const article = record(kind, null);
  const label = secondary === undefined ? undefined : safe(secondary);
  collapsible(article, safe(heading), content, null, label);
  place(article);
  if (working) showIndicator();
}

function renderMessage(frame) {
  if (frame.role === "user") {
    hideIndicator();
    section("user");
    const article = record("user", null);
    const text = (frame.content || [])
      .filter((part) => part.type === "text")
      .map((part) => part.text)
      .join("");
    markdown(el(article, "pre", "text"), text);
    place(article);
    if (working) showIndicator();
    return;
  }
  if (frame.role === "tool_result") return renderResult(frame);
  requesting = false;
  refresh();
  hideIndicator();
  section("agent");
  const article = record("assistant", null);
  for (const part of frame.content || []) {
    if (part.type === "reasoning") collapsible(article, "reasoning", part.text, "reasoning");
    else if (part.type === "text") markdown(el(article, "pre", "text"), part.text);
    else if (part.type === "tool_call") renderCall(article, part);
  }
  if (frame.usage) showUsage(frame.usage);
  place(article);
  if (working) showIndicator();
}

function renderCall(parent, call) {
  const details = el(parent, "details", "call");
  el(details, "summary", null, safe(call.name));
  // A shell command reads as the shell; anything else is its own arguments.
  const command = call.input && typeof call.input.command === "string";
  highlight(el(details, "pre", "input"), safe(inputText(call.input)), command ? "sh" : "json");
  calls.set(call.id, details);
}

// A result belongs to the call it names.
function renderResult(frame) {
  const call = calls.get(frame.call_id);
  if (!call) throw new Error("tool result has no call");
  hideIndicator();
  calls.delete(frame.call_id);
  const result = el(call, "div", frame.exit_code ? "result failed" : "result");
  if (frame.exit_code) el(result, "span", "exit", "exit " + frame.exit_code);
  el(result, "pre", null, safe(frame.content));
  place(call);
  if (working) showIndicator();
}

function applyState(frame) {
  working = frame.working === true;
  if (working) {
    showIndicator();
  } else {
    requesting = false;
    hideIndicator();
    clearPermission();
  }
  if (frame.error) note(frame.error, "error");
  refresh();
  if (!working) entry.focus();
}

function showUsage(tokens) {
  const cached =
    tokens.cached_tokens && tokens.input_tokens
      ? " " + Math.floor((tokens.cached_tokens * 100) / tokens.input_tokens) + "% ⦿"
      : "";
  usage.textContent = " · " + tokens.input_tokens + " ↑" + cached + " " + tokens.output_tokens + " ↓";
}

// ---------------------------------------------------------------- permissions

function askPermission(frame) {
  hideIndicator();
  pending = frame.id;
  const tool = frame.tool || {};
  const article = record("permission", "Run " + safe(tool.name) + " outside of sandbox?");
  el(article, "pre", "input", safe(inputText(tool.input)));
  if (frame.reason) el(article, "pre", "reason", "Reason: " + safe(frame.reason));
  const actions = el(article, "div", "actions");
  for (const decision of ["approve", "deny"]) {
    el(actions, "button", null, decision).addEventListener("click", () => {
      decide(decision, actions);
    });
  }
  place(article);
  if (working) showIndicator();
}

async function decide(decision, actions) {
  if (busy || pending === null) return;
  const id = pending;
  // One decision per request: the buttons go before the answer is in flight.
  actions.remove();
  pending = null;
  await act("/permission", { type: "_tool_permission_response", id, decision });
}

function clearPermission() {
  for (const actions of output.querySelectorAll(".permission .actions")) actions.remove();
  pending = null;
}

// ------------------------------------------------------------------ transport

// act sends one action and treats any answer but success as uncertainty, which
// the session stream settles by replaying what actually happened.
async function act(path, body) {
  busy = true;
  refresh();
  try {
    const response = await fetch(path, {
      method: "POST",
      headers: { Authorization: "Bearer " + code },
      body: JSON.stringify(body),
    });
    if (response.status === 401) {
      deauthenticate("access code rejected");
      return false;
    }
    if (!response.ok) {
      reload();
      return false;
    }
    return true;
  } catch {
    reload();
    return false;
  } finally {
    busy = false;
    refresh();
  }
}

// openStream replaces the page with the session as the service reports it.
async function openStream() {
  const mine = ++generation;
  const controller = new AbortController();
  reader = controller;
  let response;
  try {
    response = await fetch("/session", {
      headers: { Authorization: "Bearer " + code },
      signal: controller.signal,
    });
  } catch {
    return reload(mine);
  }
  if (mine !== generation) return;
  if (response.status === 401) return deauthenticate("access code rejected");
  // A refusal is temporary: another client is detaching, or the session is
  // settling behind the stream.
  if (!response.ok || !response.body) return reload(mine);

  reset();
  const decoder = new TextDecoder();
  const stream = response.body.getReader();
  let buffer = "";
  for (;;) {
    let chunk;
    try {
      chunk = await stream.read();
    } catch {
      return reload(mine);
    }
    if (mine !== generation) return;
    if (chunk.done) return reload(mine);
    buffer += decoder.decode(chunk.value, { stream: true });
    let end;
    while ((end = buffer.indexOf("\n\n")) >= 0) {
      const event = buffer.slice(0, end);
      buffer = buffer.slice(end + 2);
      const line = event.split("\n").find((text) => text.startsWith("data: "));
      if (!line) continue; // A keepalive, which carries no frame.
      try {
        apply(JSON.parse(line.slice(6)));
      } catch (failure) {
        console.error(failure);
        return reload(mine);
      }
    }
  }
}

// reload is the only recovery this page has: drop what was drawn and replay.
function reload(from) {
  if (from !== undefined && from !== generation) return;
  generation++;
  if (reader) reader.abort();
  reader = null;
  if (code === null) return;
  setTimeout(openStream, RELOAD_DELAY);
}

function reset() {
  output.replaceChildren();
  calls.clear();
  indicator = null;
  lastRole = null;
  pending = null;
  working = false;
  requesting = false;
  usage.textContent = "";
  refresh();
}

// ------------------------------------------------------------------ the page

function refresh() {
  cancelButton.hidden = !requesting;
  cancelButton.disabled = busy;
  detachButton.hidden = code === null;
}

function resizeEntry() {
  if (!entry.value) {
    entry.style.height = "";
    return;
  }
  entry.style.height = "auto";
  entry.style.height = entry.scrollHeight + "px";
}

function authenticate(value) {
  const provided = value.replace(/\D/g, "");
  if (!provided) {
    sessionStorage.removeItem(CODE_STORAGE_KEY);
    return;
  }
  code = provided;
  sessionStorage.setItem(CODE_STORAGE_KEY, code);
  codeEntry.hidden = true;
  entry.hidden = false;
  label.htmlFor = "entry";
  label.textContent = "❯";
  refresh();
  entry.focus();
  openStream();
}

function deauthenticate(reason) {
  generation++;
  if (reader) reader.abort();
  reader = null;
  code = null;
  sessionStorage.removeItem(CODE_STORAGE_KEY);
  reset();
  entry.hidden = true;
  codeEntry.hidden = false;
  codeEntry.value = "";
  label.htmlFor = "code";
  label.textContent = "access code";
  note(reason, "error");
  codeEntry.focus();
}

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  const value = code === null ? codeEntry.value : entry.value;
  if (code === null) {
    codeEntry.value = "";
    return authenticate(value);
  }
  // A message the service will not take stays in the box rather than vanishing.
  if (!value.trim() || busy || working) return;
  entry.value = "";
  resizeEntry();
  entry.focus();
  working = true;
  showIndicator();
  await act("/turn", {
    type: "message",
    role: "user",
    content: [{ type: "text", text: value }],
  });
});

entry.addEventListener("input", resizeEntry);

detachButton.addEventListener("click", () => {
  sessionStorage.removeItem(CODE_STORAGE_KEY);
  window.location.reload();
});

entry.addEventListener("keydown", (event) => {
  if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
    event.preventDefault();
    form.requestSubmit();
  }
});

cancelButton.addEventListener("click", () => {
  if (requesting && !busy) act("/cancel", {});
});

document.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && requesting && !busy) act("/cancel", {});
});

const savedCode = sessionStorage.getItem(CODE_STORAGE_KEY);
if (savedCode === null) {
  refresh();
  codeEntry.focus();
} else {
  authenticate(savedCode);
}
