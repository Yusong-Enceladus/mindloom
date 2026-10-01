// 收进织机 (Chrome, Manifest V3).
//
// Hands the selected text, the page link or a link on the page to 织机 on
// this Mac. The only way out is Chrome's native messaging: Chrome starts the
// small program that comes with 织机 (only for this extension's ID), which
// passes the request to the running App. There is no network path: the
// extension has no host permissions, never fetches anything, and its CSP
// forbids connections (connect-src 'none'). It stores nothing.
//
// The selection is read only when the owner clicks (activeTab).

"use strict";

const HOST = "com.bestasr.mindloom";
const MAX_CHARS = 1000000;
const MENU = {
  selection: "mindloom-selection",
  link: "mindloom-link",
  page: "mindloom-page",
};

const COPY = {
  title: "收进织机",
  noLink: "这个页面没有可以收进来的链接（只收 http、https 和本机文件的网页）",
  empty: "没有选中文字，也没有链接",
  tooLong: "选中的文字太长（超过 100 万字），请分几次收",
  notInstalled: "还没有连上织机：在织机的 设置 → 入口 里打开「Chrome 扩展」",
  forbidden: "织机的连接不认这个扩展：请在织机的 设置 → 入口 里重新连接 Chrome",
  exited: "织机的连接程序意外退出了，请再试一次",
  unreadable: "织机的回答看不懂",
};

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({
      id: MENU.selection,
      title: "收进织机：选中的文字",
      contexts: ["selection"],
    });
    chrome.contextMenus.create({
      id: MENU.link,
      title: "收进织机：这个链接",
      contexts: ["link"],
    });
    chrome.contextMenus.create({
      id: MENU.page,
      title: "收进织机：这个网页的链接",
      contexts: ["page"],
    });
  });
});

chrome.contextMenus.onClicked.addListener((info, tab) => {
  handleMenuClick(info, tab);
});

chrome.action.onClicked.addListener((tab) => {
  handleActionClick(tab);
});

// MARK: What to take

/** Only links a person can open later; never data: or browser pages. */
function linkOf(url) {
  return typeof url === "string" && /^(https?|file):/i.test(url) ? url : "";
}

function titleOf(tab) {
  return tab && typeof tab.title === "string" ? tab.title : "";
}

function selectionMessage(text, url, title) {
  if (typeof text !== "string" || !text.trim()) return { problem: COPY.empty };
  if (text.length > MAX_CHARS) return { problem: COPY.tooLong };
  return {
    type: "add",
    kind: "selection",
    text,
    url: linkOf(url) || undefined,
    title: title || undefined,
  };
}

function pageMessage(url, title) {
  const link = linkOf(url);
  if (!link) return { problem: COPY.noLink };
  return { type: "add", kind: "page", url: link, title: title || undefined };
}

function linkMessage(url, text) {
  const link = linkOf(url);
  if (!link) return { problem: COPY.noLink };
  return { type: "add", kind: "link", url: link, text: text || undefined };
}

/** The whole selection with its line breaks (the menu's selectionText
 *  flattens them). Possible only right after the owner's click. */
async function selectionIn(tabId, frameId) {
  if (typeof tabId !== "number" || tabId < 0) return "";
  const target = { tabId };
  if (typeof frameId === "number") target.frameIds = [frameId];
  try {
    const [first] = await chrome.scripting.executeScript({
      target,
      func: () => String(globalThis.getSelection ? getSelection() : ""),
    });
    return first && typeof first.result === "string" ? first.result : "";
  } catch {
    return "";
  }
}

// MARK: Clicks

async function handleMenuClick(info, tab) {
  switch (info && info.menuItemId) {
    case MENU.selection: {
      let text = await selectionIn(tab && tab.id, info.frameId);
      if (!text.trim()) text = typeof info.selectionText === "string" ? info.selectionText : "";
      return take(selectionMessage(text, info.pageUrl || (tab && tab.url), titleOf(tab)), tab);
    }
    case MENU.link:
      return take(linkMessage(info.linkUrl, info.selectionText), tab);
    case MENU.page:
      return take(pageMessage(info.pageUrl || (tab && tab.url), titleOf(tab)), tab);
    default:
      return null;
  }
}

/** The toolbar button: the selection if there is one, else the page link. */
async function handleActionClick(tab) {
  const text = await selectionIn(tab && tab.id);
  if (text.trim()) return take(selectionMessage(text, tab && tab.url, titleOf(tab)), tab);
  return take(pageMessage(tab && tab.url, titleOf(tab)), tab);
}

// MARK: Hand-over

async function take(message, tab) {
  const reply = message.problem ? { ok: false, reason: "local", message: message.problem } : await send(message);
  await show(reply, tab);
  return reply;
}

async function send(message) {
  try {
    const reply = await chrome.runtime.sendNativeMessage(HOST, message);
    if (reply && typeof reply.message === "string") {
      return { ok: reply.ok === true, reason: reply.reason, message: reply.message };
    }
    return { ok: false, reason: "unreadable", message: COPY.unreadable };
  } catch (error) {
    return { ok: false, reason: "host", message: hostProblem(String((error && error.message) || error)) };
  }
}

function hostProblem(text) {
  if (/not found/i.test(text)) return COPY.notInstalled;
  if (/forbidden/i.test(text)) return COPY.forbidden;
  if (/exited/i.test(text)) return COPY.exited;
  return "没能连上织机：" + text;
}

// MARK: Feedback

async function show(reply, tab) {
  const tabId = tab && typeof tab.id === "number" && tab.id >= 0 ? tab.id : undefined;
  // Per tab when there is one, else on the button itself.
  const where = tabId === undefined ? {} : { tabId };
  try {
    await chrome.action.setBadgeBackgroundColor({ color: reply.ok ? "#2E7D32" : "#C62828", ...where });
    await chrome.action.setBadgeText({ text: reply.ok ? "✓" : "!", ...where });
    await chrome.action.setTitle({ title: reply.message, ...where });
  } catch {
    // The tab went away.
  }
  if (tabId !== undefined) {
    try {
      await chrome.scripting.executeScript({ target: { tabId }, func: toast, args: [reply.message, reply.ok] });
    } catch {
      // Pages the extension may not touch (chrome://…) keep only the badge.
    }
  }
  setTimeout(() => {
    chrome.action.setBadgeText({ text: "", ...where }).catch(() => {});
    chrome.action.setTitle({ title: COPY.title, ...where }).catch(() => {});
  }, 4000);
}

/** Runs in the page: a small note in the corner, gone after three seconds. */
function toast(message, ok) {
  const id = "mindloom-take-note";
  const old = document.getElementById(id);
  if (old) old.remove();
  const host = document.createElement("div");
  host.id = id;
  const root = host.attachShadow({ mode: "closed" });
  const box = document.createElement("div");
  box.setAttribute("role", "status");
  box.textContent = message;
  box.style.cssText = [
    "position:fixed",
    "z-index:2147483647",
    "right:16px",
    "bottom:16px",
    "max-width:360px",
    "padding:10px 14px",
    "border-radius:10px",
    "font:13px/1.45 -apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif",
    "color:#fff",
    "box-shadow:0 4px 16px rgba(0,0,0,.25)",
    "background:" + (ok ? "#1f6f43" : "#9b2c2c"),
  ].join(";");
  root.appendChild(box);
  (document.body || document.documentElement).appendChild(host);
  setTimeout(() => host.remove(), 3200);
}

// For the end-to-end test, which drives these from the service worker.
globalThis.mindloom = { handleMenuClick, handleActionClick, take, send };
