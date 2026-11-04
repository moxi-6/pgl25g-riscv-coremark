"""Reject stale sources, falsified evidence status and tampered ZIP payloads."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import zipfile
from competition_artifacts import DOCS, PUBLIC_DOC_DIRS, audit_combined_source, inside, source_snapshot, verify_files
from build_competition_delivery import READY, verify_archive


class DeliveryGuards(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def test_manifest_cannot_read_outside_package(self):
        with self.assertRaisesRegex(ValueError, 'escapes'):
            inside(self.root, '../private.txt')

    def test_missing_and_changed_artifact_are_rejected(self):
        path = self.root / 'firmware.hex'
        path.write_bytes(b'00100073\n')
        hashes = {'firmware.hex': hashlib.sha256(path.read_bytes()).hexdigest()}
        verify_files(self.root, hashes)
        path.write_bytes(b'00000013\n')
        with self.assertRaisesRegex(ValueError, 'corrupt'):
            verify_files(self.root, hashes)
        path.unlink()
        with self.assertRaisesRegex(ValueError, 'Missing'):
            verify_files(self.root, hashes)

    def test_empty_evidence_is_not_success(self):
        with self.assertRaisesRegex(ValueError, 'Empty'):
            verify_files(self.root, {})

    def test_release_documents_use_a_public_allowlist(self):
        (self.root / 'docs').mkdir()
        for name in DOCS:
            (self.root / 'docs' / name).write_text('Public technical documentation', encoding='utf-8')
        (self.root / 'README.md').write_text('Project overview')
        (self.root / 'LICENSE').write_text('Project license')
        (self.root / 'docs' / 'local_license_request.txt').write_text('Machine-specific request')
        (self.root / 'docs' / 'development_handoff.md').write_text('Internal notes')
        for folder in PUBLIC_DOC_DIRS:
            (self.root / folder).mkdir(parents=True)
            (self.root / folder / 'public.txt').write_text('Published evidence')
        files = source_snapshot(self.root, include_docs=True)
        self.assertIn('LICENSE', files)
        self.assertEqual({p for p in files if p.startswith('docs/')},
                         {'docs/' + name for name in DOCS} | {folder + '/public.txt' for folder in PUBLIC_DOC_DIRS})

    def test_release_must_embed_current_ordered_rtl(self):
        (self.root / 'boards/atk_l50').mkdir(parents=True)
        (self.root / 'rtl').mkdir()
        (self.root / 'boards/atk_l50/cpu.f').write_text('rtl/a.sv\nrtl/b.sv\n')
        (self.root / 'rtl/a.sv').write_text('module a; endmodule\n')
        (self.root / 'rtl/b.sv').write_text('module b; endmodule\n')
        combined = self.root / 'pds_design.sv'
        combined.write_text('// Source: rtl/a.sv\nmodule a; endmodule\n\n// Source: rtl/b.sv\nmodule b; endmodule\n')
        audit_combined_source(self.root, 'cpu', combined)
        (self.root / 'rtl/b.sv').write_text('module b; wire new_signal; endmodule\n')
        with self.assertRaisesRegex(ValueError, 'stale embedded RTL'):
            audit_combined_source(self.root, 'cpu', combined)

    def archive(self, *, payload=b'current', actual=None, status=READY, hardware=False, extra=False):
        archive = self.root / 'delivery.zip'
        manifest = {'status': status, 'hardware_touched': hardware, 'current_hardware_verified': False,
                    'files': {'fpga_riscv_starter/rtl/core.sv': hashlib.sha256(payload).hexdigest()}}
        with zipfile.ZipFile(archive, 'w') as zipped:
            zipped.writestr('delivery_manifest.json', json.dumps(manifest))
            zipped.writestr('fpga_riscv_starter/rtl/core.sv', payload if actual is None else actual)
            if extra:
                zipped.writestr('unmanifested.sbit', b'old')
        return archive

    def test_intact_offline_archive_passes(self):
        self.assertEqual(verify_archive(self.archive())['status'], READY)

    def test_old_board_verified_status_cannot_be_reused(self):
        with self.assertRaisesRegex(ValueError, 'evidence status'):
            verify_archive(self.archive(status='BOARD_VERIFIED_DEMO_READY', hardware=True))

    def test_payload_corruption_rejected_despite_valid_zip_crc(self):
        with self.assertRaisesRegex(ValueError, 'content mismatch'):
            verify_archive(self.archive(actual=b'stale'))

    def test_unmanifested_old_bitstream_rejected(self):
        with self.assertRaisesRegex(ValueError, 'unmanifested'):
            verify_archive(self.archive(extra=True))


if __name__ == '__main__':
    unittest.main(verbosity=2)
