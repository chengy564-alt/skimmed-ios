# Skimmed — Real-Data Backend Design

Design document for taking Skimmed from seeded mock data (`MockData.swift`) to
live Finverse-sourced data. **No code in this document** — it specifies the
contract, mapping, and iOS changes so implementation can start on either side
independently.

Grounding: the Finverse flow below was verified end-to-end in sandbox
(`POST /auth/customer/token` → `POST /link/token` → hosted Link UI → redirect
`code` → `POST /auth/token` → `GET /accounts`, confirmed returning
`account_type: { type: "CARD", subtype: "CREDIT_CARD" }` against Testbank).
Field names in §4 are taken from Finverse's official OpenAPI-generated SDK
([finversetech/sdk-typescript](https://github.com/finversetech/sdk-typescript)),
not guessed.

---

## 1. Why a backend, and what it owns

`client_secret` can never ship in the app binary, so every Finverse call that
uses it happens server-side. The backend owns:

- **Finverse credentials + token exchange** (customer token, link token, code
  → `login_identity_token` exchange, refreshes).
- **All Finverse tokens.** `login_identity_token` never reaches the app; the
  app only ever holds a Skimmed session token.
- **The transaction store + markup/DCC computation** (§5).
- **The FX reference-rate corpus** (daily mid-market rates — a data pipeline
  that has no business living on-device).
- **User identity + subscription state** (§7).

The app keeps: rendering, the estimate-only fallback path (no linked data →
stays fully client-side), formatting helpers in `Derive.swift`.

## 2. Recommended stack

**TypeScript / Node (Fastify) + Postgres**, deployed as a single small service
(Fly.io or Railway; either is fine — pick whichever you already have billing
on). Rationale, in order of weight:

1. **Finverse publishes an official TypeScript SDK** generated from their
   OpenAPI spec (`@finverse/sdk-typescript`). Auth, link, accounts,
   transactions, institutions are already typed and maintained. This
   de-risks the integration more than any other single choice.
2. One language across backend and any future web surface.
3. Fastify + Postgres is boring, cheap (~US$5–10/mo at this stage), and easy
   to hire against later.

Alternatives considered:
- **Python/FastAPI** — perfectly viable, but you'd hand-roll the Finverse
  client and keep it in sync with their API yourself. Only pick it if Python
  is already your daily language.
- **Supabase/Firebase (BaaS)** — attractive for managed auth + Postgres, but
  the Finverse flow is webhook- and background-job-heavy (initial sync,
  scheduled refreshes), which fights the edge-function model. A reasonable
  hybrid is Supabase *as the Postgres + auth provider* behind the Fastify
  service; don't put the Finverse logic in edge functions.

## 3. API contract (iOS app ↔ Skimmed backend)

All endpoints under `/v1`, JSON, bearer-authed with a Skimmed session token
(short-lived JWT + refresh token in Keychain) except the anonymous bootstrap.
Errors use one envelope: `{ error: { code, message, retryable } }` — the app
maps `code` to `Copy.swift` strings, never displays raw messages.

### Identity & session

| Endpoint | Purpose |
|---|---|
| `POST /v1/users/anonymous` | First-launch bootstrap. Returns `{ user_id, session_token, refresh_token }`. Called before onboarding Screen 3b so a link can be attributed to someone. |
| `POST /v1/users/claim` | Body: `{ apple_identity_token, transaction_jws? }`. Verifies Sign in with Apple, upgrades the anonymous user to a claimed account (§7). Returns fresh session. |
| `POST /v1/subscriptions/verify` | Body: StoreKit 2 `transaction_jws`. Backend verifies signature + `appAccountToken`, sets subscription state. |
| `DELETE /v1/users/me` | Full deletion (accounts, transactions, Finverse permissions revoked). App Store requirement; also the PDPO answer. |

### Linking (Finverse Link)

| Endpoint | Purpose |
|---|---|
| `POST /v1/link/start` | Body: `{ institution_id? }`. Backend calls Finverse `/auth/customer/token` + `/link/token` with `user_id` = Skimmed user id, `redirect_uri` = the app's callback (§6), `state` = signed nonce, PKCE `code_challenge` passed through from the app. Returns `{ link_url, state }`. |
| `POST /v1/link/complete` | Body: `{ code, state, code_verifier }`. Backend exchanges via Finverse `/auth/token`, stores `login_identity_id` + tokens server-side, kicks off the initial data pull, returns `{ link_id, status: "syncing" }`. |
| `GET /v1/link/{link_id}` | Poll while the existing `linkingOverlay` runs. `{ status: syncing \| ready \| failed, accounts_found, transactions_found }` — `transactions_found` drives the Screen-4 scan counter with *real* numbers. |
| `GET /v1/institutions` | Proxies + caches Finverse `GET /institutions`. **This is the Testbank→Live swap point** (§8). Returns `{ institution_id, display_name, color, status }[]` — feeds the bank grid instead of `RegionConfig.bankGrid`, and `color` can feed `BankMark`. |

### Data

| Endpoint | Purpose |
|---|---|
| `GET /v1/accounts` | Mapped `LinkedAccount[]` (§4) — response field names match `Types.swift` so Codable conformance is mechanical. |
| `GET /v1/transactions?since=&cursor=&account_id=` | Mapped `Transaction[]` **with markup fields already computed** (§5), cursor-paginated. |
| `GET /v1/reveal` | The server-computed, cached `RevealSnapshot`. Recomputed only on new data; append-only history kept server-side. |
| `GET /v1/rankings?currency=THB` | `CardRanking` for a destination currency. |
| `POST /v1/refresh` | Triggers Finverse `/login_identity/refresh`; async. Returns `{ refresh_id }`; completion arrives via the link-status shape and/or push later. |

### Webhooks (Finverse → backend, not app-facing)

`POST /webhooks/finverse`, signature-verified against Finverse's JWKS
endpoint (`/jwks` exists in their API). Data-retrieval-complete events flip
link/refresh status to `ready` and trigger recomputation. Exact event catalog
needs confirming against their dashboard docs (open question §9).

## 4. Data mapping: Finverse → `Types.swift`

Field names on the left are from the official SDK types.

### `Account` → `LinkedAccount`

| Finverse | `LinkedAccount` | Notes |
|---|---|---|
| — (server-issued) | `id` | Stable Skimmed id; Finverse ids are internal. |
| `account_id` | `aggregatorItemId` | Plus `login_identity_id` kept server-side only. |
| `LoginIdentity.institution_id` → `Institution.institution_name` | `institutionName` | Server maps to the short display names BankMark expects ("HSBC", "SC", …). |
| `account_nickname ?? account_name` | `displayName` | ⚠️ **Ambiguous:** banks often return generic product names ("VISA SIGNATURE"), not "HSBC Red". Plan a user-rename affordance; don't assume pretty names. |
| `account_number_masked` | `last4` | ⚠️ Mask formats vary by bank ("••••4412", "XXXX-XXXX-1234"). Parse defensively; store raw mask too. |
| `account_type {type, subtype}` | `accountType` | `CARD/CREDIT_CARD` → `.credit`; deposit types → `.debit`. ⚠️ Log-and-default unknown subtypes rather than failing. |
| `LoginIdentity.status` + `permissions_expiry_date` | `status` | Healthy → `.active`; expired/expiring permissions or auth errors → `.needsReauth`; user-revoked → `.revoked`. |
| `created_at` | `linkedAt` | |

### `Transaction` (Finverse) → `Transaction` (app)

The SDK's transaction object: `transaction_id`, `account_id`,
`transaction_type`, `merchant_name?`, `description?`, `location?`,
`is_pending`, `posted_date`, `amount: { currency, value, raw }`,
`transaction_time?`, `transaction_reference?`, `transaction_details?`
(opaque), `categories?`.

| Finverse | app `Transaction` | Notes |
|---|---|---|
| `transaction_id` | — | Kept server-side for idempotent upserts. |
| `posted_date` (fallback `transaction_time`) | `txDate` | |
| `merchant_name ?? cleaned(description)` | `merchantName` | Server-side cleaning (strip terminal ids, city suffixes). |
| `amount.currency / amount.value` | `billedCurrency / billedAmount` | |
| ⚠️ **derived** | `merchantCountry` | **No country field exists.** Infer from `location` when present, else from description suffixes ("BANGKOK TH", "AMSTERDAM NL"). This is a heuristic — carry a confidence flag server-side. |
| ⚠️ **derived** | `localCurrencyInferred / localAmountEstimated` | **The single biggest finding: Finverse's schema has no original-currency amount.** Many HK banks embed it in the description ("THB 1,760.00 @ 4.386") — parse when present (→ near-exact markup); otherwise reverse-estimate from reference rates (→ `.estimated`). Audit `transaction_details` per institution — it's typed as an opaque object and may carry the original amount for some banks. |
| derived | `isForeign` | `merchantCountry != HK`, or FX cues present. |
| derived | `isDccSuspected` | Foreign merchant AND `billedCurrency == HKD` — exactly the rule already documented in `Types.swift`. |
| server FX table | `midMarketRate` | From the backend's daily ECB/Visa/Mastercard rate corpus, keyed on `posted_date`. ⚠️ Posted date ≠ settlement date; banks convert on settlement. Use posted −0/−1/−2 day window, take the rate that minimizes implied markup (conservative — never overstate the loss). |
| computed | `effectiveRate / markupAmount / markupConfidence` | §5. |
| `is_pending` | — (excluded) | Pending card transactions change on posting; only posted transactions enter markup math. |
| — | `revealIncluded` | True for rows in the initial scan window; later finds are `false`. |

The existing `markupConfidence: .exact/.estimated` enum turns out to map
1-to-1 onto the real data situation (parsed original amount vs. reverse
estimate). The mock data model anticipated reality correctly — keep it.

`RevealSnapshot` and `CardRanking` are pure aggregations; shapes already
match and are computed server-side.

## 5. Markup/DCC computation: server-side. Definitively.

Keep `Derive.swift` on the client for **formatting and display aggregation
only** (dates, HK$ strings, per-month grouping of already-computed values).
The markup math itself moves server-side:

1. **It needs a rate corpus.** Daily mid-market rates per currency pair is a
   scheduled data pipeline with storage and licensing concerns — not app
   code. The app would otherwise need to ship or fetch a rates database.
2. **The numbers must be stable and reproducible.** `RevealSnapshot` is
   append-only by design. If the client recomputed on every launch, every
   heuristic improvement would silently change a number the user already
   screenshotted. Server-side, you version the computation and keep
   snapshots immutable.
3. **The heuristics will iterate weekly** (description parsing per bank,
   country inference, DCC detection). Server-side fixes deploy in minutes;
   client-side fixes wait on App Review and stragglers on old versions.
4. **The Reveal number is the product and sits in front of a paywall.** It
   should come from one audited computation, not vary by device/version.
5. Cross-user calibration (e.g. per-bank typical markup priors that improve
   `.estimated` rows) is only possible where the data is.

Cost: the app can't recompute offline. Acceptable — payloads arrive with all
computed fields inline, cached locally; offline users see the last-synced
numbers, which is the correct behavior anyway.

The **estimate-from-answers path** (user skips linking) stays fully
client-side — it uses no bank data and must work without an account.

## 6. iOS-side changes

Everything below preserves the existing look — the components already built
(linking overlay, scan progress, `Locked` blur, glass cards) become the real
loading/error states instead of simulations.

- **New `Services/` group** (this genuinely has no home in the current
  structure): `APIClient` (an actor over `URLSession`, async/await,
  Codable DTOs matching §3 responses), `SessionStore` (Keychain: session +
  refresh token, PKCE verifier during link). Views never touch URLs.
- **A `DataSource` seam:** protocol with `mock` and `live` implementations so
  previews and the estimate path keep running on `MockData` untouched.
  `MockData.swift` is demoted from "the data" to "the preview/estimate
  fixture" — it does not get deleted.
- **Finverse Link presentation:** `ASWebAuthenticationSession` from
  `ConnectScreen`. Flow: `POST /v1/link/start` → open `link_url` in the
  session → Finverse redirects to the callback with `code` + `state` → app
  posts them to `/v1/link/complete`. Use a **universal link**
  (`https://app.skimmed.hk/link/callback`) rather than a custom scheme for
  Live — bank redirects and app-to-app flows behave better — but a custom
  scheme is fine against Testbank. `prefersEphemeralWebBrowserSession =
  false` so returning users keep bank cookies for re-auth. PKCE verifier
  generated app-side (the SDK's `LinkTokenRequest` supports
  `code_challenge`).
- **The fake linking overlay becomes real:** same visual, but the three
  status messages map to actual states — session opening → waiting for
  redirect → polling `GET /v1/link/{id}` while Finverse syncs. On `failed`:
  glass card, plain-language error from `Copy.swift`, `PrimaryButton` retry,
  and the existing "estimate it instead" skip path as the always-available
  exit.
- **Screen 4's scan counter counts real transactions** (`transactions_found`
  from link polling) instead of animating to a hardcoded 62.
- **Bank grid** renders from `GET /v1/institutions` (cached, with the
  hardcoded list as offline fallback). `BankMark` can later consume the
  `color` field Finverse provides per institution.
- **Loading states elsewhere:** reuse the `Locked` blur treatment as the
  skeleton (blur + no lock chip) — it already reads as "content warming up"
  and avoids inventing a new shimmer language.

## 7. Identity: tying `login_identity` to a user who signs in later

The sequencing problem: linking happens during onboarding, sign-in happens at
purchase, after the Reveal. Solution: **anonymous-first accounts**.

1. **First launch:** app calls `POST /v1/users/anonymous`, stores the session
   in Keychain. Keychain survives app deletion, which gives cheap continuity
   across reinstalls on the same device (not guaranteed forever — treat as
   best-effort, not identity).
2. **Link:** `LinkTokenRequest.user_id` (a real field in their SDK) is set to
   the Skimmed `user_id`, so the resulting `LoginIdentity` carries our
   reference. The backend stores `login_identity_id` against that user row.
   Tokens never reach the device.
3. **Reveal:** computed against the anonymous user's data. No sign-in yet.
4. **Purchase:** StoreKit 2 purchase sets `appAccountToken = user_id` (UUID)
   on the transaction — the purchase is bound to the account even if the
   user bails on the next step. Then the Sign in with Apple sheet: `POST
   /v1/users/claim` verifies the Apple identity token and marks the
   anonymous user as claimed (`apple_sub` stored, unique-indexed).
5. **Edge cases:**
   - *Apple ID already claimed by another user row* (reinstall, new device):
     merge — the claimed row wins, the anonymous row's login_identities and
     transactions are re-pointed to it, then it's tombstoned.
   - *User declines SIWA after purchase:* subscription still valid via
     `appAccountToken`; prompt to claim later from Profile. Unclaimed +
     lapsed accounts get a retention-window purge (PDPO-friendly).
   - *Restore purchases:* SIWA → find user by `apple_sub` → restore links
     and history; StoreKit restore re-verifies entitlement.
   - *Re-auth:* `permissions_expiry_date` approaching / auth errors flip the
     account to `needs_reauth`; re-link passes the existing
     `login_identity_id` back into `/link/token` (the SDK supports this) so
     history is preserved rather than duplicated.

## 8. Testbank → Live migration

Principle: **Live vs. Testbank is configuration, not code.**

```
FINVERSE_ENV = sandbox | live        ← THE SWAP POINT (backend env only)
  ├─ selects client_id / client_secret pair
  ├─ selects Finverse base URL (api.sandbox vs api.prod)
  └─ selects the institution filter for GET /v1/institutions:
       sandbox → institution_id == "testbank"
       live    → country == "HKG", products_supported ∋ TRANSACTIONS,
                 status == healthy
```

Because the app's bank grid renders from `GET /v1/institutions` (§3), **no
iOS release is required to go live** — the grid switches from Testbank to the
real six HK institutions when the backend env flips. Nothing else in the app
references institutions.

Build/test sequence:
1. Everything in this doc built and E2E-tested against Testbank (repeat the
   already-verified manual flow, now through the backend).
2. Fixture-record Testbank responses (accounts, transactions) into contract
   tests so CI catches Finverse schema drift.
3. Live cutover checklist: Live credentials in the secrets manager (never in
   repo/CI logs); redirect URI + webhook URL registered in the Finverse
   dashboard for the Live app; per-bank audit of real statement descriptions
   (the §4 original-amount parsing was only ever testable against real
   banks — expect a tuning pass per institution); PDPO/data-retention review;
   App Review notes for the banking-login flow.

## 9. Open questions (need Finverse dashboard docs or a support thread)

1. **Per-bank original-currency availability** — does `transaction_details`
   or the description carry the foreign amount for each of HSBC / Hang Seng
   / SC / BOC / BEA / DBS? Determines the exact/estimated split, per §4.
   *(Empirical: audit real statements per bank at Live.)*
2. `GET /transactions` pagination contract (cursor vs offset/limit) and
   maximum history window (`LinkTokenRequest.history_date_limit` exists —
   confirm the ceiling; the Reveal wants up to 24 months).
3. Webhook event catalog + signing details (JWKS endpoint exists; confirm
   event names for data-retrieval completion).
4. `GET /card_details` — the SDK exposes it (`card_accounts`, `card_total`);
   check whether it yields statement dates / credit limits worth showing on
   the Cards screen later.
5. Reference-rate licensing: ECB is free/attributable; Visa/Mastercard
   published-rate endpoints have usage terms to review before "checked
   against Visa's rate" appears in marketing copy.
6. Finverse rate limits + token TTLs for the customer token (cache it
   server-side rather than minting per request).
