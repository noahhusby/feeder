(() => {
    "use strict";

    function initialize() {
        const camera = document.querySelector("#camera");
        const cameraStatus = document.querySelector("#camera-status");
        const feedholdButton = document.querySelector("#feedhold-button");
        const releaseButton = document.querySelector("#release-button");
        const confirmation = document.querySelector("#confirmation");
        const cancelButton = document.querySelector("#cancel-button");
        const confirmButton = document.querySelector("#confirm-button");
        const controlStatus = document.querySelector("#control-status");

        const elements = {
            camera,
            cameraStatus,
            feedholdButton,
            releaseButton,
            confirmation,
            cancelButton,
            confirmButton,
            controlStatus
        };

        const missing = Object.entries(elements)
            .filter(([, element]) => !element)
            .map(([name]) => name);

        if (missing.length) {
            console.error("Feeder: missing HTML elements:", missing);
            return;
        }

        let pending = false;

        function setStatus(message, kind = "") {
            controlStatus.textContent = message;
            controlStatus.className = `status ${kind}`.trim();
        }

        function setBusy(busy) {
            pending = busy;
            feedholdButton.disabled = busy;
            releaseButton.disabled = busy;
            confirmButton.disabled = busy;
        }

        async function setFeedhold(active) {
            if (pending) return;

            setBusy(true);
            setStatus("Sending request…");

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
                    body: JSON.stringify({ active }),
                    signal: controller.signal
                });

                const result = await response.json().catch(() => null);

                if (!response.ok) {
                    throw new Error(
                        result?.error ||
                        `Server returned HTTP ${response.status}.`
                    );
                }

                if (!result || result.feedhold_active !== active) {
                    throw new Error(
                        "The server did not confirm the requested output. " +
                        "Check your connection and login."
                    );
                }

                setStatus(
                    active
                        ? "Feedhold output activated."
                        : "Feedhold input released. No Cycle Start was sent.",
                    "success"
                );
            } catch (error) {
                const message = error.name === "AbortError"
                    ? "The request timed out."
                    : error.message || "Connection failed.";

                // The server may have applied a command before connection loss.
                setStatus(
                    `Output state unconfirmed. ${message}`,
                    "error"
                );

                console.error("Feeder request failed:", error);
            } finally {
                clearTimeout(timeout);
                setBusy(false);
            }
        }

        feedholdButton.addEventListener("click", () => {
            if (pending) return;

            if (typeof confirmation.showModal === "function") {
                confirmation.showModal();
            } else if (window.confirm("Activate the Shapeoko 5 feedhold input?")) {
                setFeedhold(true);
            }
        });

        cancelButton.addEventListener("click", () => {
            confirmation.close();
        });

        confirmButton.addEventListener("click", () => {
            confirmation.close();
            setFeedhold(true);
        });

        releaseButton.addEventListener("click", () => {
            setFeedhold(false);
        });

        // MJPEG image events do not reliably detect a stalled stream.
        camera.addEventListener("error", () => {
            cameraStatus.textContent =
                "Camera unavailable. Reload the page to reconnect.";
        });

        camera.addEventListener("load", () => {
            cameraStatus.textContent = "Camera connected.";
        });

        // Attach event listeners before starting the camera request.
        camera.src = camera.dataset.src;

        setBusy(false);
    }

    if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", initialize, { once: true });
    } else {
        initialize();
    }
})();