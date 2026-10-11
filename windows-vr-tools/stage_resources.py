#!/usr/bin/env python3
"""Stage Wine builtin resources only; never launch Wine or guest executables."""
import argparse
from pathlib import Path
import shutil
import tarfile

ROOT = Path(__file__).resolve().parents[1]
WINE_TOOLS = {"wineboot.exe", "services.exe", "winedevice.exe", "explorer.exe", "conhost.exe", "rundll32.exe", "start.exe", "plugplay.exe", "rpcss.exe", "winecfg.exe"}
FORBIDDEN = ("steamclient", "codex", "test", "probe", "canary", "hello", "triangle", "cube", "thumper")

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=ROOT / "runtime-source/app/Madeira")
    parser.add_argument("--output", type=Path, default=ROOT / "visionos-windows-vr/Resources/Runtime")
    parser.add_argument("--guest-stage", type=Path, required=True,
                        help="Combined WindowsVR/Guest staging tree from the OpenComposite and OpenXR Windows builds")
    args = parser.parse_args()
    source, output = args.source.resolve(), args.output.resolve()
    guest_root = args.guest_stage.resolve() / "WindowsVR"
    guest_output = output.parent / "WindowsVR"
    if guest_output.exists():
        raise SystemExit("Guest resource output exists; choose a fresh output directory.")
    required_guests = [guest_root / "Guest/x64/OpenComposite/bin/vrclient_x64.dll",
                       guest_root / "Guest/x64/wvr_openxr.dll"]
    if any(not path.is_file() for path in required_guests):
        raise SystemExit("Stage both x64 OpenComposite and OpenXR DLLs before packaging.")
    if any(path.is_symlink() for path in guest_root.rglob("*")):
        raise SystemExit("Guest resource tree must contain regular files/directories, not symlinks.")
    if output.exists():
        raise SystemExit("Resource output already exists; choose a new directory rather than replacing it.")
    template = source / "prefix-template.tar.gz"
    # Read archive metadata before copying: do not propagate a captured game,
    # credentials, purchase-check bypass, or host filesystem symlinks.
    with tarfile.open(template, "r:gz") as archive:
        members = archive.getmembers()
        if not members:
            raise SystemExit("Wine prefix template is empty; provide a clean Wine-generated template.")
        for member in members:
            parts = Path(member.name).parts
            name = member.name.lower()
            if member.name.startswith("/") or ".." in parts or any(term in name for term in FORBIDDEN):
                raise SystemExit(f"Prefix template contains an excluded path: {member.name}")
            if member.issym() or member.islnk():
                raise SystemExit("Prefix template must omit host symlinks; runtime creates its own drive links.")
    output.mkdir(parents=True)
    shutil.copy2(template, output / template.name)
    ca_bundle = source / "cacert.pem"
    if ca_bundle.is_file():
        shutil.copy2(ca_bundle, output / ca_bundle.name)
    for farm in ["arm64ec-windows", "aarch64-windows"]:
        destination = output / farm
        destination.mkdir()
        for path in (source / farm).iterdir():
            name = path.name.lower()
            if not path.is_file() or any(term in name for term in FORBIDDEN):
                continue
            if path.suffix.lower() == ".dll" or name in WINE_TOOLS:
                shutil.copy2(path, destination / path.name)
    shutil.copytree(source / "nls", output / "nls")
    shutil.copytree(source / "legal", output / "legal")
    shutil.copytree(guest_root, guest_output)
    print(f"Staged builtin Wine resources at {output}; no code was executed.")

if __name__ == "__main__":
    main()
