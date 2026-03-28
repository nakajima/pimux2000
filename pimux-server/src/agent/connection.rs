use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use tokio::{
    sync::mpsc::{UnboundedReceiver, UnboundedSender, unbounded_channel},
    time::sleep,
};
use tokio_tungstenite::{connect_async, tungstenite::Message};

use crate::{
    channel::{AgentToServerMessage, ServerToAgentMessage},
    host::HostIdentity,
};

type BoxError = Box<dyn std::error::Error + Send + Sync>;
const RECONNECT_DELAY: Duration = Duration::from_secs(2);

#[derive(Debug)]
pub enum Event {
    Connected,
    Disconnected,
    Message(ServerToAgentMessage),
}

pub fn start(
    websocket_url: String,
    host: HostIdentity,
    events: UnboundedSender<Event>,
) -> UnboundedSender<AgentToServerMessage> {
    let (outgoing_tx, outgoing_rx) = unbounded_channel();
    tokio::spawn(run(websocket_url, host, outgoing_rx, events));
    outgoing_tx
}

async fn run(
    websocket_url: String,
    host: HostIdentity,
    mut outgoing_rx: UnboundedReceiver<AgentToServerMessage>,
    events: UnboundedSender<Event>,
) {
    loop {
        match connect_async(websocket_url.as_str()).await {
            Ok((stream, _)) => {
                let (mut sender, mut receiver) = stream.split();
                if let Err(error) = send_json(
                    &mut sender,
                    &AgentToServerMessage::Hello { host: host.clone() },
                )
                .await
                {
                    eprintln!("agent websocket hello failed: {error}");
                    sleep(RECONNECT_DELAY).await;
                    continue;
                }

                let _ = events.send(Event::Connected);

                loop {
                    tokio::select! {
                        maybe_outgoing = outgoing_rx.recv() => {
                            match maybe_outgoing {
                                Some(message) => {
                                    if let Err(error) = send_json(&mut sender, &message).await {
                                        eprintln!("agent websocket send failed: {error}");
                                        break;
                                    }
                                }
                                None => return,
                            }
                        }
                        maybe_incoming = receiver.next() => {
                            match maybe_incoming {
                                Some(Ok(Message::Text(text))) => {
                                    match serde_json::from_str::<ServerToAgentMessage>(&text) {
                                        Ok(message) => {
                                            let _ = events.send(Event::Message(message));
                                        }
                                        Err(error) => {
                                            eprintln!("invalid server websocket message: {error}");
                                        }
                                    }
                                }
                                Some(Ok(Message::Ping(_))) | Some(Ok(Message::Pong(_))) | Some(Ok(Message::Binary(_))) | Some(Ok(Message::Frame(_))) => {}
                                Some(Ok(Message::Close(_))) => break,
                                Some(Err(error)) => {
                                    eprintln!("agent websocket receive failed: {error}");
                                    break;
                                }
                                None => break,
                            }
                        }
                    }
                }

                let _ = events.send(Event::Disconnected);
            }
            Err(error) => {
                eprintln!("agent websocket connect failed: {error}");
            }
        }

        sleep(RECONNECT_DELAY).await;
    }
}

async fn send_json(
    sender: &mut futures_util::stream::SplitSink<
        tokio_tungstenite::WebSocketStream<
            tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
        >,
        Message,
    >,
    message: &AgentToServerMessage,
) -> Result<(), BoxError> {
    let payload = serde_json::to_string(message)?;
    sender.send(Message::Text(payload)).await?;
    Ok(())
}
