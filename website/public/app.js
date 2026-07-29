const form = document.querySelector("#feedback-form");
const statusLine = document.querySelector("#form-status");
document.querySelector("#year").textContent = new Date().getFullYear();

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  const button = form.querySelector("button[type='submit']");
  const message = form.elements.message.value.trim();

  if (message.length < 10) {
    statusLine.textContent = "Расскажите чуть подробнее — хотя бы 10 символов.";
    statusLine.className = "form-status error";
    form.elements.message.focus();
    return;
  }

  button.disabled = true;
  button.querySelector("span").textContent = "Отправляем…";
  statusLine.textContent = "";

  try {
    const response = await fetch("/api/feedback", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        name: form.elements.name.value.trim(),
        contact: form.elements.contact.value.trim(),
        message,
        website: form.elements.website.value,
        source: "website",
      }),
    });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || "Не удалось отправить сообщение");

    form.reset();
    statusLine.textContent = "Спасибо! Сообщение уже у команды Talistra.";
    statusLine.className = "form-status";
  } catch (error) {
    statusLine.textContent = `${error.message}. Попробуйте ещё раз чуть позже.`;
    statusLine.className = "form-status error";
  } finally {
    button.disabled = false;
    button.querySelector("span").textContent = "Отправить";
  }
});
