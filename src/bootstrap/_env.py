"""Path derivation — mirrors env.sh semantics.

Every variable is resolved as ${VAR:-default}: an empty string is treated as
unset, matching the shell ${VAR:-default} convention.
"""
from __future__ import annotations

import os
import platform
from pathlib import Path


class Env:
    def __init__(self) -> None:
        u = platform.uname()
        self.ostype: str = u.system   # "Linux" | "Darwin"
        self.arch: str = u.machine    # "x86_64" | "aarch64" | "arm64"
        self.home: Path = Path.home()

        appdir = os.environ.get("__APPDIR") or ""
        self.local_root: Path = Path(
            os.environ.get("__LOCAL_ROOT")
            or (f"{appdir}/local" if appdir else "")
            or str(self.home / ".local")
        )
        self.xdg_data_home: Path = Path(
            os.environ.get("XDG_DATA_HOME") or str(self.local_root / "share")
        )
        self.xdg_config_home: Path = Path(
            os.environ.get("XDG_CONFIG_HOME") or str(self.home / ".config")
        )
        self.opt_root: Path = Path(
            os.environ.get("__OPT_ROOT")
            or str(self.local_root / "opt" / f"{self.ostype}-{self.arch}")
        )

    @property
    def envoy_dir(self) -> Path:
        return self.xdg_data_home / "envoy"

    @property
    def sman_snippets_dir(self) -> Path:
        return self.xdg_data_home / "sman" / "snippets"

    @property
    def navi_cheats_dir(self) -> Path:
        return self.xdg_data_home / "navi" / "cheats"
