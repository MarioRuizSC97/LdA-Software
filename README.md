# LDA Inventory

Flutter foundation for the LDA inventory application. This scaffold currently contains no Firebase integration or inventory business logic.

## Supported targets

The project is scaffolded for Android, iOS, and web only.

## Local checks

Use the pinned local Flutter SDK from the repository root:

```sh
FLUTTER_SUPPRESS_ANALYTICS=true $HOME/develop/flutter/bin/flutter analyze
FLUTTER_SUPPRESS_ANALYTICS=true $HOME/develop/flutter/bin/flutter test
```

Run the app on an available device with:

```sh
FLUTTER_SUPPRESS_ANALYTICS=true $HOME/develop/flutter/bin/flutter run
```

## Local Firebase boundary

The local Firebase configuration uses the explicit demo project ID
`demo-lda-inventory`. There is intentionally no `.firebaserc` default, cloud
project, deployment configuration, Functions emulator, or Hosting emulator.
Only Auth, Firestore, and Storage emulators are in this slice.

Install the pinned rules-test dependencies and run the local security suite:

```sh
npm --prefix firebase/tests ci
$HOME/.local/share/lda-firebase-tools/node_modules/.bin/firebase \
  emulators:exec --project demo-lda-inventory \
  --only auth,firestore,storage \
  'npm --prefix firebase run test:rules'
```

The minimal local data contract is:

- `products/{productId}`: authenticated catalog reads; no acquisition cost.
- `branches/{branchId}/stock/{productId}`: administrator reads or seller reads
  when the `branchId` custom claim matches the path.
- `costs/{productId}`: administrator-only acquisition-cost reads.
- `inventoryMovements/{movementId}`: administrator reads or branch-matched
  seller reads based on the document `branchId`; client writes are denied.
- Storage `branches/{branchId}/products/{productId}/{fileName}`: administrator
  reads or branch-matched seller reads.

The local tests simulate trusted custom claims with roles `administrator` and
`seller`. Every direct Firestore inventory mutation and every direct Storage
mutation is denied, including for administrators. Future trusted server code
must perform those writes with validation and auditing; no such business logic
is part of this local-boundary slice.

Firestore rules cannot hide selected fields inside a readable document.
Therefore `products/{productId}` documents **MUST exclude acquisition costs**,
and cost data must remain physically separate under `costs/{productId}`.
Physically separated costs and server-owned inventory writes are mandatory
schema constraints for the next implementation phase, not field filtering that
these rules can provide.

## Current platform limitations

- Android builds require the missing Android command-line tools and accepted SDK licenses.
- iOS builds and device testing are not validated because a complete Xcode installation and CocoaPods are unavailable.
- Browser execution and browser testing are not validated because Chrome is unavailable. The widget test above runs in Flutter's test environment, not in a browser.
