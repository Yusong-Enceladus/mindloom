"""Spark-side organizer: turns intake items into flat "events" with Agent Skills.

Runs on the user's own DGX Spark, on a private Unix socket reached from the Mac over an SSH tunnel.
Its store is encrypted (SQLCipher) with a key that only the Mac holds and sends at unlock; masked text only;
image and file bytes are deleted once read. Item content is never rewritten, only purged when the user
deletes it; model output is stored as proposals and never overwrites source evidence or explicit user
decisions (docs/PRIVACY.md).
"""

__version__ = "0.1.0"
