#!/bin/bash
# Create the organizer's own small venv on the Spark (separate from the vLLM venv).
set -euo pipefail
VENV=${ORGANIZER_VENV:-$HOME/hack/organizer-venv}
INDEX=${PIP_INDEX_URL:-https://pypi.org/simple}
python3 -m venv "$VENV"
"$VENV/bin/pip" install -q -i "$INDEX" -U pip
"$VENV/bin/pip" install -q -i "$INDEX" "fastapi>=0.115" "uvicorn>=0.30" "pydantic>=2.8" "httpx>=0.27" "pyyaml>=6.0" "pytest>=8"
# the encrypted store (docs/PRIVACY.md): SQLCipher 4 bundled in the wheel (linux aarch64 / x86_64, macOS arm64)
"$VENV/bin/pip" install -q -i "$INDEX" "sqlcipher3-wheels>=0.5.7"
# file-read parsers (docs/FILE_READ.md) and their test-only fixture builders (pypdf, xlwt)
"$VENV/bin/pip" install -q -i "$INDEX" "defusedxml>=0.7.1" "openpyxl>=3.1" "xlrd>=2.0" "pypdfium2>=4.30" "pillow>=10.0" \
  "olefile>=0.46" "pypdf>=4" "xlwt>=1.3"
# shared spaces (docs/SPACES.md): Ed25519 verification of member signatures
"$VENV/bin/pip" install -q -i "$INDEX" "cryptography>=42"
"$VENV/bin/python" -c "import fastapi, uvicorn, pydantic, httpx, yaml; print('ok', fastapi.__version__, pydantic.__version__)"
"$VENV/bin/python" -c "import cryptography; print('cryptography', cryptography.__version__)"
"$VENV/bin/python" -c "from sqlcipher3 import dbapi2 as s; print('sqlcipher', s.connect(':memory:').execute('PRAGMA cipher_version').fetchone()[0])"
"$VENV/bin/python" -c "import defusedxml, openpyxl, xlrd, pypdfium2, PIL, olefile; print('file parsers ok')"
