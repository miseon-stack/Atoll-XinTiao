import hashlib
import json
import plistlib
import re
import struct
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "DynamicIsland/Assets.xcassets"
APPROVED_SHA = "e0e411fd2c63e286465c64668428744ef641200715de5a8cb9393a2ca0e41aaf"


class BrandingTests(unittest.TestCase):
    def test_source_is_approved_icon_five(self):
        source = (ROOT / ".github/assets/work-tempo-icon.png").read_bytes()
        self.assertEqual(hashlib.sha256(source).hexdigest(), APPROVED_SHA)
        self.assertEqual(source, (ROOT / ".github/assets/atoll-logo.png").read_bytes())
        for name in ("logo.imageset", "logo2.imageset"):
            manifest = json.loads((ASSETS / name / "Contents.json").read_text())
            for item in manifest["images"]:
                self.assertEqual(source, (ASSETS / name / item["filename"]).read_bytes())

    def test_all_app_icon_channels_use_same_artwork_and_correct_sizes(self):
        reference = {}
        catalogs = sorted(ASSETS.glob("AppIcon*.appiconset"))
        self.assertEqual(len(catalogs), 5)
        for catalog in catalogs:
            manifest = json.loads((catalog / "Contents.json").read_text())
            for item in manifest["images"]:
                pixels = int(item["size"].split("x")[0]) * int(item["scale"][:-1])
                data = (catalog / item["filename"]).read_bytes()
                self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
                self.assertEqual(struct.unpack(">II", data[16:24]), (pixels, pixels))
                digest = hashlib.sha256(data).hexdigest()
                self.assertEqual(reference.setdefault(pixels, digest), digest)

    def test_product_names_and_test_host(self):
        project = (ROOT / "DynamicIsland.xcodeproj/project.pbxproj").read_text()
        self.assertEqual(project.count('PRODUCT_NAME = "Work Tempo";'), 2)
        self.assertEqual(project.count('INFOPLIST_KEY_CFBundleDisplayName = "Work Tempo";'), 2)
        self.assertEqual(project.count('PRODUCT_MODULE_NAME = Atoll;'), 2)
        self.assertEqual(project.count('$(BUILT_PRODUCTS_DIR)/Work Tempo.app/Contents/MacOS/Work Tempo'), 2)
        self.assertIn('PRODUCT_BUNDLE_IDENTIFIER = com.Ebullioscopic.Atoll.dev;', project)
        self.assertIn('PRODUCT_BUNDLE_IDENTIFIER = com.Ebullioscopic.Atoll;', project)
        scheme = (ROOT / "DynamicIsland.xcodeproj/xcshareddata/xcschemes/DynamicIsland.xcscheme").read_text()
        self.assertNotIn('BuildableName = "Atoll.app"', scheme)

    def test_persistent_launcher_and_calendar_folders_are_unchanged(self):
        for file in ('DynamicIsland/features/ShortcutLauncher/AtollShortcutLauncherPaths.swift',
                     'DynamicIsland/features/LiveEarnings/Calendar/WorkdayOverrideStore.swift'):
            self.assertIn('appendingPathComponent("Atoll", isDirectory: true)', (ROOT / file).read_text())
        self.assertIn('syncFolderName = "Atoll"', (ROOT / 'DynamicIsland/managers/AppleNotesSyncManager.swift').read_text())

    def test_public_brand_links_and_update_key(self):
        readme = (ROOT / 'ReadMe.md').read_text()
        self.assertIn('<h1 align="center">Work Tempo</h1>', readme)
        self.assertIn('.github/assets/work-tempo-icon.png', readme)
        self.assertNotIn('Atoll × 薪跳', readme)
        self.assertIn('miseon-stack/work-tempo', readme)
        info = plistlib.loads((ROOT / 'DynamicIsland/Info.plist').read_bytes())
        self.assertEqual(info['SUPublicEDKey'], '3n7A+IQtyB5hsiTwwP33gNOd0mUmo7g+pTURXCxvJDE=')
        self.assertIn('/miseon-stack/work-tempo/', info['SUFeedURL'])

    def test_localized_brand_and_launcher_entry_points(self):
        catalog = json.loads((ROOT / 'DynamicIsland/Localizable.xcstrings').read_text())['strings']
        self.assertIn('Work Tempo', catalog)
        self.assertNotIn('Atoll', catalog)
        app = (ROOT / 'DynamicIsland/DynamicIslandApp.swift').read_text()
        self.assertIn('MenuBarExtra("Work Tempo", image: "MenuBarIcon"', app)
        self.assertIn('AtollShortcutLauncherService.shared.presentPanel()', app)
        self.assertIn('Button("Restart Work Tempo")', app)
        self.assertIn('openApplication(at: Bundle.main.bundleURL', app)
        self.assertNotIn('urlForApplication(withBundleIdentifier: bundleIdentifier)', app)
        self.assertIn('identifier?.rawValue == "Atoll.Focus.Menu"', app)
        self.assertIn('Text("Work Tempo")', (ROOT / 'DynamicIsland/components/Onboarding/WelcomeView.swift').read_text())

    def test_download_permission_wait_cannot_block_launch(self):
        source = (ROOT / 'DynamicIsland/managers/DownloadManager.swift').read_text()
        self.assertNotIn('requestDownloadsPermissionIfNeeded()', source)
        self.assertIn('await Task.detached(priority: .utility)', source)
        self.assertIn('self.queue.async(execute: scan)', source)
        self.assertIn('self.monitoringGeneration == generation', source)


if __name__ == '__main__':
    unittest.main()
