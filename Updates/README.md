# Update signing

The Sparkle feeds in this directory belong to the `miseon-stack/work-tempo`
distribution. They intentionally contain no release items until the first
binary has been signed with the matching private key and notarized by Apple.

- `SUPublicEDKey` is committed in `DynamicIsland/Info.plist`.
- The matching private key is stored only in the local macOS login Keychain
  under the Sparkle account `miseon-stack.Atoll-XinTiao`.
- Never commit an exported Sparkle private key, a Developer ID `.p12`, an
  app-specific password, or App Store Connect API credentials.
- Generate each feed from artifacts signed by this project's key. Do not copy
  historical appcast items signed by another publisher.

Developer ID signing and Apple notarization additionally require an active
Apple Developer Program team. A free Personal Team cannot issue a
`Developer ID Application` certificate.
