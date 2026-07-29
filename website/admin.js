const login = document.querySelector("#login");
const dashboard = document.querySelector("#dashboard");
const messages = document.querySelector("#messages");
const filter = document.querySelector("#filter");
let items = [];

const api = async (path = "", options = {}) => {
  const response = await fetch(`./api${path}`, {
    ...options,
    headers: { "Content-Type": "application/json", "X-Talistra-Request": "admin", ...(options.headers || {}) },
  });
  if (response.status === 401) throw new Error("unauthorized");
  const body = await response.json();
  if (!response.ok) throw new Error(body.error || "Ошибка сервера");
  return body;
};

const escapeHtml = (text) => {
  const node = document.createElement("div");
  node.textContent = text || "";
  return node.innerHTML;
};

const render = () => {
  document.querySelector("#count-new").textContent = items.filter((x) => x.status === "new").length;
  document.querySelector("#count-read").textContent = items.filter((x) => x.status === "read").length;
  document.querySelector("#count-resolved").textContent = items.filter((x) => x.status === "resolved").length;
  document.querySelector("#total").textContent = `Всего сообщений: ${items.length}`;
  const visible = filter.value ? items.filter((x) => x.status === filter.value) : items;
  if (!visible.length) {
    messages.innerHTML = '<div class="empty">Здесь пока нет сообщений.</div>';
    return;
  }
  messages.innerHTML = visible.map((item) => `
    <article class="${item.status}">
      <div class="meta">
        <b>#${item.id}</b>
        <span>${escapeHtml(item.created_at)}</span>
        <span>Источник: ${escapeHtml(item.source)}</span>
        <span>${item.name ? `Имя: ${escapeHtml(item.name)}` : "Анонимно"}</span>
      </div>
      <div class="message">${escapeHtml(item.message)}</div>
      ${item.contact ? `<span class="contact">Ответить: ${escapeHtml(item.contact)}</span>` : ""}
      <div class="actions">
        <button data-id="${item.id}" data-status="new">Новое</button>
        <button data-id="${item.id}" data-status="read">В работу</button>
        <button data-id="${item.id}" data-status="resolved">Готово</button>
        <button class="danger" data-id="${item.id}" data-delete="true">Удалить</button>
      </div>
    </article>`).join("");
};

const load = async () => {
  try {
    const result = await api("/messages");
    items = result.messages;
    login.hidden = true;
    dashboard.hidden = false;
    render();
  } catch (error) {
    if (error.message !== "unauthorized") alert(error.message);
    login.hidden = false;
    dashboard.hidden = true;
  }
};

document.querySelector("#login-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const errorLine = document.querySelector("#login-error");
  errorLine.textContent = "";
  try {
    await api("/login", {
      method: "POST",
      body: JSON.stringify({ password: event.target.elements.password.value }),
    });
    event.target.reset();
    await load();
  } catch (_) {
    errorLine.textContent = "Неверный пароль.";
  }
});

document.querySelector("#logout").addEventListener("click", async () => {
  await api("/logout", { method: "POST", body: "{}" });
  items = [];
  login.hidden = false;
  dashboard.hidden = true;
});

filter.addEventListener("change", render);
messages.addEventListener("click", async (event) => {
  const button = event.target.closest("button[data-id]");
  if (!button) return;
  const id = Number(button.dataset.id);
  if (button.dataset.delete) {
    if (!confirm(`Удалить сообщение #${id}?`)) return;
    await api(`/messages/${id}`, { method: "DELETE" });
    items = items.filter((x) => x.id !== id);
  } else {
    const status = button.dataset.status;
    await api(`/messages/${id}`, { method: "PATCH", body: JSON.stringify({ status }) });
    items = items.map((x) => x.id === id ? { ...x, status } : x);
  }
  render();
});

load();
