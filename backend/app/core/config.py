import logging
import os
import sys

from pydantic_settings import BaseSettings

# Use stdlib logging directly here — get_logger imports from this module, so
# importing it back would create a cycle. The root JSON formatter is set up
# in app.core.logging.configure() at app startup.
_log = logging.getLogger(__name__)


class Settings(BaseSettings):
    PROJECT_NAME: str = "Voqora Backend"
    # Kept in lockstep with the public app version. The release preflight
    # verifies this runtime declaration and `pyproject.toml` against Xcode so
    # support logs and packaged components never report a stale product build.
    VERSION: str = "1.0.2"
    # Loopback only. The Swift client always connects via localhost; binding to
    # 0.0.0.0 would expose /speak and /audiobook to every device on the LAN
    # with no authentication. See HARD-004.
    HOST: str = "127.0.0.1"
    PORT: int = 10101

    # Caps the body size of /audiobook uploads so a huge file can't OOM the
    # backend. Enforced via stream-reading the upload. See HARD-017.
    MAX_AUDIOBOOK_UPLOAD_MB: int = 100

    # Kokoro emits 24 kHz mono. Hardcoded across services pre-HARD-035; now
    # centralized so any future model swap is a single edit.
    AUDIO_SAMPLE_RATE: int = 24000

    # Gate the /debug/state endpoint behind an env var so it's off in
    # production. Set DEBUG_ENDPOINTS=1 to enable. See HARD-070.
    DEBUG_ENDPOINTS: bool = False

    # Hard cap on the estimated Gemini cost per audiobook. Estimated values
    # above this are rejected at upload time so a user can't accidentally
    # run up a multi-dollar bill on a 2,000-page book. See HARD-072.
    MAX_GEMINI_COST_USD_PER_BOOK: float = 5.0

    # Paths
    BASE_DIR: str = os.path.dirname(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    )

    @property
    def RESOURCE_PATH(self) -> str:
        """Returns the path to resources, handling PyInstaller's temp folder."""
        if getattr(sys, "frozen", False):
            # Running inside PyInstaller bundle
            return sys._MEIPASS
        else:
            # Running locally
            return self.BASE_DIR

    @property
    def MODEL_PATH(self) -> str:
        return os.path.join(self.RESOURCE_PATH, "kokoro-v1.0.onnx")

    @property
    def ACTIVE_MODEL_PATH(self) -> str:
        """Returns INT8 quantized model if present, else falls back to FP32."""
        int8_path = self.MODEL_PATH.replace(".onnx", "-int8.onnx")
        if os.path.exists(int8_path):
            _log.info("config.using_int8_model", extra={"path": int8_path})
            return int8_path
        return self.MODEL_PATH

    @property
    def VOICES_PATH(self) -> str:
        return os.path.join(self.RESOURCE_PATH, "voices-v1.0.bin")

    @property
    def USER_DATA_DIR(self) -> str:
        """Writable user-data dir for audiobooks. Cleaned by `make nuke`."""
        return os.path.expanduser(
            "~/Library/Application Support/com.himudigonda.Voqora"
        )

    @property
    def AUDIOBOOKS_DIR(self) -> str:
        path = os.path.join(self.USER_DATA_DIR, "audiobooks")
        os.makedirs(path, exist_ok=True)
        return path


settings = Settings()
