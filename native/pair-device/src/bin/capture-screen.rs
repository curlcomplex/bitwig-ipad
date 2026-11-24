//! Read-only screenshot using the device's CoreDevice screenshot service.
use idevice::{IdeviceService, RsdService,
    core_device_proxy::CoreDeviceProxy,
    core_device::{ImageFormat, ScreenCaptureServiceClient},
    rsd::RsdHandshake,
    usbmuxd::{UsbmuxdAddr, UsbmuxdConnection}};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 3 { return Err("Usage: capture-screen UDID OUTPUT.png".into()); }
    let mut mux = UsbmuxdConnection::default().await?;
    let device = mux.get_device(&args[1]).await?;
    let provider = device.to_provider(UsbmuxdAddr::from_env_var()?, "Bitwig native screen check");
    let capture = async {
        let proxy = CoreDeviceProxy::connect(&provider).await?;
        let port = proxy.tunnel_info().server_rsd_port;
        let mut adapter = proxy.create_software_tunnel()?.to_async_handle();
        let mut handshake = RsdHandshake::new(adapter.connect(port).await?).await?;
        let mut client = ScreenCaptureServiceClient::connect_rsd(&mut adapter, &mut handshake).await?;
        client.take_screenshot(None, ImageFormat::Png).await
    };
    let bytes = tokio::time::timeout(std::time::Duration::from_secs(30), capture).await??;
    std::fs::write(&args[2], &bytes)?;
    println!("Saved native device screenshot ({} bytes)", bytes.len());
    Ok(())
}
