package main

import "core:net"
import "core:log"
import "core:strings"
import enet "vendor:ENet"
import imgui "odin-imgui"

BROADCAST_PORT :: 64209
SERVER_PORT :: 42690

BroadcastResponse :: struct {
    my_ip: u32      // Big-endian (network order)
}

Network :: struct {
    server_ip: [256]u8,
    username: [256]u8,
    broadcast_listener: enet.Socket,
    broadcast_sender: enet.Socket,
    listen_address: enet.Address,
    server: ^enet.Host,
    server_peer: ^enet.Peer,
    client: ^enet.Host,
    client_peer: ^enet.Peer,
    my_ip: net.IP4_Address,
}

network_init :: proc() -> Network {
    network: Network

    errcode := enet.initialize()
    assert(errcode == 0)

    network.broadcast_listener = enet.socket_create(.DATAGRAM)
    network.listen_address = enet.Address {
        host = enet.HOST_ANY,
        port = BROADCAST_PORT
    }
    errcode = enet.socket_set_option(network.broadcast_listener, .NONBLOCK, 1)
    assert(errcode == 0)
    errcode = enet.socket_set_option(network.broadcast_listener, .REUSEADDR, 1)
    assert(errcode == 0)
    errcode = enet.socket_bind(network.broadcast_listener, &network.listen_address)
    assert(errcode == 0)

    network.broadcast_sender = enet.socket_create(.DATAGRAM)
    enet.socket_set_option(network.broadcast_sender, .BROADCAST, 1)

    server_addr := enet.Address {
        host = enet.HOST_ANY,
        port = SERVER_PORT,
    }
    network.server = enet.host_create(&server_addr, 1, 2, 0, 0)
    if network.server == nil {
        log.error("Unable to create ENet server host. Is another copy of the game running on this machine?")
    }

    return network
}

network_input :: proc(network: ^Network) {
    event: enet.Event
    if network.server != nil {
        for enet.host_service(network.server, &event, 0) > 0 {

            switch event.type {
                case .NONE: {}
                case .CONNECT: {
                    network.server_peer = event.peer
                    log.infof("Server Got connection from session id %v", event.peer.incomingSessionID)
                }
                case .DISCONNECT: {
                    log.info("Disconnect event")
                }
                case .RECEIVE: {
                    log.info("Received packet I think")
                }
            }
        }
    }
    if network.client != nil {
        for enet.host_service(network.client, &event, 0) > 0 {
            switch event.type {
                case .NONE: {}
                case .CONNECT: {
                    addr_str := net.to_string(to_net_addr(event.peer.address))
                    log.infof("Client Got connection from %v", addr_str)
                }
                case .DISCONNECT: {
                    log.info("Disconnect event")
                }
                case .RECEIVE: {
                    log.info("Received packet I think")
                }
            }
        }
    }
}

network_gui :: proc(network: ^Network) {
    server_ip_string: string
    {
        cs : cstring = strings.unsafe_string_to_cstring(string(network.server_ip[:]))
        server_ip_string = string(cs)
        imgui.InputText("Enter IP to connect to", cs, len(network.server_ip))
    }
    name_string: string
    {
        cs : cstring = strings.unsafe_string_to_cstring(string(network.username[:]))
        name_string = string(cs)
        imgui.InputText("Enter username", cs, len(network.username))
    }

    imgui.BeginDisabled(network.client_peer != nil || len(server_ip_string) == 0)
    if imgui.Button("Connect to remote game") {
        remote_addr, ok := net.parse_endpoint(server_ip_string)
        assert(ok)
        
        network.client = enet.host_create(nil, 1, 2, 0, 0)
        assert(network.client != nil)

        ip4_addr := remote_addr.address.(net.IP4_Address)
        peer_addr := enet.Address {
            host = (cast(^u32)(&ip4_addr[0]))^,
            port = SERVER_PORT,
        }
        network.client_peer = enet.host_connect(network.client, &peer_addr, 2, 0)
        if network.client_peer == nil {
            log.errorf("Unable to connect to host.")
        }
    }
    imgui.EndDisabled()

    imgui.BeginDisabled(len(name_string) == 0)
    if imgui.Button("Broadcast discovery packet") {
        addr := enet.Address {
            host = enet.HOST_BROADCAST,
            port = BROADCAST_PORT,
        }
        b := enet.Buffer {
            data = raw_data(name_string),
            dataLength = len(name_string)
        }

        errcode := enet.socket_connect(network.broadcast_sender, &addr)
        assert(errcode == 0)
        bytes_sent := enet.socket_send(network.broadcast_sender, &addr, &b, 1)
        assert(uint(bytes_sent) == b.dataLength)
    }
    imgui.EndDisabled()

    @static response := false
    if response {
        imgui.Text("Response received!")
    } else {
        imgui.Text("No response yet...")
    }

    recvbuf: [256]u8
    b := enet.Buffer {
        data = &recvbuf,
        dataLength = len(recvbuf)
    }
    bytes_received := enet.socket_receive(network.broadcast_listener, &network.listen_address, &b, 1)
    if bytes_received == 4 {
        ip := (cast(^u32)&recvbuf[0])^
        log.infof("IP received: %v.%v.%v.%v", ip % 0xFF, (ip >> 8) % 0xFF, (ip >> 16) % 0xFF, (ip >> 24) % 0xFF)
    } else if bytes_received > 0 {
        response = true
        recv_username := string(recvbuf[:bytes_received])
        log.infof("Received username: %v", recv_username)
    }
}

to_enet_addr :: proc(addr: net.Address) -> enet.Address {
    ip4_addr := addr.(net.IP4_Address)
    return enet.Address {
        host = (cast(^u32)(&ip4_addr[0]))^,
        port = SERVER_PORT,
    }
}

to_net_addr :: proc(addr: enet.Address) -> net.Address {
    return net.IP4_Address {
        u8(addr.host) & 0xFF,
        u8(addr.host >> 8) & 0xFF,
        u8(addr.host >> 16) & 0xFF,
        u8(addr.host >> 24) & 0xFF
    }
}