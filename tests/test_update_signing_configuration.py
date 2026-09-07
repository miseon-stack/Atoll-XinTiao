import plistlib
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
INFO_PLIST = ROOT / "DynamicIsland" / "Info.plist"
UPDATE_CHANNEL = ROOT / "DynamicIsland" / "models" / "UpdateChannel.swift"
APPCASTS = (
    ROOT / "Updates" / "appcast.xml",
    ROOT / "Updates" / "appcast-beta.xml",
    ROOT / "Updates" / "appcast-alpha.xml",
    ROOT / "Updates" / "appcast-nightly.xml",
)
PUBLIC_REPOSITORY = "miseon-stack/Atoll-XinTiao"
SPARKLE_PUBLIC_KEY = "3n7A+IQtyB5hsiTwwP33gNOd0mUmo7g+pTURXCxvJDE="


class UpdateSigningConfigurationTests(unittest.TestCase):
    def test_info_plist_uses_public_repository_and_matching_public_key(self):
        info = plistlib.loads(INFO_PLIST.read_bytes())

        self.assertIn(PUBLIC_REPOSITORY, info["SUFeedURL"])
        self.assertEqual(SPARKLE_PUBLIC_KEY, info["SUPublicEDKey"])

    def test_every_update_channel_uses_public_repository(self):
        source = UPDATE_CHANNEL.read_text()

        self.assertIn(PUBLIC_REPOSITORY, source)
        self.assertNotIn("Ebullioscopic/Atoll", source)

    def test_appcasts_are_valid_and_do_not_offer_foreign_binaries(self):
        for appcast in APPCASTS:
            with self.subTest(appcast=appcast.name):
                root = ET.parse(appcast).getroot()
                self.assertEqual("rss", root.tag)
                self.assertIsNotNone(root.find("channel"))
                self.assertIsNone(root.find("channel/item"))
                self.assertNotIn("Ebullioscopic/Atoll", appcast.read_text())


if __name__ == "__main__":
    unittest.main()
