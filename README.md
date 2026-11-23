<p align="center">
  <img src="Skimmed%20v3/Assets.xcassets/AppIcon.appiconset/icon-1024.png" width="120" alt="Skimmed app icon">
</p>

<h1 align="center">Skimmed</h1>

<p align="center"><b>Your travel fees, finally seen.</b><br>
A native iOS app that finds the hidden foreign-exchange markup on your card statements.<br>
<a href="https://skimmed.org">skimmed.org</a></p>

---

When you pay abroad, your bank converts the charge at its own rate and quietly keeps the difference. That markup never appears as a line item. Skimmed reads your statement, compares every foreign charge with the European Central Bank's official rate for that day, and shows you exactly how much each card cost you.

**No bank login, no account, no server.** Statements are parsed and analysed entirely on the device. The only network calls are the ECB's public rates API and StoreKit.

<!-- Screenshots: add PNGs to docs/screenshots/ and uncomment.
<p align="center">
  <img src="docs/screenshots/home.png" width="230">
  <img src="docs/screenshots/cards.png" width="230">
  <img src="docs/screenshots/trip.png" width="230">
</p>
-->

## Features

- **Statement import.** Users import PDF or CSV statements. The parser detects the bank, and a manual column-mapping step handles unknown layouts. The mapping is remembered for next time.
- **Fee analysis against real rates.** Each foreign charge is priced against the ECB reference rate for its transaction date. Weekends and holidays walk back to the last published rate. Rates are cached, and charges start as provisional before upgrading to verified.
- **Card ranking.** Your cards are ranked by median markup, with evidence tiers and honest tie handling.
- **Trip audits.** Users can plan a trip, attach statements to it, and get a per-trip breakdown with an evidence-labelled playbook.
- **Leak map.** An offline world map, drawn with Canvas from Natural Earth data, glows where money was lost. Tapping a country opens that trip.
- **Worldwide card catalogue.** It covers 88 institutions and about 170 card products, specific to each market. Published fees exist only when backed by an issuer source link and a verification date, and a test enforces this.
- **Dynamic currency conversion trap detection.** The app flags charges where the merchant converted the currency at the till.
- **StoreKit 2 monetisation.** The app offers a one-time full report, a supporter tier, and monthly or annual Plus subscriptions.

## Honesty as a product rule

The app never fabricates a number. Every figure is labelled **Observed**, **Published**, **Estimated** or **Insufficient evidence**. Only positive losses count toward totals. An implausible implied rate, more than 50% off the reference rate, is reported as unable to calculate rather than guessed.

## Tech

| | |
|---|---|
| UI | SwiftUI on iOS 26, including Liquid Glass, spring motion, haptics and full Reduce Motion support |
| Parsing | PDFKit text extraction plus a content-sniffing CSV and PDF importer |
| Rates | ECB Data API with an on-device cache and a bundled fallback table |
| Payments | StoreKit 2, with a local `.storekit` configuration for testing |
| Persistence | JSON in Application Support, using atomic writes and complete file protection |
| Tests | 163 XCTest unit tests on the import core, run with Swift Package Manager |

## Project structure

```
Skimmed v3/
  ImportCore/    Statement parsing, bank detection, rates, card catalogue (pure Swift, unit-tested)
  Store/         App state, analyzer, persistence, StoreKit entitlements
  Models/        Domain types, formatting, region and trip logic
  Views/         Screens: onboarding, home, trips, cards, profile, import flow
  Components/    Reusable UI: cards, map, charts, pickers, splash
Tests/           XCTest suite with synthetic CSV fixtures
site/            Static marketing site and privacy policy
```

## Build and run

You need Xcode 26 or newer.

```bash
# Run the app in the simulator
open "Skimmed v3.xcodeproj"    # then press Run

# Run the unit tests
swift test

# Optional: test against the live ECB API
SKIMMED_LIVE_ECB=1 swift test --filter ECBLiveIntegrationTests
```

## Status

Version 1.0 is feature-complete and in TestFlight, with App Store submission in progress. The project is built by [Hubert Cheng](https://github.com/chengy564-alt) in Hong Kong.
