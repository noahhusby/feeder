# cnc_server.py
import atexit
import logging
import threading
import time

import cv2
from flask import Flask, Response, request, render_template
from gpiozero import OutputDevice


class CNCServer:
    def __init__(
        self,
        feedhold_pin=17,       # BCM numbering
        feedhold_active_high=True,
        camera_device=0,
        width=1280,
        height=720,
        fps=30,
        jpeg_quality=85,
    ):
        self.app = Flask(__name__)
        self.app.config["MAX_CONTENT_LENGTH"] = 1024

        self._stop = threading.Event()
        self._frame_ready = threading.Condition()
        self._gpio_lock = threading.Lock()
        self._jpeg = None
        self._sequence = 0

        self._feedhold = OutputDevice(
            feedhold_pin,
            active_high=feedhold_active_high,
            initial_value=False,
        )

        self._camera = cv2.VideoCapture(camera_device, cv2.CAP_V4L2)

        if not self._camera.isOpened():
            self._camera.release()
            self._feedhold.close()
            raise RuntimeError("Could not open webcam")

        self._camera.set(
            cv2.CAP_PROP_FOURCC,
            cv2.VideoWriter_fourcc(*"MJPG"),
        )
        self._camera.set(cv2.CAP_PROP_FRAME_WIDTH, width)
        self._camera.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
        self._camera.set(cv2.CAP_PROP_FPS, fps)

        self._encode_options = [
            cv2.IMWRITE_JPEG_QUALITY,
            jpeg_quality,
        ]
        self.app.add_url_rule("/", view_func=self.index, methods=["GET"])
        self.app.add_url_rule(
            "/camera", view_func=self.camera_stream, methods=["GET"]
        )
        self.app.add_url_rule(
            "/api/feedhold", view_func=self.set_feedhold, methods=["POST"]
        )

        self._thread = threading.Thread(
            target=self._capture_loop,
            name="camera",
            daemon=True,
        )
        self._thread.start()
        atexit.register(self.close)

    def _capture_loop(self):
        """Only this thread reads from the camera."""
        try:
            while not self._stop.is_set():
                success, frame = self._camera.read()

                if not success:
                    logging.warning("Camera read failed; retrying")
                    with self._frame_ready:
                        self._jpeg = None
                        self._frame_ready.notify_all()
                    self._stop.wait(0.25)
                    continue

                success, encoded = cv2.imencode(
                    ".jpg", frame, self._encode_options
                )
                if not success:
                    continue

                with self._frame_ready:
                    self._jpeg = encoded.tobytes()
                    self._sequence += 1
                    self._frame_ready.notify_all()
        finally:
            self._camera.release()
            self._stop.set()
            with self._frame_ready:
                self._frame_ready.notify_all()

    def _video_frames(self):
        last_sequence = -1

        while not self._stop.is_set():
            with self._frame_ready:
                ready = self._frame_ready.wait_for(
                    lambda: self._stop.is_set()
                    or (
                        self._jpeg is not None
                        and self._sequence != last_sequence
                    ),
                    timeout=5,
                )

                if self._stop.is_set():
                    return

                if not ready:
                    continue

                jpeg = self._jpeg
                last_sequence = self._sequence

            # Release the lock before sending to a potentially slow client.
            yield (
                b"--frame\r\n"
                b"Content-Type: image/jpeg\r\n"
                b"Content-Length: "
                + str(len(jpeg)).encode()
                + b"\r\n\r\n"
                + jpeg
                + b"\r\n"
            )

    def camera_stream(self):
        with self._frame_ready:
            available = self._frame_ready.wait_for(
                lambda: self._jpeg is not None or self._stop.is_set(),
                timeout=3,
            )
            if not available or self._stop.is_set():
                return {"error": "Camera unavailable"}, 503

        return Response(
            self._video_frames(),
            content_type="multipart/x-mixed-replace; boundary=frame",
            headers={
                "Cache-Control": "no-store",
                "X-Accel-Buffering": "no",
            },
        )

    def set_feedhold(self):
        with self._gpio_lock:
            if self._stop.is_set():
                return {"error": "Server shutting down"}, 503

            try:
                self._feedhold.on()
                time.sleep(0.2)
            finally:
                self._feedhold.off()

        return {"ok": True}

    def close(self):
        with self._gpio_lock:
            if self._stop.is_set() and self._feedhold.closed:
                return

            self._stop.set()
            if not self._feedhold.closed:
                self._feedhold.close()

        with self._frame_ready:
            self._frame_ready.notify_all()

        self._thread.join(timeout=3)

    def index(self):
        return render_template("index.html")


server = CNCServer(
    feedhold_pin=4,
    feedhold_active_high=True,
)
app = server.app