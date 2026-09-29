# Persistence migration fixtures

\`schema-fixture.json\` is the committed, content-free contract for the generated
SQLite N-1 and current schemas. Tests create fresh databases from the exact-pinned
GRDB migrator, compare the applied migration IDs and table set to this manifest,
and insert only stable synthetic UUIDs.

Binary SQLite files are generated in a unique temporary directory so WAL/SHM
sidecars and machine-specific page state are never committed. The interruption
fixture throws inside the current migration transaction and verifies that the
N-1 source plus byte-verified pre-migration backup remain recoverable.
