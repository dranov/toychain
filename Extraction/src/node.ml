open Forests
open Protocol
open Util

module Addr = Address.Addr
module Types = TypesImpl.TypesImpl
module Consensus = Impl.ProofOfWork
module ForestImpl = Forests (Types) (Consensus)
module Pr = Protocol (Types) (Consensus) (ForestImpl) (Addr)
open ForestImpl
open Pr
open Net

(** STATE **)
let _ = Random.self_init ()
let cluster = ref []
let nodes = ref []
let _empty_addr = (((0, 0), (0, 0)), (0, 0))
let node_id = ref (-1)
let node_addr = ref (_empty_addr)
let st = ref (coq_Init  _empty_addr)

let blocks = ref 1
let hashes = ref 0
let last_measurement = ref 0
let last_time = ref (Unix.gettimeofday ())

(* Command line arguments *)
let usage msg =
  print_endline msg;
  Printf.printf "%s usage:\n" Sys.argv.(0);
  Printf.printf "    %s -me IP_ADDR PORT -cluster <CLUSTER>\n" (Array.get Sys.argv 0);
  print_endline "where:";
  print_endline "    CLUSTER   is a list of tuples of IP_ADDR PORT,";
  print_endline "              giving OTHER known nodes in the system";
  exit 1

let rec parse_args = function
  | [] -> ()
  | "-me" :: ip :: port :: args ->
    begin
      node_id := int_of_ip_port ip (int_of_string port);
      node_addr := addr_of_int !node_id;
      parse_args args
    end
  | "-cluster" :: args -> parse_args args
  | ip :: port :: args ->
    begin
      cluster := (ip, int_of_string port) :: !cluster;
      parse_args args
    end
  | arg :: args -> usage ("Unknown argument " ^ arg)


(* MESSAGE and TRANSITION LOGIC *)
let rec get_pkt = function
  | [] -> None
  | fd :: fds ->
      try
        Some (recv_pkt fd)
      with e ->
      begin
        get_pkt fds
      end

let send_all (pkts : coq_Packet list) =
  List.iter (fun pkt -> send_pkt (int_of_addr pkt.dst) pkt) pkts

let add_peer_if_new p_addr =
  let cfg = get_cfg "new peer" () in
  let peer = (int_of_addr p_addr, ip_port_of_addr p_addr) in
  if not (List.mem peer cfg.nodes) then
  begin
    let (ip, port) = snd peer in
      Printf.printf "New peer %s:%d connected to us!" ip port ;
      print_newline ();
      the_cfg := Some {cfg with nodes = (peer :: cfg.nodes)} ;
  end

let procMsg_wrapper () =
  let () = check_for_new_connections () in
  let fds = get_all_read_fds () in
  let (ready_fds, _, _) = retry_until_no_eintr (fun () -> Unix.select fds [] [] 0.0) in
  begin
    match get_pkt ready_fds with
    | None -> (* nothing available *) None
    | Some pkt ->
        begin
          Printf.printf "Received packet %s" (string_of_packet pkt);
          print_newline ();
          if pkt.dst <> !node_addr then
          begin
            Printf.printf " - packet sent in error? (we're not the destination!)";
            print_newline ();
            None
          end
          else
          begin
            (* For ConnectMsg and AddrMsg, update peer table in Net.the_cfg
                before actually processing the message. This ensures the
                appropriate sockets can be created when send_all is called
                later.
             *)
            ( match pkt.msg with
              | ConnectMsg -> ignore (add_peer_if_new pkt.src);
              | AddrMsg peers -> ignore (List.map (fun pr -> add_peer_if_new pr) peers);
              | _ -> ();
            );
            let (st', pkts) = Pr.procMsg !st pkt.src pkt.msg 0 in
            st := st';
            send_all pkts;
            Some (st, pkts)
          end
        end
  end

let procInt_wrapper () =
  (* Randomly decide what to do *)
  let shouldIssueTx = false in
  match shouldIssueTx with
  | true ->
      let tx = clist_of_string ("TX " ^ (string_of_int (Random.int 65536))) in
      let (st', pkts) = Pr.procInt !st (TxT tx) 0 in
      Printf.printf "Created %s" (string_of_clist tx);
      print_newline ();
      st := st';
      send_all pkts;
      Some (st, pkts)
  | false ->
      let (st', pkts) = Pr.procInt !st (MintT) 0 in
      hashes := !hashes + 1;
      (* Bit of a hack to figure out whether a block was mined *)
      if List.length pkts > 0 then
        begin
            blocks := !blocks + 1;
            st := st';
            send_all pkts;
            Some (st, pkts)
        end
      else None


(* NODE LOGIC *)
let main () = 
  (* XXX: our hack of packing IPv4:port into ints only works on 64 bit;
            see Net.ml `int_of_ip_port` and `ip_port_of_int`
  *)
  assert (Sys.word_size >= 64);

  let args = (List.tl (Array.to_list Sys.argv)) in
  if List.length args = 0 then usage "" else
  begin
    parse_args args ;

    (* Setup networking *)
    let _cluster = (List.map (fun (ip, port) -> int_of_ip_port ip port) !cluster) in
    let peer_ids = if not (List.mem !node_id _cluster) then !node_id :: _cluster else _cluster in
    let peer_addrs = List.map addr_of_int peer_ids in
    nodes := List.map (fun nid -> (nid, ip_port_of_int nid)) peer_ids ;
    setup { nodes = !nodes; me = !node_id };
    (* Printf.printf "%s" (str_cfg ()); *)
    (* print_newline (); *)

    (* Wait so other nodes in the cluster have time to start listening *)
    (* Unix.sleep 1; *)

    begin
      st := {(coq_Init (addr_of_int !node_id)) with peers = peer_addrs} ;
      (* Printf.printf "You are node %d (%s)" (int_of_addr !st.id) (string_of_address !st.id);
      print_newline (); *)
      (* Send a ConnectMsg to all peers *)
      (* let connects = List.map (fun pr -> {src = !node_addr; dst = pr; msg = ConnectMsg }) peer_addrs in
      send_all connects ;


      Printf.printf "\n---------\nChain\n%s\n---------\n" (string_of_blockchain (btChain !st.blockTree)); *)

      last_measurement := !hashes;
      last_time := Unix.gettimeofday ();
      while true do
        ignore (procInt_wrapper ());

        if (Unix.gettimeofday () -. !last_time >= 5.0) then
        begin
          Printf.printf "%d %0.2f"
          !blocks
          ((float_of_int (!hashes - !last_measurement)) /. (Unix.gettimeofday () -. !last_time));
          print_newline ();
          last_time := Unix.gettimeofday ();
          last_measurement := !hashes;
        end;


        (* ignore (procMsg_wrapper ());  *)
        (* Every 10 seconds, print your chain. *)
        (* let ts = (int_of_float (Unix.time ())) in
        if ts mod 10 = 0 then
          begin
            Printf.printf "\n---------\nChain\n%s\n---------\n" (string_of_blockchain (btChain !st.blockTree));
            Printf.printf "%0.2f hashes per second\n"
              ((float_of_int (!hashes - !last_measurement)) /. (Unix.time () -. !last_time));
            print_newline ();
            last_measurement := !hashes;
            last_time := Unix.time ();
            Unix.sleep 1 ;
            ()
          end
        else () *)
      done;
    end
  end

let () = main ()