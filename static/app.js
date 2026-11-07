"use strict";

const camera = document.querySelector("#camera");
const cameraStatus = document.querySelector("#camera-status");
const feedholdButton = document.querySelector("#feedhold-button");
const controlStatus = document.querySelector("#control-status");

const dialog = document.querySelector("#feedhold-dialog");
const cancelButton = document.querySelector("#cancel-feedhold");
const confirmButton = document.querySelector("#confirm-feedhold");

let pending = false;
let cameraRunning = false;

function setStatus(message, kind = "") {
    controlStatus.textContent = message;
    controlStatus.className = `status ${kind}`.trim();
}

function startCamera() {
    if (document.hidden || cameraRunning) return;

    cameraRunning = true;
    cameraStatus.textContent = "";

    const url = new URL(camera.dataset.src, window.location.href);
    url.searchParams.set("session", Date.now());
    camera.src = url.href;
}

function stopCamera() {
    cameraRunning = false;
    camera.removeAttribute("src");
    cameraStatus.textContent = "Camera paused.";
}

camera.addEventListener("error", () => {
    if (!cameraRunning) return;

    cameraStatus.textContent =
        "Camera unavailable. Reload the page to reconnect.";
});

document.addEventListener("visibilitychange", () => {
    if (document.hidden) {
        stopCamera();
    } else {
        startCamera();
    }
});

window.addEventListener("pagehide", stopCamera);
window.addEventListener("pageshow", startCamera);

feedholdButton.addEventListener("click", () => {
    if (!pending && !dialog.open) dialog.showModal();
});

cancelButton.addEventListener("click", () => dialog.close());

confirmButton.addEventListener("click", async () => {
    if (pending) return;

    pending = true;
    feedholdButton.disabled = true;
    confirmButton.disabled = true;
    dialog.close();

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
        confirmButton.disabled = false;
    }
});

feedholdButton.disabled = false;
startCamera();