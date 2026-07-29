"""AudiobookStore — filesystem layout + SQLite-backed metadata.

Layout under {AUDIOBOOKS_DIR}/{book_id}/:
  source.pdf
  cover.jpg
  pages/{n:03d}.txt             raw extracted
  pages/{n:03d}.clean.txt       LLM-cleaned
  audio_pages/{n:03d}.wav       per-page TTS (resumability granularity)
  audio.wav                     final concatenated
  transcript.json               sections + page→time map (Phase 2)

Metadata lives in {AUDIOBOOKS_DIR}/audiobooks.db (SQLite). One row per book
in the `books` table. The dict-shaped `read_meta` / `write_meta` API is
preserved so callers don't have to change. Per-book file presence remains
the resumability checkpoint — DB is for queryable summary fields only.

Migration: on startup, any legacy `meta.json` files are imported into the
DB and the JSON files are removed. See `_migrate_legacy_meta_files`.
"""

import asyncio
import json
import os
import shutil
import sqlite3
import threading
import time
import uuid
from pathlib import Path
from typing import Any

from app.core.config import settings
from app.core.logging import get_logger

log = get_logger(__name__)


def _now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


# Columns we hoist out of the JSON blob for indexed queries. Everything else
# (sections, page_to_time, estimated, actual, phase_progress, failed_pages,
# error) lives inside the JSON `meta` column for schema flexibility.
_INDEXED_COLUMNS = (
    "book_id",
    "title",
    "created_at",
    "page_count",
    "status",
    "total_audio_seconds",
    "engine",
    "voice",
    "speed",
)


class AudiobookStore:
    """Filesystem layout + SQLite metadata."""

    # Per-book locks so concurrent meta updates don't clobber each other.
    _meta_locks: dict[str, asyncio.Lock] = {}
    # Single connection guarded by a thread lock; SQLite serialises writes.
    _conn: sqlite3.Connection | None = None
    _conn_lock = threading.Lock()

    # ---------- DB lifecycle ----------

    @classmethod
    def _connection(cls) -> sqlite3.Connection:
        with cls._conn_lock:
            if cls._conn is None:
                db_path = os.path.join(cls.root_dir(), "audiobooks.db")
                conn = sqlite3.connect(
                    db_path, check_same_thread=False, isolation_level=None
                )
                conn.execute("PRAGMA journal_mode=WAL")
                conn.execute("PRAGMA foreign_keys=ON")
                conn.row_factory = sqlite3.Row
                cls._conn = conn
                cls._init_schema(conn)
                cls._migrate_legacy_meta_files(conn)
            return cls._conn

    @classmethod
    def _init_schema(cls, conn: sqlite3.Connection) -> None:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS books (
                book_id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                created_at TEXT NOT NULL,
                page_count INTEGER NOT NULL DEFAULT 0,
                status TEXT NOT NULL DEFAULT 'ready',
                total_audio_seconds REAL NOT NULL DEFAULT 0,
                engine TEXT NOT NULL DEFAULT 'kokoro',
                voice TEXT NOT NULL DEFAULT 'af_bella',
                speed REAL NOT NULL DEFAULT 1.0,
                meta_json TEXT NOT NULL
            )
            """)
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_books_created_at ON books(created_at DESC)"
        )
        conn.execute("CREATE INDEX IF NOT EXISTS idx_books_status ON books(status)")

    @classmethod
    def _migrate_legacy_meta_files(cls, conn: sqlite3.Connection) -> None:
        """Walk the audiobooks dir; import any meta.json found into SQLite,
        then delete the file. Idempotent — second run is a no-op."""
        try:
            for entry in os.listdir(cls.root_dir()):
                bdir = os.path.join(cls.root_dir(), entry)
                if not os.path.isdir(bdir):
                    continue
                legacy = os.path.join(bdir, "meta.json")
                if not os.path.exists(legacy):
                    continue
                try:
                    with open(legacy, encoding="utf-8") as f:
                        meta = json.load(f)
                    cls._upsert_row(conn, meta)
                    os.remove(legacy)
                    log.info("store.legacy_meta_migrated", extra={"book_id": entry})
                except (OSError, json.JSONDecodeError) as e:
                    log.warning(
                        "store.bad_legacy_meta",
                        extra={"book_id": entry, "error": str(e)},
                    )
        except FileNotFoundError:
            pass

    @staticmethod
    def _meta_to_row(meta: dict[str, Any]) -> dict[str, Any]:
        """Pull the indexed columns out of meta + serialise the rest as JSON."""
        return {
            "book_id": meta.get("book_id"),
            "title": meta.get("title", ""),
            "created_at": meta.get("created_at", _now_iso()),
            "page_count": int(meta.get("page_count") or 0),
            "status": meta.get("status", "ready"),
            "total_audio_seconds": float(meta.get("total_audio_seconds") or 0),
            "engine": meta.get("engine", "kokoro"),
            "voice": meta.get("voice", "af_bella"),
            "speed": float(meta.get("speed") or 1.0),
            "meta_json": json.dumps(meta, ensure_ascii=False),
        }

    @staticmethod
    def _row_to_meta(row: sqlite3.Row) -> dict[str, Any]:
        try:
            return json.loads(row["meta_json"])
        except (json.JSONDecodeError, KeyError):
            # Fall back to indexed columns only.
            return {col: row[col] for col in _INDEXED_COLUMNS if col in row.keys()}

    @classmethod
    def _upsert_row(cls, conn: sqlite3.Connection, meta: dict[str, Any]) -> None:
        row = cls._meta_to_row(meta)
        conn.execute(
            """
            INSERT INTO books (book_id, title, created_at, page_count, status,
                               total_audio_seconds, engine, voice, speed, meta_json)
            VALUES (:book_id, :title, :created_at, :page_count, :status,
                    :total_audio_seconds, :engine, :voice, :speed, :meta_json)
            ON CONFLICT(book_id) DO UPDATE SET
                title=excluded.title,
                page_count=excluded.page_count,
                status=excluded.status,
                total_audio_seconds=excluded.total_audio_seconds,
                engine=excluded.engine,
                voice=excluded.voice,
                speed=excluded.speed,
                meta_json=excluded.meta_json
            """,
            row,
        )

    # ---------- paths (unchanged) ----------

    @classmethod
    def root_dir(cls) -> str:
        return settings.AUDIOBOOKS_DIR

    @classmethod
    def book_dir(cls, book_id: str) -> str:
        return os.path.join(cls.root_dir(), book_id)

    @classmethod
    def source_file_path(cls, book_id: str, ext: str) -> str:
        """Return the path for the uploaded source file with the given extension."""
        return os.path.join(cls.book_dir(book_id), f"source.{ext}")

    @classmethod
    def pdf_path(cls, book_id: str) -> str:
        return cls.source_file_path(book_id, "pdf")

    @classmethod
    def cover_path(cls, book_id: str) -> str:
        return os.path.join(cls.book_dir(book_id), "cover.jpg")

    @classmethod
    def transcript_path(cls, book_id: str) -> str:
        return os.path.join(cls.book_dir(book_id), "transcript.json")

    @classmethod
    def audio_path(cls, book_id: str) -> str:
        return os.path.join(cls.book_dir(book_id), "audio.wav")

    @classmethod
    def page_raw_path(cls, book_id: str, n: int) -> str:
        return os.path.join(cls.book_dir(book_id), "pages", f"{n:03d}.txt")

    @classmethod
    def page_clean_path(cls, book_id: str, n: int) -> str:
        return os.path.join(cls.book_dir(book_id), "pages", f"{n:03d}.clean.txt")

    @classmethod
    def page_audio_path(cls, book_id: str, n: int) -> str:
        return os.path.join(cls.book_dir(book_id), "audio_pages", f"{n:03d}.wav")

    # ---------- create ----------

    @classmethod
    def create_book(cls, title: str) -> str:
        """Allocate a fresh book_id and create the dir tree. No DB row yet."""
        # Touch the connection to ensure schema is up before any write.
        cls._connection()
        book_id = uuid.uuid4().hex
        bdir = cls.book_dir(book_id)
        os.makedirs(os.path.join(bdir, "pages"), exist_ok=True)
        os.makedirs(os.path.join(bdir, "audio_pages"), exist_ok=True)
        return book_id

    @classmethod
    def save_source(cls, book_id: str, content: bytes, ext: str) -> None:
        """Save any source file type under source.{ext}."""
        Path(cls.source_file_path(book_id, ext)).write_bytes(content)

    # ---------- meta (SQLite-backed) ----------

    @classmethod
    def _lock(cls, book_id: str) -> asyncio.Lock:
        lock = cls._meta_locks.get(book_id)
        if lock is None:
            lock = asyncio.Lock()
            cls._meta_locks[book_id] = lock
        return lock

    @classmethod
    def read_meta(cls, book_id: str) -> dict[str, Any] | None:
        conn = cls._connection()
        with cls._conn_lock:
            row = conn.execute(
                "SELECT * FROM books WHERE book_id = ?", (book_id,)
            ).fetchone()
        if row is None:
            return None
        return cls._row_to_meta(row)

    @classmethod
    def write_meta(cls, book_id: str, meta: dict[str, Any]) -> None:
        """Atomic upsert. SQLite (WAL mode) handles concurrency."""
        meta = dict(meta)  # shallow copy so caller mutations don't bleed
        meta["book_id"] = book_id
        conn = cls._connection()
        with cls._conn_lock:
            cls._upsert_row(conn, meta)

    @classmethod
    async def update_meta(cls, book_id: str, **patch: Any) -> dict[str, Any]:
        """Read-modify-write under per-book asyncio.Lock + DB transaction."""
        async with cls._lock(book_id):
            meta = cls.read_meta(book_id) or {}
            meta.update(patch)
            cls.write_meta(book_id, meta)
            return meta

    @classmethod
    def initial_meta(
        cls,
        book_id: str,
        title: str,
        page_count: int,
        engine: str,
        voice: str,
        speed: float,
        estimated: dict[str, Any],
    ) -> dict[str, Any]:
        return {
            "book_id": book_id,
            "title": title,
            "created_at": _now_iso(),
            "page_count": page_count,
            "status": "ready",
            "phase_progress": {"page_done": 0, "page_total": page_count},
            "sections": [],
            "page_to_time": {},
            "total_audio_seconds": 0.0,
            "failed_pages": [],
            "estimated": estimated,
            "actual": None,
            "engine": engine,
            "voice": voice,
            "speed": speed,
            "error": None,
        }

    # ---------- list / delete ----------

    @classmethod
    def list_books(cls) -> list[dict[str, Any]]:
        """Summary list, ordered by created_at desc, indexed by SQLite."""
        conn = cls._connection()
        with cls._conn_lock:
            rows = conn.execute(
                "SELECT * FROM books ORDER BY created_at DESC"
            ).fetchall()
        return [cls._row_to_meta(r) for r in rows]

    @classmethod
    def delete_book(cls, book_id: str) -> bool:
        bdir = cls.book_dir(book_id)
        existed = os.path.isdir(bdir)
        if existed:
            shutil.rmtree(bdir, ignore_errors=True)
        conn = cls._connection()
        with cls._conn_lock:
            cur = conn.execute("DELETE FROM books WHERE book_id = ?", (book_id,))
            db_existed = cur.rowcount > 0
        cls._meta_locks.pop(book_id, None)
        return existed or db_existed

    # ---------- test helpers ----------

    @classmethod
    def _reset_for_tests(cls) -> None:
        """Close the DB connection so a new test fixture's tmp dir takes
        effect on next access. Tests use a per-test AUDIOBOOKS_DIR via
        monkeypatch — without this reset, the singleton connection points
        at the wrong DB."""
        with cls._conn_lock:
            if cls._conn is not None:
                try:
                    cls._conn.close()
                except sqlite3.Error:
                    pass
                cls._conn = None
        cls._meta_locks.clear()
