# Ridge 1.0 privacy evidence

Audited 27 October 2026 against the release-preparation working tree, including
the existing Apple-hosted delivery and retained protected-download code. Recheck
this matrix against the final submitted binary. This is an engineering record,
not a declaration that the app has passed Apple review.

## Proposed App Store answers

The current code retains a Bilella Works App Attest download client. The default
source is Apple-hosted Background Assets; that path does not call the retained
verification service. Existing/explicit compatible download links can still use
the protected service. Therefore do not select **Data Not Collected** while that
reachable behaviour remains in the release.

| Type | Purpose | Linked | Tracking | Evidence |
|---|---|---|---|---|
| Device ID | App Functionality | Yes, installation/device identifier | No | `WorldProtectedAccess` sends the App Attest key ID; the retained service persists its public key, assertion counter and block flag. No Ridge account or advertising ID. |
| Other Usage Data | App Functionality | Yes, the same device key | No | Protected service stores per-device daily read/byte counts to enforce download allowances. These are security/operation counters, not behavioural analytics. |

The app privacy manifest now matches these conservative answers. Neither type is
used for advertising, analytics, personalization or cross-app tracking. There is
no third-party analytics or crash-reporting SDK in the audited app sources.

## Local-only data and system services

| Data/feature | Handling |
|---|---|
| Routes, GPX, waypoints, names, notes | Local `RouteStore`; no upload in route calculation, rendering or preview. User chooses each system export/share destination. |
| Walking pace, start time, breaks and checklist | Per-route `UserDefaults` data; no server API. |
| Place search | `WorldExploreView.candidates` filters saved/bundled places locally. No MapKit search call or online map service in this flow. |
| Optional current location | `RidgeLocation` requests a one-shot location for the supported map view after permission. No background location entitlement or route-tracking upload. Do not declare off-device location collection solely because permission exists. |
| Default additional map downloads | Apple Background Assets / `StoreDownloaderExtension`; app requests pack IDs. Apple's own account/distribution handling follows Apple's terms. Route documents and notes are not uploaded as pack requests. |
| Alternative servers and links | Operator receives normal file requests; the explicit selected provider's own privacy practices apply. The two exact retained Bilella Works protected hosts receive the additional security exchange above. |
| Optional support email | User opens Mail with an empty message and a subject. No automatic route or diagnostic attachment. Existing support policy covers email and voluntary attachments. |
| TestFlight diagnostics | Apple's separate beta service; not evidence of an embedded analytics SDK. |

## Retention verified in the retained service

`homeCloud/cloud/src/index.ts` creates `devices`, `challenges`, `grants` and
`counters`. Short-lived challenge/grant records have a two-minute expiry and are
purged by subsequent challenge requests. They include the requested path/range.
Device registrations and per-device daily counters currently have **no automatic
expiry**. The revised website policy states that fact rather than inventing a
retention period. Do not silently change the service or discard its quotas as
part of store preparation.

## Links and release checks

- Policy: https://bilellaworks.com/apps/ridge/privacy/
- Support: https://bilellaworks.com/apps/ridge/support/
- Optional feedback: public studio email already used on Bilella Works.
- Website corrections were published with owner approval on 30 October 2026.
  The live policy, support redirect and product page were verified in the browser;
  see `evidence/website-publication.json`. The App Store declaration remains an
  unpublished draft for final submission preparation.
- On 30 October, both draft data types were saved as App Functionality, linked
  to the device, and not used for tracking. The product-page preview shows
  Identifiers and Usage Data under Data Linked to You. Publish was not pressed.
  The signed build 3 archive contains the matching manifest.
- A final Apple-only build with the retained client removed could warrant a
  narrower declaration, but that is a different implementation and must be
  verified before changing these answers.
- On 31 October the selected build-4 archive's privacy manifest was inspected:
  Device ID and Other Usage Data remain linked, for app functionality, with no
  tracking. The live questionnaire still shows those two saved types and a
  Publish button. The included-only build disables Apple downloads but retains
  the protected-client code; the conservative declaration is unchanged.

Sources: [Apple privacy definitions](https://developer.apple.com/app-store/app-privacy-details/),
[manifest collection fields](https://developer.apple.com/documentation/technotes/tn3184-adding-data-collection-details-to-your-privacy-manifest),
[collection purposes](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacycollecteddatatypes/nsprivacycollecteddatatypepurposes).
