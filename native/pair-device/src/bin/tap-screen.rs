//! One explicitly requested touch through the trusted CoreDevice connection.
//! Coordinates are normalized 0..65535 in the device touchscreen space.
use idevice::{IdeviceService, RsdService,
    core_device_proxy::CoreDeviceProxy,
    core_device::{DisplayServiceClient, UniversalHidServiceClient, CallInfoBlob,
        build_screen_audio_offer, build_screen_video_offer,
        build_start_audio_parameters, build_start_video_parameters},
    rsd::RsdHandshake,
    usbmuxd::{UsbmuxdAddr, UsbmuxdConnection}};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = std::env::args().collect();
    if args.len()!=4 { return Err("Usage: tap-screen UDID X_U16 Y_U16".into()); }
    let x:u16=args[2].parse()?;let y:u16=args[3].parse()?;
    let mut mux=UsbmuxdConnection::default().await?;
    let device=mux.get_device(&args[1]).await?;
    let provider=device.to_provider(UsbmuxdAddr::from_env_var()?, "Bitwig native touch check");
    let proxy=CoreDeviceProxy::connect(&provider).await?;
    let receiver=proxy.tunnel_info().client_address.clone();
    let sender=proxy.tunnel_info().server_address.clone();
    let port=proxy.tunnel_info().server_rsd_port;
    let mut adapter=proxy.create_software_tunnel()?.to_async_handle();
    let mut handshake=RsdHandshake::new(adapter.connect(port).await?).await?;
    let mut display=DisplayServiceClient::connect_rsd(&mut adapter,&mut handshake).await?;
    let status=display.get_media_stream_server_status().await?;
    // Never replace a screen-sharing session owned by the user or another tool.
    if status.as_dictionary().is_some_and(|d|d.contains_key("streamConfig")) {
        return Err("An existing media stream is active; leaving it untouched".into());
    }
    let session=uuid::Uuid::new_v4();let call=session.to_string();
    let info=CallInfoBlob {call_id:session.as_u128() as u32,device_type:"Mac".into(),
        device_name:Some("Bitwig native touch check".into()),..Default::default()};
    let audio=build_screen_audio_offer(&call,&info)?;
    let video=build_screen_video_offer(&call,&info,session.as_u128() as u32)?;
    let operation=async {
        display.start_media_stream(build_start_audio_parameters(&receiver,55000,&sender,55001,audio,0,session)).await?;
        display.start_media_stream(build_start_video_parameters(&receiver,55002,&sender,55003,video,0,1,session)).await?;
        let mut hid=UniversalHidServiceClient::connect_rsd(&mut adapter,&mut handshake).await?;
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        hid.tap(x,y).await?;
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        Ok::<(),idevice::IdeviceError>(())
    };
    let result=tokio::time::timeout(std::time::Duration::from_secs(20),operation).await;
    let stopped=display.stop_media_stream().await;
    result??;stopped?;
    println!("Touch sent; temporary media stream stopped");
    Ok(())
}
