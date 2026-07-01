/*
 * Browser action popup controller.
 *
 * The popup is the fast pairing surface shown by left-clicking the extension
 * icon. It shares storage and API code with the full Options page.
 */

(async function () {
  const form = document.querySelector("#popup-form");
  const portInput = document.querySelector("#port");
  const tokenInput = document.querySelector("#token");
  const testButton = document.querySelector("#test");
  const openOptionsButton = document.querySelector("#open-options");
  const status = document.querySelector("#status");

  const config = await StarcatCompanion.loadConfig();
  portInput.value = String(config.port);
  tokenInput.value = config.token;

  function setStatus(message, tone = "") {
    status.textContent = message;
    if (tone) {
      status.dataset.tone = tone;
    } else {
      delete status.dataset.tone;
    }
  }

  function formConfig() {
    return {
      port: portInput.value,
      token: tokenInput.value
    };
  }

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    await StarcatCompanion.saveConfig(formConfig());
    setStatus("Saved.", "success");
  });

  testButton.addEventListener("click", async () => {
    testButton.disabled = true;
    setStatus("Testing connection...");
    try {
      const current = formConfig();
      await StarcatCompanion.saveConfig(current);
      const client = StarcatCompanion.createClient(current);
      const pong = await client.ping();
      setStatus(`Connected to ${pong.app || "Starcat"}.`, "success");
    } catch (error) {
      setStatus(`Connection failed: ${error.message}`, "error");
    } finally {
      testButton.disabled = false;
    }
  });

  openOptionsButton.addEventListener("click", () => {
    chrome.runtime.openOptionsPage();
  });
})();
