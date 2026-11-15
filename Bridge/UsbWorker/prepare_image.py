"""Download/cache only; never opens a phone. Isolated so cancellation stays responsive."""
import sys
from pathlib import Path

from packaging.version import Version
from pymobiledevice3.common import get_home_folder
from pymobiledevice3.services.mobile_image_mounter import (
    _developer_disk_image_path,
    _download_developer_disk_image,
    fetch_personalized_ddi,
)


def prepare(kind, version):
    if kind == "legacy":
        v = Version(version)
        selected = f"{v.major}.{v.minor}"
        path = _developer_disk_image_path(Path("/Applications/Xcode.app"), selected)
        if not path.exists():
            path = _developer_disk_image_path(get_home_folder() / "Xcode.app", selected)
        signature = path.with_name(path.name + ".signature")
        if not path.exists() or not signature.exists():
            _download_developer_disk_image(selected, path, signature)
    elif kind == "cryptex":
        from pymobiledevice3.services.cryptexd import fetch_cryptex_ddi
        fetch_cryptex_ddi()
    elif kind == "personalized":
        fetch_personalized_ddi()
    else:
        raise ValueError("Unknown image kind")


if __name__ == "__main__":
    prepare(sys.argv[1], sys.argv[2])
