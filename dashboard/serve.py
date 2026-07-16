"""Tombstoned at fastapi-cutover (T0.3). Use ``uvicorn dashboard.server.app:app``.

The 17 symbols ``routes/api.py`` used to import from this module live in
``dashboard/server/_serve_legacy.py``.
"""

import sys

sys.stderr.write("serve.py tombstoned — use uvicorn dashboard.server.app:app\n")
sys.exit(1)
