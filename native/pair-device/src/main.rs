//! Creates a remote pairing record through the iPad's existing trusted transport.
//! Uses idevice's official CoreDeviceProxy / RPPairing flow; never prints keys.
use idevice::{IdeviceService, RemoteXpcClient,
    core_device_proxy::CoreDeviceProxy,
    remote_pairing::{RemotePairingClient, RpPairingFile},
    rsd::RsdHandshake,
    usbmuxd::{UsbmuxdAddr, UsbmuxdConnection}};
use std::{fs::OpenOptions, io::Write, os::unix::fs::OpenOptionsExt};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 3 { return Err("Usage: bitwig-pair-device UDID OUTPUT.plist".into()); }
    let mut mux = UsbmuxdConnection::default().await?;
    let device = mux.get_device(&args[1]).await?;
    let provider = device.to_provider(UsbmuxdAddr::from_env_var()?, "Bitwig native iPad setup");
    println!("Connecting through the existing trusted device transport");
    let proxy = CoreDeviceProxy::connect(&provider).await?;
    let port = proxy.tunnel_info().server_rsd_port;
    let mut adapter = proxy.create_software_tunnel()?.to_async_handle();
    let handshake = RsdHandshake::new(adapter.connect(port).await?).await?;
    let service = handshake.services.get("com.apple.internal.dt.coredevice.untrusted.tunnelservice")
        .ok_or("Remote pairing service unavailable")?;
    let mut connection = RemoteXpcClient::new(adapter.connect(service.port).await?).await?;
    connection.do_handshake().await?;
    let _ = connection.recv_root().await;
    let mut record = RpPairingFile::generate("Bitwig native iPad setup");
    let mut pairing = RemotePairingClient::new(connection, "Bitwig native iPad setup");
    tokio::time::timeout(std::time::Duration::from_secs(300), async {
        println!("Negotiating Remote Pairing protocol");
        pairing.attempt_pair_verify().await?;
        println!("Checking the new host identity");
        if pairing.validate_pairing(&mut record).await.is_err() {
            println!("Requesting iPadOS pairing consent; approve Trust on the iPad");
            pairing.pair(&mut record, async || "000000".to_string()).await?;
        }
        Ok::<(), idevice::IdeviceError>(())
    }).await??;
    let mut output = OpenOptions::new().create_new(true).write(true).mode(0o600).open(&args[2])?;
    output.write_all(&record.to_bytes())?;
    println!("Remote pairing record saved privately");
    Ok(())
}
