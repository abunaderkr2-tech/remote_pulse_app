
import asyncio
import base64
import json
import os
import threading
import time
import customtkinter as ctk
import websockets

SAVE_DIR = "downloaded_images"
os.makedirs(SAVE_DIR, exist_ok=True)

SERVER_URL = "wss://remote-pulse-server.onrender.com/ws/desktop/my_device_123"


class PulseStudioApp(ctk.CTk):

    def __init__(self):
        super().__init__()

        self.title("Remote Pulse Studio v5.0 - Ultimate Synchronizer")
        self.geometry("820x720")
        ctk.set_appearance_mode("dark")

        self.ws = None
        self.loop = None
        self.total_saved = 0
        self.last_mobile_ping = 0
        self.start_time = time.time()

        self.server_connected = False
        self.mobile_connected = False
        self.blink_state = False

        self._build_ui()

        threading.Thread(target=self._update_timer_loop, daemon=True).start()
        threading.Thread(target=self._led_blink_loop, daemon=True).start()
        threading.Thread(target=self._health_check_loop, daemon=True).start()
        threading.Thread(target=self.start_asyncio_loop, daemon=True).start()

    def _build_ui(self):
        # Header Section
        self.header_frame = ctk.CTkFrame(self, corner_radius=15, fg_color="#1E293B")
        self.header_frame.pack(fill="x", padx=20, pady=15)

        self.title_label = ctk.CTkLabel(
            self.header_frame,
            text="⚡ Remote Pulse Sync Center",
            font=ctk.CTkFont(size=22, weight="bold"),
            text_color="#F8FAFC",
        )
        self.title_label.pack(side="left", padx=20, pady=20)

        # LED Indicators
        self.status_box = ctk.CTkFrame(self.header_frame, fg_color="transparent")
        self.status_box.pack(side="right", padx=20)

        self.server_frame = ctk.CTkFrame(self.status_box, fg_color="transparent")
        self.server_frame.pack(anchor="e", pady=3)
        self.server_lbl = ctk.CTkLabel(self.server_frame, text="Server: ", font=ctk.CTkFont(size=12, weight="bold"))
        self.server_lbl.pack(side="left")
        self.server_light = ctk.CTkFrame(self.server_frame, width=14, height=14, corner_radius=7, fg_color="#EF4444")
        self.server_light.pack(side="right")

        self.mobile_frame = ctk.CTkFrame(self.status_box, fg_color="transparent")
        self.mobile_frame.pack(anchor="e", pady=3)
        self.mobile_lbl = ctk.CTkLabel(self.mobile_frame, text="Phone: ", font=ctk.CTkFont(size=12, weight="bold"))
        self.mobile_lbl.pack(side="left")
        self.mobile_light = ctk.CTkFrame(self.mobile_frame, width=14, height=14, corner_radius=7, fg_color="#EF4444")
        self.mobile_light.pack(side="right")

        # Live Info
        self.info_frame = ctk.CTkFrame(self, fg_color="transparent")
        self.info_frame.pack(fill="x", padx=20, pady=5)

        self.timer_label = ctk.CTkLabel(
            self.info_frame,
            text="⏱️ Runtime: 00:00:00",
            font=ctk.CTkFont(family="Consolas", size=13),
            text_color="#94A3B8",
        )
        self.timer_label.pack(side="left")

        self.stats_label = ctk.CTkLabel(
            self.info_frame,
            text="📁 Saved Photos: 0",
            font=ctk.CTkFont(size=13, weight="bold"),
            text_color="#38BDF8",
        )
        self.stats_label.pack(side="right")

        # Controls
        self.control_frame = ctk.CTkFrame(self, fg_color="transparent")
        self.control_frame.pack(fill="x", padx=20, pady=10)

        self.fetch_btn = ctk.CTkButton(
            self.control_frame,
            text="📥 Start Ultra-Fast Photo Sync",
            font=ctk.CTkFont(size=15, weight="bold"),
            fg_color="#10B981",
            hover_color="#059669",
            height=48,
            command=self.trigger_fetch,
        )
        self.fetch_btn.pack(side="left", expand=True, fill="x")

        # Progress Spinner
        self.spinner = ctk.CTkProgressBar(self, height=8, mode="indeterminate", progress_color="#38BDF8")
        self.spinner.pack(fill="x", padx=20, pady=5)

        # Log Terminal
        self.log_textbox = ctk.CTkTextbox(
            self, font=ctk.CTkFont(family="Consolas", size=12), fg_color="#0F172A", text_color="#E2E8F0"
        )
        self.log_textbox.pack(fill="both", expand=True, padx=20, pady=15)

        self.log("🚀 Sync Center Ready. Optimized with In-Memory Compression.")

    def log(self, message):
        self.log_textbox.insert("end", f"[{time.strftime('%H:%M:%S')}] {message}\n")
        self.log_textbox.see("end")

    def _update_timer_loop(self):
        while True:
            elapsed = int(time.time() - self.start_time)
            hrs, rem = divmod(elapsed, 3600)
            mins, secs = divmod(rem, 60)
            self.timer_label.configure(text=f"⏱️ Runtime: {hrs:02d}:{mins:02d}:{secs:02d}")
            time.sleep(1)

    def _led_blink_loop(self):
        while True:
            self.blink_state = not self.blink_state

            if self.server_connected:
                color = "#10B981" if self.blink_state else "#047857"
                self.server_light.configure(fg_color=color)
            else:
                self.server_light.configure(fg_color="#EF4444")

            if self.mobile_connected:
                color = "#10B981" if self.blink_state else "#047857"
                self.mobile_light.configure(fg_color=color)
            else:
                self.mobile_light.configure(fg_color="#EF4444")

            time.sleep(0.5)

    def _health_check_loop(self):
        while True:
            time.sleep(1)
            self.mobile_connected = (time.time() - self.last_mobile_ping < 6)

    def get_existing_files(self):
        return os.listdir(SAVE_DIR) if os.path.exists(SAVE_DIR) else []

    def start_asyncio_loop(self):
        self.loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self.loop)
        self.loop.run_until_complete(self.connect_websocket())

    async def connect_websocket(self):
        while True:
            try:
                async with websockets.connect(
                    SERVER_URL,
                    max_size=None,
                    max_queue=None,
                    ping_interval=20,
                    ping_timeout=20,
                ) as websocket:
                    self.ws = websocket
                    self.server_connected = True
                    self.log("🌐 WebSockets Connected.")

                    async for message in websocket:
                        await self.handle_message(message)
            except Exception:
                self.ws = None
                self.server_connected = False
                await asyncio.sleep(3)

    async def handle_message(self, message_str):
        try:
            data = json.loads(message_str)
            msg_type = data.get("type")

            if data.get("action") == "PING" or msg_type == "PING":
                self.last_mobile_ping = time.time()

            elif msg_type == "NEW_IMAGE_DATA":
                self.last_mobile_ping = time.time()
                self.spinner.start()

                file_name = data.get("file_name", "image.jpg")
                base64_data = data.get("data", "")

                if base64_data:
                    image_bytes = base64.b64decode(base64_data)
                    file_path = os.path.join(SAVE_DIR, file_name)

                    with open(file_path, "wb") as f:
                        f.write(image_bytes)

                    self.total_saved += 1
                    self.stats_label.configure(text=f"📁 Saved Photos: {self.total_saved}")
                    
                    size_kb = round(len(image_bytes) / 1024, 1)
                    self.log(f"⚡ Fast Saved: {file_name} ({size_kb} KB)")

                    # إرسال تأكيد الحفظ (ACK) للجوال
                    if self.ws:
                        await self.ws.send(json.dumps({"type": "ACK_SAVED"}))

                self.spinner.stop()

        except Exception as e:
            self.log(f"❌ Error: {e}")

    def trigger_fetch(self):
        if self.ws and self.loop:
            existing_files = self.get_existing_files()
            self.spinner.start()
            self.log(f"📡 Request sent. Ignored {len(existing_files)} existing items.")

            payload = {
                "action": "FETCH_ALL_IMAGES",
                "existing_files": existing_files,
            }
            asyncio.run_coroutine_threadsafe(self.ws.send(json.dumps(payload)), self.loop)
        else:
            self.log("⚠️ Offline from Server.")


if __name__ == "__main__":
    app = PulseStudioApp()
    app.mainloop()
