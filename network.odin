package main

import "core:fmt"
import "core:mem"
import "core:net"
import "core:log"
import "core:math/linalg/hlsl"
import "core:strings"
import "core:time"
import enet "vendor:ENet"
import imgui "odin-imgui"

@(private)
float3 :: hlsl.float3

BROADCAST_PORT :: 64209
SERVER_PORT :: 42690
MAX_SERVER_PEERS :: 4       // Four players can connect to server
MAX_BROADCAST_RESPONSES :: 20

BroadcastMeaning :: enum u8 {
    ClientQuery,
    ServerResponse,
}
ClientID :: distinct i64
BroadcastPacket :: struct {
    meaning: BroadcastMeaning,
    client_id: ClientID,
    payload: string,
}
serialize_broadcast_packet :: proc(p: ^BroadcastPacket, allocator := context.temp_allocator) -> [dynamic]byte {
    bytes := make([dynamic]byte, size_of(BroadcastMeaning) + size_of(ClientID) + len(p.payload), allocator)
    bytes[0] = byte(p.meaning)
    mem.copy_non_overlapping(&bytes[size_of(BroadcastMeaning)], &p.client_id, size_of(ClientID))
    mem.copy_non_overlapping(&bytes[size_of(BroadcastMeaning) + size_of(ClientID)], raw_data(p.payload), len(p.payload))
    return bytes
}
deserialize_broadcast_packet :: proc(bytes: []byte) -> BroadcastPacket {
    packet: BroadcastPacket

    packet.meaning = BroadcastMeaning(bytes[0])
    packet.client_id = (cast(^ClientID)(&bytes[1]))^
    packet.payload = string(bytes[size_of(ClientID) + size_of(BroadcastMeaning):])

    return packet
}

LANServer :: struct {
    ip_address: enet.Address,
    username: [256]u8,
    level_name: [256]u8,
}

ClientUpdatePacket :: struct {
    position: float3,
    anim_t: f32,
    rotation: quaternion128,
    anim_idx: u32,
    local_player_id: u8,
}

Network :: struct {
    // Buffers for imgui.InputText cstrings
    server_ip: [256]u8,
    username: [256]u8,
    
    recv_message: [256]u8,

    broadcast_listener: enet.Socket,
    broadcast_sender: enet.Socket,
    listen_address: enet.Address,
    lan_servers: [dynamic; MAX_BROADCAST_RESPONSES]LANServer,

    host: ^enet.Host,
    one_and_only_peer: ^enet.Peer,

    remote_players: [dynamic; MAX_SPLITSCREEN_PLAYERS]EntityID,
    my_ip: net.IP4_Address,

    _unique_id: ClientID,
}

network_init :: proc(user_config: UserConfiguration, allocator := context.allocator) -> Network {
    network: Network
    network._unique_id = ClientID(time.now()._nsec)

    errcode := enet.initialize()
    assert(errcode == 0)

    network.server_ip[0] = '1'
    network.server_ip[1] = '9'
    network.server_ip[2] = '2'
    network.server_ip[3] = '.'
    network.server_ip[4] = '1'
    network.server_ip[5] = '6'
    network.server_ip[6] = '8'
    network.server_ip[7] = '.'
    network.server_ip[8] = '1'
    network.server_ip[9] = '.'
    network.server_ip[10] = '2'
    network.server_ip[11] = '1'
    network.server_ip[12] = '4'

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

    is_server := true
    if is_server {
        server_addr := enet.Address {
            host = enet.HOST_ANY,
            port = SERVER_PORT,
        }
        network.host = enet.host_create(&server_addr, MAX_SERVER_PEERS, 2, 0, 0)
        if network.host == nil {
            log.error("Unable to create ENet server host. Is another copy of the game running on this machine?")
        }
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
poll_network :: proc(app: ^App, allocator := context.temp_allocator) -> NetworkOutput {
    output: NetworkOutput
    output.bool_update = make(map[NetworkVerb]bool, 16, allocator)
    output.float3_update = make(map[NetworkVerb]hlsl.float3, 16, allocator)

    network := &app.network
    game_state := &app.game_state

    event: enet.Event
    if network.host != nil {
        // Server advertisement / UDP broadcast handling
        {
            recvbuf: [size_of(BroadcastPacket)]u8
            b := enet.Buffer {
                data = &recvbuf,
                dataLength = len(recvbuf)
            }
            retaddr: enet.Address
            bytes_received := enet.socket_receive(network.broadcast_listener, &retaddr, &b, 1)
            for bytes_received > 0 {
                defer bytes_received = enet.socket_receive(network.broadcast_listener, &retaddr, &b, 1)
                assert(bytes_received == size_of(BroadcastPacket))
                packet := deserialize_broadcast_packet(recvbuf[0:bytes_received])
                // Ignore broadcasts that came from ourself
                if packet.client_id != network._unique_id {
                    switch packet.meaning {
                        case .ClientQuery: {
                            recv_username := packet.payload
                            log.infof("Received username: \"%v\" from address %v", recv_username, address_string(retaddr))
                            mem.copy_non_overlapping(&network.recv_message[0], raw_data(recv_username), len(recv_username))
                            network.recv_message[len(recv_username)] = 0
            
                            // Send response packet
                            addr := enet.Address {
                                host = enet.HOST_BROADCAST,
                                port = BROADCAST_PORT,
                            }
                            p := BroadcastPacket {
                                meaning = .ServerResponse,
                                client_id = network._unique_id,
                                payload = app.current_level
                            }
                            bytes := serialize_broadcast_packet(&p)
                            b2 := enet.Buffer {
                                data = raw_data(bytes),
                                dataLength = len(bytes)
                            }
                    
                            errcode := enet.socket_connect(network.broadcast_sender, &addr)
                            assert(errcode == 0)
                            bytes_sent := enet.socket_send(network.broadcast_sender, &addr, &b2, 1)
                            assert(uint(bytes_sent) == b2.dataLength)
                        }
                        case .ServerResponse: {
                            log.infof("Game7 peer at %v said \"%v\"", address_string(retaddr), packet.payload)

                            new_server: LANServer
                            new_server.ip_address = retaddr
                            new_server.username[0] = 'N'
                            new_server.username[1] = '/'
                            new_server.username[2] = 'A'
                            mem.copy_non_overlapping(&new_server.level_name[0], raw_data(packet.payload), len(packet.payload))
                            append(&network.lan_servers, new_server)
                        }
                    }
                }

            }
        }

        // Service host events
        for enet.host_service(network.host, &event, 0) > 0 {
            switch event.type {
                case .NONE: { assert(false, "Should be unreachable") }
                case .CONNECT: {
                    network.one_and_only_peer = event.peer
                    log.infof("Got connection from connect id %v", event.peer.connectID)
                    for _ in 0..<MAX_SPLITSCREEN_PLAYERS {
                        id := gamestate_next_id(game_state)
                        game_state.transforms[id] = Transform {
                            position = {f32(0xFFFFFFFF), f32(0xFFFFFFFF), f32(0xFFFFFFFF)},
                            scale = 1.0
                        }
                        game_state.skinned_models[id] = SkinnedModelInstance {
                            handle = game_state.player_mesh,
                            pos_offset = {0.0, 0.0, -0.6},
                            flags = {}
                        }
                        append(&network.remote_players, id)
                    }

                    log.infof("Peer address %v",  to_net_addr(event.peer.address))
                }
                case .DISCONNECT: {
                    log.info("Peer %v disconnected", event.peer.connectID)
                    network.one_and_only_peer = nil
                }
                case .RECEIVE: {
                    defer enet.packet_destroy(event.packet)
                    addr := event.peer.address
                    net_addr := to_net_addr(addr)

                    con_id := event.peer.connectID

                    assert(event.packet.dataLength == size_of(ClientUpdatePacket))
                    cpacket := cast(^ClientUpdatePacket)event.packet.data
                    if int(cpacket.local_player_id) < len(network.remote_players) {
                        local_id := network.remote_players[cpacket.local_player_id]
                        tform, ok := &game_state.transforms[local_id]
                        assert(ok)
                        a, aok := &game_state.skinned_models[local_id]
                        assert(aok)
                        a.anim_idx = cpacket.anim_idx
                        a.anim_t = cpacket.anim_t
                        tform.position = cpacket.position
                        tform.rotation = cpacket.rotation
                    }
                }
            }
        }

        // Send player position
        if network.one_and_only_peer != nil && network.one_and_only_peer.state == .CONNECTED {
            for player_id, idx in game_state.local_players {
                assert(idx < 256)
                tfrom, ok := game_state.transforms[player_id]
                assert(ok)
                a, aok := &game_state.skinned_models[player_id]
                assert(aok)
                packet_data := ClientUpdatePacket {
                    local_player_id = u8(idx),
                    anim_idx = a.anim_idx,
                    anim_t = a.anim_t,
                    position = tfrom.position,
                    rotation = tfrom.rotation,
                }
                packet := enet.packet_create(&packet_data, size_of(ClientUpdatePacket), {})
                @static once := true
                if once {
                    once = false
                    log.infof("ClientUpdatePacket \"over-the-wire\" size is %v bytes", packet.dataLength)
                }
                errcode := enet.peer_send(network.one_and_only_peer, 0, packet)
                assert(errcode == 0)
            }
        }
    }

    return output
}

connect_client_net :: proc(network: ^Network, addr: net.Address) {
    ip4_addr, ok := addr.(net.IP4_Address)
    assert(ok)
    peer_addr := enet.Address {
        host = (cast(^u32)(&ip4_addr[0]))^,
        port = SERVER_PORT,
    }
    connect_client_enet(network, peer_addr)
}

connect_client_enet :: proc(network: ^Network, addr: enet.Address) {
    addr := addr
    network.one_and_only_peer = enet.host_connect(network.host, &addr, 2, 0)
    if network.one_and_only_peer == nil {
        log.errorf("Unable to connect to host.")
    }
}

connect_client :: proc {
    connect_client_enet,
    connect_client_net,
}

network_gui :: proc(network: ^Network, p_open: ^bool, allocator := context.temp_allocator) {
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
    
        imgui.BeginDisabled(network.one_and_only_peer != nil || len(server_ip_string) == 0)
        if imgui.Button("Connect to remote game") {
            remote_addr, ok := net.parse_endpoint(server_ip_string)
            assert(ok)
    
            connect_client(network, remote_addr.address)
        }
        imgui.EndDisabled()
        imgui.BeginDisabled(network.one_and_only_peer == nil)
        if imgui.Button("Disconnect from game") {
            enet.peer_disconnect(network.one_and_only_peer, 0)
        }
        imgui.EndDisabled()
    
        imgui.BeginDisabled(len(name_string) == 0)
        if imgui.Button("Broadcast discovery packet") {
            clear(&network.lan_servers)
            
            addr := enet.Address {
                host = enet.HOST_BROADCAST,
                port = BROADCAST_PORT,
            }
            packet := BroadcastPacket {
                meaning = .ClientQuery,
                client_id = network._unique_id,
                payload = name_string,
            }
            bytes := serialize_broadcast_packet(&packet)
            b := enet.Buffer {
                data = raw_data(bytes),
                dataLength = len(bytes)
            }

            errcode := enet.socket_connect(network.broadcast_sender, &addr)
            assert(errcode == 0)
            bytes_sent := enet.socket_send(network.broadcast_sender, &addr, &b, 1)
            assert(uint(bytes_sent) == b.dataLength)
        }
        imgui.EndDisabled()

        {
            message_str := string(network.recv_message[:])
            cs := strings.unsafe_string_to_cstring(message_str)
            if message_str[0] > 0 {
                imgui.Text("You got a username! It was \"%s\"!", cs)
            }
        }

        if len(network.lan_servers) > 0 {
            if imgui.BeginTable("Server browser", 3) {
                defer imgui.EndTable()
                imgui.TableSetupColumn("IP Address")
                imgui.TableSetupColumn("Username")
                imgui.TableSetupColumn("Level name")
                imgui.TableHeadersRow()

                for &server, i in network.lan_servers {
                    imgui.PushIDInt(i32(i))
                    defer imgui.PopID()
                    imgui.TableNextRow()
                    imgui.TableNextColumn()

                    cs: cstring
                    addr_str := address_string(server.ip_address, allocator)
                    cs = strings.unsafe_string_to_cstring(addr_str)
                    imgui.Text(cs)
                    imgui.SameLine()
                    imgui.BeginDisabled(network.one_and_only_peer != nil)
                    if imgui.Button("Connect") {
                        log.infof("Connecting to %v", addr_str)
                        connect_client(network, server.ip_address)
                    }
                    imgui.EndDisabled()

                    imgui.TableNextColumn()
                    cs = strings.unsafe_string_to_cstring(string(server.username[:]))
                    imgui.Text(cs)

                    imgui.TableNextColumn()
                    cs = strings.unsafe_string_to_cstring(string(server.level_name[:]))
                    imgui.Text(cs)
                }
            }
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

address_string :: proc(addr: enet.Address, allocator := context.temp_allocator) -> string {
    host := addr.host
    sb: strings.Builder
    strings.builder_init(&sb, allocator)
    addr_str := fmt.sbprintf(&sb, "%v.%v.%v.%v", host & 0xFF, host >> 8 & 0xFF, host >> 16 & 0xFF, host >> 24 & 0xFF)
    return addr_str
}