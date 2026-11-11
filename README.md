# boltz-dart

The top level directory of this project is a dart/flutter pub library.

The `rust` folder containers the core code which uses the `boltz-rust` crate internally to expose an abstracted API to manage boltz swaps.

## Usage

Init the library in your apps main()

Eg:

```dart

Future main({bool fromTest = false}) async {
  if (!fromTest) WidgetsFlutterBinding.ensureInitialized();

  await dotenv.load(isOptional: true);
  Bloc.observer = BBlocObserver();
  // await FlutterWindowManager.addFlags(FlutterWindowManager.FLAG_SECURE);

  await setupLocator(fromTest: fromTest);
  final delegate = await Localise.getDelegate();
  LwkCore.init();
  BoltzCore.init();
  runApp(
    LocalizedApp(
      delegate,
      const BullBitcoinWalletApp(),
    ),
  );
}
```

## Dependencies

Currently we do not use precompiled binaries with cargokit. So as the end user, you will require cargo and platform specific toolchains to compile the binaries locally.

```bash
# install rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
# install tools
cargo install flutter_rust_bridge_codegen --version 2.9.0
cargo install cargo-ndk
cargo install cargo-lipo
```

For ios builds, make sure you have xcode and cocoapods installed.

## Update & Build process

Add new types to `types.rs` and static functions to `api.rs`

api.rs contains an `Api` struct that holds all the static functions.

types.rs structures and enums are also re-exported via api.rs

```bash
# in the project root directory

./compile.native.sh # build for your native platform (linux/macos). adds binary to dart test folder.

```

## MacOS as host

macos as the host machine can build binaries for all platforms using:

```bash
# requires dockerd running
./compile.all.sh
```

Compile will first build native binaries of the rust code and move them to the dart test folder.

It will then run flutter_rust_bridge_codegen and generate ffi code in rust and dart.

### Non-debian linux users

On non-debian systems you will get some errors with the `bridge_generated.dart` files.

Error would be related to:

```rust
  void store_dart_post_cobject(
    int ptr,
  ) {
    return _store_dart_post_cobject(
      ptr,
    );
  }
```

You may need to set the path the clang in CPATH manually.
Run the following:

```bash
export CPATH="$(clang -v 2>&1 | grep "Selected GCC installation" | rev | cut -d' ' -f1 | rev)/include"
```

## dart classes

Once we have all our structs and functions in dart, we can organize them into classes to improve the UX of the library.

## test

You can now use the `test/boltz-test.dart` file to test whether the expected logic is being exposed correctly over ffi.

Also try `flutter run` in the `example` directory.

### Resources:

- [FRB-Docs](https://cjycode.com/flutter_rust_bridge/v1/index.html)
- [FRB-Codebase](https://github.com/fzyzcjy/flutter_rust_bridge/)
- [Article](https://blog.logrocket.com/using-flutter-rust-bridge-cross-platform-development/)

## Regtest networks

`Chain` distinguishes Bitcoin/Liquid regtest from testnet. New chain swaps take `network: Network` instead of `is_testnet: bool`; the network must match the swap master key before the library contacts Boltz. BTC and Liquid Lightning constructors also require matching chain families and master-key networks.

Persisted chain swaps serialize the canonical `network` field. The updated reader still accepts legacy `is_testnet` booleans, preserving mainnet/testnet keys, scripts and amounts. Missing, unknown or conflicting network fields are rejected. Newly serialized swaps require an updated reader; downgrade compatibility is not guaranteed.

Supply explicit `ElectrumSettings` with `tls: false` for local plaintext Electrum connections, including restored swaps, claims, refunds, size estimates and local broadcast. Chain selection never comes from endpoint URLs. `check_lockup_outspends` accepts an optional explorer URL for the resolved lockup chain; regtest requires it and otherwise fails before network I/O. Mainnet keeps HTTPS enforcement and its existing explorer defaults.

The pinned native dependency supports the default Elements regtest policy asset `5ac9f65c0efcc4775e0baec4ec03abdde22473cd3cf33c0419ca290e0751b225`. A custom regtest genesis with another policy asset needs native dependency support and must not bypass asset validation.
