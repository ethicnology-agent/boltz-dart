use boltz::api::{
    btc_ln::BtcLnSwap,
    lbtc_ln::LbtcLnSwap,
    secrets::KeyPair,
    types::{BtcSwapScriptStr, Chain, LBtcSwapScriptStr, PreImage, SwapType},
};
use boltz_client::bitcoin::secp256k1::{PublicKey, Secp256k1, SecretKey};
use boltz_client::util::secrets::Preimage;
use std::io::{Read, Write};
use std::str::FromStr;

// Deterministic public test material, never an application's wallet keys.
fn serve_preimage(valid: bool) -> (String, PreImage, String, String) {
    let preimage = Preimage::from_str(&hex::encode([3; 32])).unwrap();
    let public =
        PublicKey::from_secret_key(&Secp256k1::new(), &SecretKey::from_slice(&[1; 32]).unwrap())
            .to_string();
    let hash = preimage.hash160.to_string();
    let stored = PreImage {
        value: String::new(),
        sha256: preimage.sha256.to_string(),
        hash160: hash.clone(),
    };
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}/v2", listener.local_addr().unwrap());
    std::thread::spawn(move || {
        let (mut socket, _) = listener.accept().unwrap();
        let mut buffer = [0; 4096];
        let count = socket.read(&mut buffer).unwrap();
        let request = String::from_utf8_lossy(&buffer[..count]);
        let correct_route = request.starts_with("GET /v2/swap/submarine/fixture/preimage ");
        let status = if correct_route { 200 } else { 400 };
        let body = if correct_route {
            format!(
                r#"{{"preimage":"{}"}}"#,
                hex::encode([if valid { 3 } else { 4 }; 32])
            )
        } else {
            r#"{"error":"swap not eligible for a cooperative claim"}"#.to_owned()
        };
        write!(socket, "HTTP/1.1 {status} Response\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).unwrap();
    });
    (url, stored, hash, public)
}

#[tokio::test]
async fn completed_submarine_uses_preimage_endpoint_and_verifies_hashes() {
    for liquid in [false, true] {
        for valid in [true, false] {
            let (url, preimage, hashlock, public) = serve_preimage(valid);
            let keys = KeyPair {
                secret_key: String::new(),
                public_key: public.clone(),
            };
            let result = if liquid {
                let script = LBtcSwapScriptStr {
                    swap_type: SwapType::Submarine,
                    funding_addrs: None,
                    hashlock,
                    receiver_pubkey: public.clone(),
                    locktime: 100,
                    sender_pubkey: public,
                    blinding_key: hex::encode([1; 32]),
                    side: None,
                };
                let swap = LbtcLnSwap::new(
                    "fixture".into(),
                    SwapType::Submarine,
                    Chain::LiquidTestnet,
                    keys,
                    0,
                    preimage,
                    script,
                    String::new(),
                    10000,
                    String::new(),
                    hex::encode([1; 32]),
                    String::new(),
                    url,
                    None,
                );
                swap.get_completed_submarine_preimage().await
            } else {
                let script = BtcSwapScriptStr {
                    swap_type: SwapType::Submarine,
                    funding_addrs: None,
                    hashlock,
                    receiver_pubkey: public.clone(),
                    locktime: 100,
                    sender_pubkey: public,
                    side: None,
                };
                let swap = BtcLnSwap::new(
                    "fixture".into(),
                    SwapType::Submarine,
                    Chain::BitcoinTestnet,
                    keys,
                    0,
                    preimage,
                    script,
                    String::new(),
                    String::new(),
                    10000,
                    String::new(),
                    url,
                    None,
                );
                swap.get_completed_submarine_preimage().await
            };
            assert_eq!(result.is_ok(), valid, "completed swaps use the preimage endpoint and validate its hash");
            if !valid {
                assert_eq!(result.err().unwrap().kind, "Protocol");
            }
        }
    }
}
