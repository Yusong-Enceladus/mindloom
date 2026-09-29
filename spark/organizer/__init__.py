"""Spark-side organizer: turns intake items into flat "events" with Agent Skills.

Runs on the user's own DGX Spark, bound to 127.0.0.1, reached from the Mac over an
SSH tunnel. Source items are append-only; model output is stored as proposals and
never overwrites source evidence or explicit user decisions.
"""

__version__ = "0.1.0"
