//! Explicit touch frames through the trusted CoreDevice connection.
//! Coordinates are normalized 0..65535 in the device touchscreen space.
use idevice::{
    core_device::{
        build_screen_audio_offer, build_screen_video_offer, build_start_audio_parameters,
        build_start_video_parameters, CallInfoBlob, DisplayServiceClient, TouchscreenContact,
        UniversalHidServiceClient,
    },
    core_device_proxy::CoreDeviceProxy,
    rsd::RsdHandshake,
    usbmuxd::{UsbmuxdAddr, UsbmuxdConnection},
    IdeviceService, RsdService,
};

use std::{collections::BTreeSet, error::Error, time::Duration};

enum Input {
    Tap(u16, u16),
    Frames(Vec<(Duration, Vec<TouchscreenContact>)>),
}

fn parse_frames(args: &[String]) -> Result<Input, Box<dyn Error>> {
    let mut active = BTreeSet::new();
    let mut total = 0u64;
    let mut frames = Vec::new();
    for frame in args {
        let (delay, entries) = frame
            .split_once(':')
            .ok_or("Expected MS:ID,X,Y,STATE[;…]")?;
        let delay: u64 = delay.parse()?;
        total = total.checked_add(delay).ok_or("Invalid total delay")?;
        if total > 12000 {
            return Err("Touch sequence exceeds 12 seconds".into());
        }
        let mut reported = BTreeSet::new();
        let mut contacts = Vec::new();
        for entry in entries.split(';') {
            let fields: Vec<_> = entry.split(',').collect();
            let [identity, x, y, state] = fields.as_slice() else {
                return Err("Expected ID,X,Y,STATE for each contact".into());
            };
            let identity: u8 = identity.parse()?;
            if identity >= 5 || !reported.insert(identity) {
                return Err("Each frame requires unique contact IDs in 0 through 4".into());
            }
            let touching = match *state {
                "down" => true,
                "up" if active.contains(&identity) => false,
                _ => return Err("Use down or release a currently active contact with up".into()),
            };
            contacts.push(TouchscreenContact {
                identity,
                x: x.parse()?,
                y: y.parse()?,
                touching,
            });
        }
        if !active.is_subset(&reported) {
            return Err("Every active contact must appear in the next frame".into());
        }
        active = contacts
            .iter()
            .filter(|contact| contact.touching)
            .map(|contact| contact.identity)
            .collect();
        frames.push((Duration::from_millis(delay), contacts));
    }
    if frames.is_empty() || !active.is_empty() {
        return Err("Supply at least one frame and release all contacts".into());
    }
    Ok(Input::Frames(frames))
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = std::env::args().collect();
    let input =
        match args.as_slice() {
            [_, _, mode, frames @ ..] if mode == "--frames" => parse_frames(frames)?,
            [_, _, x, y] => Input::Tap(x.parse()?, y.parse()?),
            _ => return Err(
                "Usage: tap-screen UDID X_U16 Y_U16 | --frames 'MS:ID,X,Y,down;…' 'MS:ID,X,Y,up;…'"
                    .into(),
            ),
        };
    let mut mux = UsbmuxdConnection::default().await?;
    let device = mux.get_device(&args[1]).await?;
    let provider = device.to_provider(UsbmuxdAddr::from_env_var()?, "Bitwig native touch check");
    let proxy = CoreDeviceProxy::connect(&provider).await?;
    let receiver = proxy.tunnel_info().client_address.clone();
    let sender = proxy.tunnel_info().server_address.clone();
    let port = proxy.tunnel_info().server_rsd_port;
    let mut adapter = proxy.create_software_tunnel()?.to_async_handle();
    let mut handshake = RsdHandshake::new(adapter.connect(port).await?).await?;
    let mut display = DisplayServiceClient::connect_rsd(&mut adapter, &mut handshake).await?;
    let status = display.get_media_stream_server_status().await?;
    // Never replace a screen-sharing session owned by the user or another tool.
    if status
        .as_dictionary()
        .is_some_and(|d| d.contains_key("streamConfig"))
    {
        return Err("An existing media stream is active; leaving it untouched".into());
    }
    let session = uuid::Uuid::new_v4();
    let call = session.to_string();
    let info = CallInfoBlob {
        call_id: session.as_u128() as u32,
        device_type: "Mac".into(),
        device_name: Some("Bitwig native touch check".into()),
        ..Default::default()
    };
    let audio = build_screen_audio_offer(&call, &info)?;
    let video = build_screen_video_offer(&call, &info, session.as_u128() as u32)?;
    let operation = async {
        display
            .start_media_stream(build_start_audio_parameters(
                &receiver, 55000, &sender, 55001, audio, 0, session,
            ))
            .await?;
        display
            .start_media_stream(build_start_video_parameters(
                &receiver, 55002, &sender, 55003, video, 0, 1, session,
            ))
            .await?;
        let mut hid = UniversalHidServiceClient::connect_rsd(&mut adapter, &mut handshake).await?;
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        match input {
            Input::Tap(x, y) => hid.tap(x, y).await?,
            Input::Frames(frames) => {
                for (delay, contacts) in frames {
                    tokio::time::sleep(delay).await;
                    hid.send_multitouch(&contacts, None).await?;
                }
            }
        }
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        Ok::<(), idevice::IdeviceError>(())
    };
    let result = tokio::time::timeout(std::time::Duration::from_secs(20), operation).await;
    let stopped = display.stop_media_stream().await;
    result??;
    stopped?;
    println!("Touch sent; temporary media stream stopped");
    Ok(())
}
