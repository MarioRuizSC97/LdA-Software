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

## Current platform limitations

- Android builds require the missing Android command-line tools and accepted SDK licenses.
- iOS builds and device testing are not validated because a complete Xcode installation and CocoaPods are unavailable.
- Browser execution and browser testing are not validated because Chrome is unavailable. The widget test above runs in Flutter's test environment, not in a browser.
