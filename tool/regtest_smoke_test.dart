// Explicit opt-in integration test against BULL's disposable Podman stack.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:boltz/boltz.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';

const boltzUrl = 'http://127.0.0.1:9001/v2';
const btcElectrum = ElectrumSettings(
    url: '127.0.0.1:50000', validateDomain: false, tls: false, timeout: 10);
const liquidElectrum = ElectrumSettings(
    url: '127.0.0.1:50001', validateDomain: false, tls: false, timeout: 10);

void main() {
  test('real BTC and Liquid submarine, reverse and chain swaps settle',
      () async {
    await BoltzCore.init(
        externalLibrary: ExternalLibrary.open(
            '${Directory.current.path}/rust/target/debug/libboltz.so'));
    final http = HttpClient();
    var index = BigInt.from(Random.secure().nextInt(100000000));
    BigInt nextIndex() {
      final value = index;
      index += BigInt.one;
      return value;
    }

    // The same published deterministic vector used by the package's unit tests.
    // These are disposable regtest keys, never wallet custody material.
    final key = await SwapMasterKey.create(
        walletMnemonic: List.filled(24, 'bacon').join(' '),
        network: Network.regtest);
    Future<dynamic> request(int port, String path,
        [Object? body, bool rpc = false]) async {
      final req = await http.open(
          body == null ? 'GET' : 'POST', '127.0.0.1', port, path);
      req.persistentConnection = false;
      if (rpc) {
        req.headers.set(HttpHeaders.authorizationHeader,
            'Basic ${base64Encode(utf8.encode('admin1:123'))}');
      }
      if (body != null) {
        final bytes = utf8.encode(jsonEncode(body));
        req.headers.contentType = ContentType.json;
        req.contentLength = bytes.length;
        req.add(bytes);
      }
      final response = await req.close().timeout(const Duration(seconds: 30));
      final decoded = jsonDecode(await utf8.decoder.bind(response).join());
      if (response.statusCode != 200) {
        throw StateError('HTTP request failed status=${response.statusCode}');
      }
      return decoded;
    }

    Future<dynamic> rpc(bool liquid, String method,
        [List<Object?> params = const []]) async {
      final body = await request(
          liquid ? 18884 : 18443,
          '/wallet/bull-regtest',
          {'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params},
          true);
      if (body['error'] != null) {
        throw StateError('Regtest RPC failed method=$method');
      }
      return body['result'];
    }

    Future<bool> lightningCaughtUp(int height) async {
      for (final node in ['cln-peer', 'boltz-cln']) {
        final result = await Process.run('podman', [
          '--cgroup-manager=cgroupfs',
          'exec',
          'bull-regtest-$node',
          'lightning-cli',
          '--regtest',
          '--json',
          '--notifications=none',
          'getinfo'
        ]);
        if (result.exitCode != 0 ||
            (jsonDecode(result.stdout as String)['blockheight'] as int) <
                height) {
          return false;
        }
      }
      return true;
    }

    Future<void> mine(bool liquid) async {
      final address = await rpc(liquid, 'getnewaddress');
      await rpc(liquid, 'generatetoaddress', [2, address]);
      final target = await rpc(liquid, 'getblockcount') as int;
      for (var attempt = 0; attempt < 100; attempt++) {
        if ((await request(liquid ? 30001 : 30000, '/blocks/tip/height')
                as int) >=
            target) {
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      throw StateError('Indexer did not catch up');
    }

    Future<Map<String, dynamic>> lightning(List<String> args) async {
      if (args.first == 'pay') {
        final height = await rpc(false, 'getblockcount') as int;
        final deadline = DateTime.now().add(const Duration(seconds: 120));
        while (!await lightningCaughtUp(height)) {
          if (DateTime.now().isAfter(deadline)) {
            throw StateError('Lightning tip did not catch up');
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
      final result = await Process.run('podman', [
        '--cgroup-manager=cgroupfs',
        'exec',
        'bull-regtest-cln-peer',
        'lightning-cli',
        '--regtest',
        '--json',
        '--notifications=none',
        ...args
      ]);
      if (result.exitCode != 0) {
        throw StateError(
            'Lightning operation failed: ${result.stdout.toString().replaceAll(RegExp(r'[a-fA-F0-9]{32,}'), '<hex>')} ${result.stderr.toString().replaceAll(RegExp(r'[a-fA-F0-9]{32,}'), '<hex>')}');
      }
      return jsonDecode(result.stdout as String) as Map<String, dynamic>;
    }

    Future<String> waitStatus(String id, Set<String> accepted) async {
      for (var attempt = 0; attempt < 90; attempt++) {
        final state = await request(9001, '/v2/swap/$id');
        final status = state['status'] as String;
        if (accepted.contains(status)) return status;
        if (status == 'invoice.failedToPay' ||
            status == 'transaction.failed' ||
            status == 'swap.expired') {
          throw StateError('Swap failed status=$status');
        }
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      throw StateError('Swap status deadline exceeded');
    }

    try {
      for (final liquid in [false, true]) {
        final invoice = await lightning([
          'invoice',
          '100000000',
          'smoke-${DateTime.now().microsecondsSinceEpoch}',
          'regtest-smoke'
        ]);
        dynamic swap = liquid
            ? await LbtcLnSwap.newSubmarine(
                swapMasterKey: key,
                index: nextIndex(),
                invoice: invoice['bolt11'] as String,
                network: Chain.liquidRegtest,
                electrumUrl: liquidElectrum.url,
                boltzUrl: boltzUrl)
            : await BtcLnSwap.newSubmarine(
                swapMasterKey: key,
                index: nextIndex(),
                invoice: invoice['bolt11'] as String,
                network: Chain.bitcoinRegtest,
                electrumUrl: btcElectrum.url,
                boltzUrl: boltzUrl);
        final encoded = await swap.toJson() as String;
        swap = liquid
            ? await LbtcLnSwap.fromJson(jsonStr: encoded)
            : await BtcLnSwap.fromJson(jsonStr: encoded);
        await rpc(liquid, 'sendtoaddress', [
          swap.scriptAddress,
          (swap.outAmount as BigInt).toInt() / 100000000
        ]);
        await mine(liquid);
        final status = await waitStatus(swap.id as String,
            {'transaction.claimed', 'transaction.claim.pending'});
        if (status != 'transaction.claimed') {
          try {
            await swap.coopCloseSubmarine();
          } on BoltzError catch (error) {
            print(
                'Cooperative close category=${error.kind}: ${error.message.replaceAll(RegExp(r'[a-fA-F0-9]{32,}'), '<hex>')}');
            rethrow;
          }
          await waitStatus(swap.id as String, {'transaction.claimed'});
        }
        final preimage = await swap.getCompletedSubmarinePreimage() as String;
        expect(preimage.length, 64);
        print('${liquid ? 'Liquid' : 'Bitcoin'} submarine settled');
      }
      for (final liquid in [false, true]) {
        final destination = await rpc(liquid, 'getnewaddress') as String;
        dynamic swap = liquid
            ? await LbtcLnSwap.newReverse(
                swapMasterKey: key,
                index: nextIndex(),
                outAmount: BigInt.from(100000),
                network: Chain.liquidRegtest,
                electrumUrl: liquidElectrum.url,
                boltzUrl: boltzUrl)
            : await BtcLnSwap.newReverse(
                swapMasterKey: key,
                index: nextIndex(),
                outAmount: BigInt.from(100000),
                network: Chain.bitcoinRegtest,
                electrumUrl: btcElectrum.url,
                boltzUrl: boltzUrl);
        final encoded = await swap.toJson() as String;
        swap = liquid
            ? await LbtcLnSwap.fromJson(jsonStr: encoded)
            : await BtcLnSwap.fromJson(jsonStr: encoded);
        final payment = lightning(['pay', swap.invoice as String]);
        await waitStatus(swap.id as String,
            {'transaction.mempool', 'transaction.confirmed'});
        await mine(liquid);
        final signed = await swap.claim(
            outAddress: destination,
            minerFee: const TxFee.relative(1),
            tryCooperate: true,
            electrumSettings: liquid ? liquidElectrum : btcElectrum) as String;
        await swap.broadcastLocal(
            signedHex: signed,
            electrumSettings: liquid ? liquidElectrum : btcElectrum);
        await mine(liquid);
        await payment;
        expect(
            (await rpc(liquid, 'getreceivedbyaddress',
                        liquid ? [destination, 1, 'bitcoin'] : [destination])
                    as num) >
                0,
            isTrue);
        print('${liquid ? 'Liquid' : 'Bitcoin'} reverse claimed');
      }
      for (final direction in ChainSwapDirection.values) {
        final fromLiquid = direction == ChainSwapDirection.lbtcToBtc;
        var swap = await ChainSwap.newSwap(
            direction: direction,
            swapMasterKey: key,
            index: index,
            amount: BigInt.from(100000),
            network: Network.regtest,
            btcElectrumUrl: btcElectrum.url,
            lbtcElectrumUrl: liquidElectrum.url,
            boltzUrl: boltzUrl);
        index += BigInt.two;
        swap = await ChainSwap.fromJson(jsonStr: await swap.toJson());
        // outAmount is the user lockup amount in the existing native API.
        final amount = swap.outAmount;
        await rpc(fromLiquid, 'sendtoaddress',
            [swap.scriptAddress, amount.toInt() / 100000000]);
        await mine(fromLiquid);
        await waitStatus(swap.id,
            {'transaction.server.mempool', 'transaction.server.confirmed'});
        await mine(!fromLiquid);
        final destination = await rpc(!fromLiquid, 'getnewaddress') as String;
        final signed = await swap.claim(
            outAddress: destination,
            minerFee: const TxFee.relative(1),
            tryCooperate: true,
            btcElectrumSettings: btcElectrum,
            lbtcElectrumSettings: liquidElectrum);
        await swap.broadcastLocal(
            signedHex: signed,
            kind: SwapTxKind.claim,
            electrumSettings: fromLiquid ? btcElectrum : liquidElectrum);
        await mine(!fromLiquid);
        expect(
            (await rpc(
                    !fromLiquid,
                    'getreceivedbyaddress',
                    !fromLiquid
                        ? [destination, 1, 'bitcoin']
                        : [destination]) as num) >
                0,
            isTrue);
        print('Chain ${direction.name} claimed');
      }
    } on BoltzError catch (error) {
      print(
          'Native category=${error.kind}: ${error.message.replaceAll(RegExp(r'[a-fA-F0-9]{32,}'), '<hex>')}');
      rethrow;
    } finally {
      http.close(force: true);
      BoltzCore.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 12)));
}
