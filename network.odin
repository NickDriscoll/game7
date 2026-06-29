package main

import "core:c"
import "core:c/libc"
import "core:mem"
import "core:net"
import "core:log"
import "core:math/linalg/hlsl"
import "core:os"
import "core:strings"
import enet "vendor:ENet"
import imgui "odin-imgui"

@(private)
float3 :: hlsl.float3

BROADCAST_PORT :: 64209
SERVER_PORT :: 42690
MAX_SERVER_PEERS :: 4       // Four players can connect to server

BroadcastClientPacket :: struct {
    ip: u32,
}

BroadcastResponse :: struct {
    my_ip: u32      // Big-endian (network order)
}

ClientUpdatePacket :: struct {
    position: [3]f32,
    local_player_id: u8,
}

Network :: struct {
    // Buffers for imgui.InputText cstrings
    server_ip: [256]u8,
    username: [256]u8,

    broadcast_listener: enet.Socket,
    broadcast_sender: enet.Socket,
    listen_address: enet.Address,

    server: ^enet.Host,
    server_peer: ^enet.Peer,

    client: ^enet.Host,
    client_peer: ^enet.Peer,

    remote_players: [dynamic]EntityID,
    my_ip: net.IP4_Address,
}

network_init :: proc(user_config: UserConfiguration, allocator := context.allocator) -> Network {
    network: Network
    network.remote_players = make([dynamic]EntityID, 0, 16, allocator)

    errcode := enet.initialize()
    assert(errcode == 0)

    network.server_ip[0] = '1'
    network.server_ip[1] = '2'
    network.server_ip[2] = '7'
    network.server_ip[3] = '.'
    network.server_ip[4] = '0'
    network.server_ip[5] = '.'
    network.server_ip[6] = '0'
    network.server_ip[7] = '.'
    network.server_ip[8] = '1'

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

    // Socket used for advertising server address
    network.broadcast_sender = enet.socket_create(.DATAGRAM)
    enet.socket_set_option(network.broadcast_sender, .BROADCAST, 1)

    server_addr := enet.Address {
        host = enet.HOST_ANY,
        port = SERVER_PORT,
    }
    network.server = enet.host_create(&server_addr, MAX_SERVER_PEERS, 2, 0, 0)
    if network.server == nil {
        log.error("Unable to create ENet server host. Is another copy of the game running on this machine?")
    }

    return network
}

NetworkVerb :: enum {
    PlayerUpdate,
    PlayerAdded,
}

NetworkOutput :: struct {
    bool_update: map[NetworkVerb]bool,
    float3_update: map[NetworkVerb]hlsl.float3,
}

// Once-per-frame servicing of ENet hosts
poll_network :: proc(network: ^Network, game_state: ^GameState, allocator := context.temp_allocator) -> NetworkOutput {
    output: NetworkOutput
    output.bool_update = make(map[NetworkVerb]bool, 16, allocator)
    output.float3_update = make(map[NetworkVerb]hlsl.float3, 16, allocator)

    event: enet.Event
    if network.server != nil {
        for enet.host_service(network.server, &event, 0) > 0 {
            switch event.type {
                case .NONE: { assert(false, "Should be unreachable") }
                case .CONNECT: {
                    network.server_peer = event.peer
                    log.infof("Server got connection from connect id %v", event.peer.connectID)
                    id := gamestate_next_id(game_state)
                    append(&network.remote_players, id)
                    game_state.transforms[id] = Transform {
                        scale = 1.0
                    }
                    game_state.skinned_models[id] = SkinnedModelInstance {
                        handle = game_state.player_mesh,
                        pos_offset = {0.0, 0.0, -0.6},
                        flags = {}
                    }
                    append(&network.remote_players, id)

                    log.infof("Peer address %v",  to_net_addr(event.peer.address))
                    //connect_client(network, event.peer.address)
                    network.client_peer = network.server_peer
                }
                case .DISCONNECT: {
                    log.info("Disconnect event")
                }
                case .RECEIVE: {
                    defer enet.packet_destroy(event.packet)
                    addr := event.peer.address
                    net_addr := to_net_addr(addr)

                    log.infof("Received packet from %v", net_addr)
                }
            }
        }

        // Send player position to clients
        if network.server_peer != nil {
            for player_id, idx in game_state.local_players {
                tfrom, ok := game_state.transforms[player_id]
                assert(ok)
                assert(idx < 256)
                packet_data := ClientUpdatePacket {
                    local_player_id = u8(idx),
                    position = tfrom.position
                }
                packet := enet.packet_create(&tfrom.position, size_of(tfrom.position), {})
                errcode := enet.peer_send(network.server_peer, 0, packet)
                assert(errcode == 0)
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
                    defer enet.packet_destroy(event.packet)
                    addr := event.peer.address
                    net_addr := to_net_addr(addr)

                    con_id := event.peer.connectID

                    assert(event.packet.dataLength == size_of(hlsl.float3))
                    cpacket := cast(^ClientUpdatePacket)event.packet.data
                    //output.float3_update[.PlayerUpdate] = cpacket.position
                    if len(network.remote_players) < int(cpacket.local_player_id) {
                        tform, ok := game_state.transforms[network.remote_players[cpacket.local_player_id]]
                        tform.position = cpacket.position
                    }

                    //log.infof("Packet value received: %v", cpacket.position)
                }
            }
        }
    }

    return output
}

connect_client_net :: proc(network: ^Network, addr: net.Address) {
    network.client = enet.host_create(nil, 1, 2, 0, 0)
    assert(network.client != nil)

    ip4_addr := addr.(net.IP4_Address)
    peer_addr := enet.Address {
        host = (cast(^u32)(&ip4_addr[0]))^,
        port = SERVER_PORT,
    }
    connect_client_enet(network, peer_addr)
}

connect_client_enet :: proc(network: ^Network, addr: enet.Address) {
    addr := addr
    network.client_peer = enet.host_connect(network.client, &addr, 2, 0)
    if network.client_peer == nil {
        log.errorf("Unable to connect to host.")
    }
}

connect_client :: proc {
    connect_client_enet,
    connect_client_net,
}

network_gui :: proc(network: ^Network, p_open: ^bool) {
    defer imgui.End()
    if imgui.Begin("Network", p_open) {
        server_ip_string: string
        {
            cs : cstring = strings.unsafe_string_to_cstring(string(network.server_ip[:]))
            server_ip_string = string(cs)
            imgui.InputText("Enter remote IP", cs, len(network.server_ip))
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
    
            connect_client(network, remote_addr.address)
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
        if bytes_received > 0 {
            response = true
            recv_username := string(recvbuf[:bytes_received])
            log.infof("Received username: \"%v\"", recv_username)
        }
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