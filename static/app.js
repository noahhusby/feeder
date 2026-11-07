"use strict";

const camera = document.querySelector("#camera");
const cameraStatus = document.querySelector("#camera-status");
const feedholdButton = document.querySelector("#feedhold-button");
const controlStatus = document.querySelector("#control-status");

let pending = false;

function setStatus(message, kind = "") {
    controlStatus.textContent = message;
    controlStatus.className = `status ${kind}`.trim();
}

camera.addEventListener("error", () => {
    cameraStatus.textContent =
        "Camera unavailable. Reload the page to reconnect.";
});

camera.src = camera.dataset.src;

feedholdButton.disabled = false;

feedholdButton.addEventListener("click", async () => {
    if (pending) return;

    if (!window.confirm("Send a feedhold to the Shapeoko 5?")) {
        return;
    }

    pending = true;
    feedholdButton.disabled = true;
    setStatus("Sending feedhold…");

    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 8000);

    try {
        const response = await fetch("/api/feedhold", {
            method: "POST",
            headers: {
                "Content-Type": "application/json",
                "Accept": "application/json"
            },
            credentials: "same-origin",
            body: JSON.stringify({}),
            signal: controller.signal
        });

        const result = await response.json().catch(() => null);

        if (!response.ok || result?.ok !== true) {
            throw new Error(
                result?.error || "The server did not confirm the pulse."
            );
        }

        setStatus("Feedhold pulse sent.", "success");
    } catch (error) {
        setStatus(
            error.name === "AbortError"
                ? "Request timed out. Feedhold delivery is unconfirmed."
                : `Feedhold delivery unconfirmed. ${error.message}`,
            "error"
        );
    } finally {
        clearTimeout(timeout);
        pending = false;
        feedholdButton.disabled = false;
    }
});