"""Offline packaging regressions. Fixtures contain no Wine or game binaries."""
import gzip
import io
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import sanitize_prefix_snapshot as sanitizer
import stage_resources as stage
from verify_source_checkout import verify_source_checkout


class PrefixTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.source = self.root / "source.tar.gz"

    def archive(self, extra=(), layout="prefix/"):
        entries = [(layout + "system.reg", b"registry"),
                   (layout + "user.reg", b"registry"),
                   (layout + "drive_c/windows/system32", None), *extra]
        with tarfile.open(self.source, "w:gz", format=tarfile.PAX_FORMAT) as archive:
            for name, value in entries:
                member = tarfile.TarInfo(name)
                if isinstance(value, tarfile.TarInfo):
                    member = value
                elif value is None:
                    member.type = tarfile.DIRTYPE
                else:
                    member.size = len(value)
                archive.addfile(member, io.BytesIO(value) if isinstance(value, bytes) else None)

    def test_root_and_upstream_layouts(self):
        for layout in ("", "prefix/"):
            with self.subTest(layout=layout):
                self.archive(layout=layout)
                stage.validate_prefix_archive(self.source)

    def test_rejects_links_collisions_and_file_ancestors(self):
        link = tarfile.TarInfo("prefix/drive_c/host")
        link.type, link.linkname = tarfile.SYMTYPE, "/unreadable/host/path"
        cases = [
            ([('prefix/drive_c/host', link)], "symlinks"),
            ([('prefix/SYSTEM.REG', b"other")], "case-colliding"),
            ([('prefix/data', b"file"), ('prefix/data/child', b"file")], "file used as a directory"),
            ([('prefix/../escape', b"file")], "unsafe path"),
        ]
        for entries, reason in cases:
            with self.subTest(reason=reason):
                self.archive(entries)
                with self.assertRaisesRegex(SystemExit, reason):
                    stage.validate_prefix_archive(self.source)

    def test_member_cap_stops_iteration_before_remaining_headers(self):
        self.archive([(f"prefix/item{i}", b"") for i in range(10)])
        original = tarfile.open(self.source, "r:gz")
        self.addCleanup(original.close)

        class LimitedReader:
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def getmembers(self): raise AssertionError("Must not materialize the full archive")
            def __iter__(self):
                for count, entry in enumerate(original, 1):
                    if count > 4:
                        raise AssertionError("Read past the enforced member cap")
                    yield entry

        with patch.object(stage, "MAX_ARCHIVE_MEMBERS", 3), patch.object(stage.tarfile, "open", return_value=LimitedReader()):
            with self.assertRaisesRegex(SystemExit, "too many archive members"):
                stage.validate_prefix_archive(self.source)

    def test_oversized_header_rejected_without_reading_declared_body(self):
        member = tarfile.TarInfo("prefix/huge")
        member.size = 1025
        with gzip.open(self.source, "wb") as stream:
            stream.write(member.tobuf(format=tarfile.USTAR_FORMAT))
        with patch.object(stage, "MAX_ARCHIVE_FILE", 1024):
            with self.assertRaisesRegex(SystemExit, "oversized file"):
                stage.validate_prefix_archive(self.source)

    def test_cumulative_size_limit(self):
        self.archive()
        with patch.object(stage, "MAX_ARCHIVE_UNPACKED", 10):
            with self.assertRaisesRegex(SystemExit, "maximum uncompressed size"):
                stage.validate_prefix_archive(self.source)

    def test_sanitizer_preserves_registry_and_never_follows_host_links(self):
        name = "prefix/drive_c/users/madeira/Documents"
        link = tarfile.TarInfo(name)
        link.type, link.linkname = tarfile.SYMTYPE, "/unreadable/host/Documents"
        self.archive([(name, link), ("prefix/._system.reg", b"host metadata")])
        output, receipt = self.root / "portable.tar.gz", self.root / "receipt.json"
        with patch.object(Path, "read_bytes", side_effect=AssertionError("Archive hashing must stream")):
            sanitizer.sanitize(self.source, output, receipt)
        stage.validate_prefix_archive(output)
        with tarfile.open(output, "r:gz") as archive:
            self.assertEqual(archive.extractfile("prefix/system.reg").read(), b"registry")
            self.assertTrue(archive.getmember(name).isdir())
            self.assertNotIn("prefix/._system.reg", archive.getnames())
            self.assertTrue(all(not item.pax_headers for item in archive))
        value = json.loads(receipt.read_text())
        self.assertEqual(value["removedLinkNames"], [name])
        self.assertEqual(value["portableArchiveSha256"], sanitizer.sha256_file(output))

    def test_receipt_publication_failure_rolls_back_archive_and_temp_file(self):
        self.archive()
        output, receipt = self.root / "portable.tar.gz", self.root / "receipt.json"
        with patch.object(sanitizer.os, "link", side_effect=PermissionError("fixture")):
            with self.assertRaises(PermissionError):
                sanitizer.sanitize(self.source, output, receipt)
        self.assertFalse(output.exists())
        self.assertFalse(receipt.exists())
        self.assertEqual(list(self.root.glob(".prefix-receipt-*")), [])

    def test_existing_or_dangling_receipt_is_preserved(self):
        self.archive()
        output, receipt = self.root / "portable.tar.gz", self.root / "receipt.json"
        receipt.symlink_to("missing-target")
        with self.assertRaisesRegex(SystemExit, "fresh portable"):
            sanitizer.sanitize(self.source, output, receipt)
        self.assertTrue(receipt.is_symlink())
        self.assertFalse(output.exists())

    def test_racing_output_writer_is_not_deleted(self):
        self.archive()
        output, receipt = self.root / "portable.tar.gz", self.root / "receipt.json"
        original_open = Path.open

        def racing_open(path, *args, **kwargs):
            if path == output and args == ("xb",):
                with original_open(path, "wb") as stream:
                    stream.write(b"other writer")
                raise FileExistsError("other writer won the race")
            return original_open(path, *args, **kwargs)

        with patch.object(Path, "open", racing_open):
            with self.assertRaises(FileExistsError):
                sanitizer.sanitize(self.source, output, receipt)
        self.assertEqual(output.read_bytes(), b"other writer")


class SourcePinTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.source = self.root / "source"
        self.source.mkdir()
        self.git(self.source, "init", "--quiet")
        (self.source / "source.c").write_text("original\n")
        self.commit(self.source)
        self.revision = self.git(self.source, "rev-parse", "HEAD")

    def git(self, source, *args):
        return subprocess.check_output([
            "git", "-c", "user.name=Offline Fixture", "-c", "user.email=fixture@example.invalid",
            "-c", "commit.gpgsign=false", "-c", "protocol.file.allow=always",
            "-C", str(source), *args], text=True, stderr=subprocess.PIPE).strip()

    def commit(self, source):
        self.git(source, "add", ".")
        self.git(source, "commit", "--quiet", "-m", "fixture")

    def test_clean_pin_is_accepted_and_wrong_revision_rejected(self):
        verify_source_checkout(self.source, self.revision)
        with self.assertRaisesRegex(SystemExit, "revision"):
            verify_source_checkout(self.source, "0" * 40)

    def test_tracked_and_untracked_source_changes_rejected(self):
        (self.source / "source.c").write_text("modified\n")
        with self.assertRaisesRegex(SystemExit, "local or submodule changes"):
            verify_source_checkout(self.source, self.revision)
        self.git(self.source, "checkout", "--", "source.c")
        (self.source / "new.c").write_text("untracked\n")
        with self.assertRaisesRegex(SystemExit, "local or submodule changes"):
            verify_source_checkout(self.source, self.revision)

    def test_dirty_wrong_revision_and_uninitialized_submodules_rejected(self):
        dependency = self.root / "dependency"
        dependency.mkdir()
        self.git(dependency, "init", "--quiet")
        (dependency / "dep.c").write_text("original\n")
        self.commit(dependency)
        self.git(self.source, "submodule", "add", "--quiet", str(dependency), "dependency")
        self.commit(self.source)
        revision = self.git(self.source, "rev-parse", "HEAD")
        verify_source_checkout(self.source, revision)
        submodule = self.source / "dependency"
        (submodule / "dep.c").write_text("modified\n")
        with self.assertRaises(SystemExit): verify_source_checkout(self.source, revision)
        self.commit(submodule)
        with self.assertRaises(SystemExit): verify_source_checkout(self.source, revision)
        self.git(self.source, "submodule", "deinit", "--force", "dependency")
        with self.assertRaisesRegex(SystemExit, "uninitialized"):
            verify_source_checkout(self.source, revision)


class ArchitectureTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.path = Path(self.scratch.name) / "synthetic.dll"

    def image(self, machine=0x8664, metadata_version=None, metadata_va=None):
        # A header-only PE fixture: one data section and no executable code.
        data = bytearray(0x800)
        def number(offset, value, width):
            data[offset:offset + width] = value.to_bytes(width, "little")
        data[:2] = b"MZ"
        number(0x3C, 0x40, 4)
        data[0x40:0x44] = b"PE\0\0"
        number(0x44, machine, 2)
        number(0x46, 1, 2)
        number(0x54, 240, 2)
        optional = 0x58
        number(optional, 0x20B, 2)
        number(optional + 24, 0x180000000, 8)
        number(optional + 56, 0x2000, 4)
        number(optional + 60, 0x400, 4)
        number(optional + 108, 16, 4)
        section = optional + 240
        number(section + 8, 0x400, 4)
        number(section + 12, 0x1000, 4)
        number(section + 16, 0x400, 4)
        number(section + 20, 0x400, 4)
        if metadata_version is not None:
            number(optional + 112 + 10 * 8, 0x1000, 4)
            number(optional + 116 + 10 * 8, 0xD0, 4)
            number(0x400, 0xD0, 4)
            number(0x400 + 0xC8, metadata_va if metadata_va is not None else 0x180001200, 8)
            number(0x600, metadata_version, 4)
        self.path.write_bytes(data)

    def test_plain_x64_and_raw_arm64ec_are_distinguished(self):
        self.image()
        self.assertEqual(stage.pe_machine(self.path), 0x8664)
        self.assertFalse(stage.is_arm64ec_pe(self.path))
        self.image(machine=0xA641)
        self.assertTrue(stage.is_arm64ec_pe(self.path))

    def test_amd64_with_valid_chpe_is_arm64ec_not_plain_x64(self):
        for version in (1, 2):
            self.image(metadata_version=version)
            self.assertEqual(stage.pe_machine(self.path), 0x8664)
            self.assertTrue(stage.is_arm64ec_pe(self.path))
            self.assertFalse(stage._is_x64_pe(self.path))

    def test_invalid_or_unmapped_chpe_metadata_is_not_accepted(self):
        self.image(metadata_version=3)
        self.assertFalse(stage.is_arm64ec_pe(self.path))
        self.image(metadata_version=1, metadata_va=0x180002000)
        self.assertFalse(stage.is_arm64ec_pe(self.path))


if __name__ == "__main__":
    unittest.main()
