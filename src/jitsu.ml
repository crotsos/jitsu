(*
 * Copyright (c) 2014 Magnus Skjegstad <magnus@skjegstad.com>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Lwt
open Dns
open Libvirt

type vm_stop_mode = VmStopDestroy | VmStopSuspend | VmStopShutdown

type vm_metadata = {
  vm_name : string;             (* Unique name of VM. Matches name in libvirt *)
  vm_uuid : Libvirt.uuid;       (* Libvirt data structure for this VM *)

  mac : Macaddr.t option;       (* MAC addr of this domain, if known. Used for gARP *)
  ip : Ipaddr.V4.t;                (* IP addr of this domain *)

  query_response_delay : float; (* in seconds, delay after startup before
                                   sending query response *)
  vm_ttl : int;                 (* TTL in seconds. VM is stopped [vm_ttl]
                                   seconds after [requested_ts] *)
  how_to_stop : vm_stop_mode;   (* how to stop the VM on timeout *)
  mutable started_ts : int;     (* started timestamp *)
  mutable requested_ts : int;   (* last request timestamp *)
  mutable total_requests : int;
  mutable total_starts : int;
}

type t = {
  db : Loader.db;                         (* DNS database *)
  log : string -> unit;                   (* Log function *) 
  connection : rw Libvirt.Connect.t;      (* connection to libvirt *)
  forward_resolver : Dns_resolver_unix.t option; (* DNS to forward request to if no
                                             local match *)
  synjitsu : Synjitsu.t option;
  domain_table : (Name.domain_name, vm_metadata) Hashtbl.t;
  (* vm hash table indexed by domain *)
  name_table : (string, vm_metadata) Hashtbl.t;
  (* vm hash table indexed by vm name *)
}

let try_libvirt msg f =
  try f () with
  | Libvirt.Virterror e -> raise (Failure (Printf.sprintf "%s: %s" msg (Libvirt.Virterror.to_string e)))

let create log connstr forward_resolver ?vm_count:(vm_count=7) ?use_synjitsu:(use_synjitsu=None) () =
  let connection = try_libvirt "Unable to connect" (fun () -> Libvirt.Connect.connect ~name:connstr ()) in
  let synjitsu = match use_synjitsu with
  | Some domain -> let t = (Synjitsu.create connection log domain "synjitsu") in
            ignore_result (Synjitsu.connect t);  (* connect in background *)
            Some t
  | None -> None
  in
  { db = Loader.new_db ();
    log = log; 
    connection;
    forward_resolver = forward_resolver;
    synjitsu;
    domain_table = Hashtbl.create ~random:true vm_count;
    name_table = Hashtbl.create ~random:true vm_count }

(* fallback to external resolver if local lookup fails *)
let fallback t _class _type _name =
  match t.forward_resolver with
  | Some f -> 
      Dns_resolver_unix.resolve f _class _type _name
      >>= fun result ->
      return (Some (Dns.Query.answer_of_response result))
  | None -> return None

(* convert vm state to string *)
let string_of_vm_state = function
  | Libvirt.Domain.InfoNoState -> "no state"
  | Libvirt.Domain.InfoRunning -> "running"
  | Libvirt.Domain.InfoBlocked -> "blocked"
  | Libvirt.Domain.InfoPaused -> "paused"
  | Libvirt.Domain.InfoShutdown -> "shutdown"
  | Libvirt.Domain.InfoShutoff -> "shutoff"
  | Libvirt.Domain.InfoCrashed -> "crashed"

let lookup_uuid t vm_uuid =
  try_libvirt (Printf.sprintf "Unable to find VM by UUID %s" vm_uuid) (fun () -> Libvirt.Domain.lookup_by_uuid t.connection vm_uuid)

let get_vm_info t vm =
  try_libvirt "Unable to get VM info" (fun () -> Libvirt.Domain.get_info (lookup_uuid t vm.vm_uuid))

let get_vm_state t vm =
  let info = get_vm_info t vm in
  try_libvirt "Unable to get VM state" (fun () -> info.Libvirt.Domain.state)

let destroy_vm t vm =
  try_libvirt "Unable to destroy VM" (fun () -> Libvirt.Domain.destroy (lookup_uuid t vm.vm_uuid))

let shutdown_vm t vm =
  try_libvirt "Unable to shutdown VM" (fun () -> Libvirt.Domain.shutdown (lookup_uuid t vm.vm_uuid))

let suspend_vm t vm =
  try_libvirt "Unable to suspend VM" (fun () -> Libvirt.Domain.suspend (lookup_uuid t vm.vm_uuid))

let resume_vm t vm =
  try_libvirt "Unable to resume VM" (fun () -> Libvirt.Domain.resume (lookup_uuid t vm.vm_uuid))

let create_vm t vm =
  try_libvirt "Unable to create VM" (fun () -> Libvirt.Domain.create (lookup_uuid t vm.vm_uuid))

let stop_vm t vm =
  match get_vm_state t vm with
  | Libvirt.Domain.InfoRunning ->
    begin match vm.how_to_stop with
      | VmStopShutdown -> t.log (Printf.sprintf "VM shutdown: %s\n" vm.vm_name); shutdown_vm t vm
      | VmStopSuspend  -> t.log (Printf.sprintf "VM suspend: %s\n" vm.vm_name) ; suspend_vm t vm
      | VmStopDestroy  -> t.log (Printf.sprintf "VM destroy: %s\n" vm.vm_name) ; destroy_vm t vm
    end
  | _ -> ()

let start_vm t vm =
  let state = get_vm_state t vm in
  t.log (Printf.sprintf "Starting %s (%s)" vm.vm_name (string_of_vm_state state));
  match state with
  | Libvirt.Domain.InfoPaused | Libvirt.Domain.InfoShutdown
  | Libvirt.Domain.InfoShutoff ->
    let () = match state with
      | Libvirt.Domain.InfoPaused ->
        t.log " --> resuming vm...\n";
        resume_vm t vm
      | _ ->
        t.log " --> creating vm...\n";
        create_vm t vm
    in
    (* Notify Synjitsu *)
    (match vm.mac with
      | Some m -> 
              (match t.synjitsu with
              | Some s -> (
                  t.log (Printf.sprintf "Notifying Synjitsu of MAC %s\n" (Macaddr.to_string m));
                  (try_lwt 
                    Synjitsu.send_garp s m vm.ip
                  with 
                    e -> t.log (Printf.sprintf "Got exception %s\n" (Printexc.to_string e)); 
                         Lwt.return_unit))
              | None -> Lwt.return_unit)
      | None -> Lwt.return_unit)
    >>= fun _ ->
    (* update stats *)
    vm.started_ts <- truncate (Unix.time());
    vm.total_starts <- vm.total_starts + 1;
    (* sleeping a bit *)
    Lwt_unix.sleep vm.query_response_delay
  | Libvirt.Domain.InfoRunning ->
    t.log " --! VM is already running\n";
    Lwt.return_unit
  | Libvirt.Domain.InfoBlocked | Libvirt.Domain.InfoCrashed
  | Libvirt.Domain.InfoNoState ->
    t.log " --! VM cannot be started from this state.\n";
    Lwt.return_unit

let get_vm_metadata_by_domain t domain =
  try Some (Hashtbl.find t.domain_table domain)
  with Not_found -> None

let get_vm_metadata_by_name t name =
  try Some (Hashtbl.find t.name_table name)
  with Not_found -> None

let get_stats vm =
  Printf.sprintf "VM: %s\n\
                 \ total requests: %d\n\
                 \ total starts: %d\n\
                 \ last start: %d\n\
                 \ last request: %d (%d seconds since started)\n\
                 \ vm ttl: %d\n"
    vm.vm_name vm.total_requests vm.total_starts vm.started_ts vm.requested_ts
    (vm.requested_ts - vm.started_ts) vm.vm_ttl

(* Process function for ocaml-dns. Starts new VMs from DNS queries or
   forwards request to a fallback resolver *)
let process t ~src:_ ~dst:_ packet =
  let open Packet in
  match packet.questions with
  | [] -> return_none;
  | [q] -> begin
      let answer = Query.(answer q.q_name q.q_type t.db.Loader.trie) in
      match answer.Query.rcode with
      | Packet.NoError ->
        t.log (Printf.sprintf "Local match for domain %s\n"
                 (Name.domain_name_to_string q.q_name));
        (* look for vm in hash table *)
        let vm = get_vm_metadata_by_domain t q.q_name in
        begin match vm with
          | Some vm -> begin (* there is a match *)
              t.log (Printf.sprintf "Matching VM is %s\n" vm.vm_name);
              (* update stats *)
              vm.total_requests <- vm.total_requests + 1;
              vm.requested_ts <- int_of_float (Unix.time());
              start_vm t vm >>= fun () ->
              (* print stats *)
              t.log (get_stats vm);
              return (Some answer);
            end;
          | None -> (* no match, fall back to resolver *)
            t.log "No known VM. Forwarding to next resolver...\n";
            fallback t q.q_class q.q_type q.q_name
        end
      | _ ->
        t.log (Printf.sprintf "No local match for %s, forwarding...\n"
                 (Name.domain_name_to_string q.q_name));
        fallback t q.q_class q.q_type q.q_name
    end
  | _ -> return_none

(* Add domain SOA record. Called automatically from add_vm if domain
   is not registered in local DB as a SOA record *)
let add_soa t soa_domain ttl =
  Loader.add_soa_rr [] []
    (Int32.of_int (int_of_float (Unix.time())))
    (Int32.of_int ttl)
    (Int32.of_int 3)
    (Int32.of_int (ttl*2))
    (Int32.of_int (ttl*2))
    (Int32.of_int ttl)
    soa_domain
    t.db

(* true if a dns record exists locally for [domain] of [_type] *)
let has_local_domain t domain _type =
  let answer = Query.(answer domain _type t.db.Loader.trie) in
  match answer.Query.rcode with
  | Packet.NoError -> true
  | _ -> false

(* return base of domain. E.g. www.example.org = example.org, a.b.c.d = c.d *)
let get_base_domain domain =
  (*match domain with
  | _::domain::[tld] | domain::[tld] -> ([domain ; tld] :> Name.domain_name)
  | _ -> raise (Failure "Invalid domain name")*)
  List.tl domain
  

(* get mac address for domain - TODO only supports one interface *)
let get_mac domain =
  let dom_xml_s = try_libvirt "Unable to retrieve XML description of domain" (fun () -> Libvirt.Domain.get_xml_desc domain) in
  (*Printf.printf "xml is %s" dom_xml_s;*)
  try
      let (_, dom_xml) = Ezxmlm.from_string dom_xml_s in
      let (mac_attr, _) = Ezxmlm.member "domain" dom_xml |> Ezxmlm.member "devices" |> Ezxmlm.member "interface" |> Ezxmlm.member_with_attr "mac" in
      let mac_s = Ezxmlm.get_attr "address" mac_attr in
      Macaddr.of_string mac_s
  with
  | Not_found -> None
  | Ezxmlm.Tag_not_found _ -> None

(* add vm to be monitored by jitsu *)
let add_vm t ~domain:domain_as_string ~name:vm_name vm_ip stop_mode
    ~delay:response_delay ~ttl =
  (* check if vm_name exists and set up VM record *)
  let vm_dom = try_libvirt "Unable to lookup VM by name" (fun () -> Libvirt.Domain.lookup_by_name t.connection vm_name) in
  let vm_uuid = try_libvirt (Printf.sprintf "Unable to get uuid for %s" vm_name) (fun () -> Libvirt.Domain.get_uuid vm_dom) in
  let mac = get_mac vm_dom in
  (match mac with
  | Some m -> t.log (Printf.sprintf "Domain registered with MAC %s\n" (Macaddr.to_string m))
  | None -> t.log (Printf.sprintf "Warning: MAC not found for domain. Synjitsu will not be notified..\n"));
  (* check if SOA is registered and domain is ok *)
  let domain_as_list = Name.string_to_domain_name domain_as_string in
  let base_domain = get_base_domain domain_as_list in
  let answer = has_local_domain t base_domain Packet.Q_SOA in
  if not answer then (
    t.log (Printf.sprintf "Adding SOA '%s' with ttl=%d\n"
             (Name.domain_name_to_string base_domain) ttl);
    (* add soa if not registered before *) (* TODO use same ttl? *)
    add_soa t base_domain ttl;
  );
  (* add dns record *)
  t.log (Printf.sprintf "Adding A PTR for '%s' with ttl=%d and ip=%s\n"
           (Name.domain_name_to_string domain_as_list) ttl (Ipaddr.V4.to_string vm_ip));
  Loader.add_a_rr vm_ip (Int32.of_int ttl) domain_as_list t.db;
  let existing_record = (get_vm_metadata_by_name t vm_name) in
  (* reuse existing record if possible *)
  let record = match existing_record with
    | None -> { vm_name;
                vm_uuid;
                mac;
                ip=vm_ip;
                how_to_stop = stop_mode;
                vm_ttl = ttl * 2; (* note *2 here *)
                query_response_delay = response_delay;
                started_ts = 0;
                requested_ts = 0;
                total_requests = 0;
                total_starts = 0 }
    | Some existing_record -> existing_record
  in
  (* add/replace in both hash tables *)
  Hashtbl.replace t.domain_table domain_as_list record;
  Hashtbl.replace t.name_table vm_name record;
  return_unit

(* iterate through t.name_table and stop VMs that haven't received
   requests for more than ttl*2 seconds *)
let stop_expired_vms t =
  let expired_vms = Array.make (Hashtbl.length t.name_table) None in
  (* TODO this should be run in lwt, but hopefully it is reasonably fast this way. *)
  let current_time = int_of_float (Unix.time ()) in
  let is_expired vm_meta =
    current_time - vm_meta.requested_ts > vm_meta.vm_ttl
  in
  let pos = ref (-1) in
  let put_in_array _ vm_meta =
    incr pos;
    match is_expired vm_meta with
    | true  -> expired_vms.(!pos) <- Some vm_meta
    | false -> expired_vms.(!pos) <- None
  in
  Hashtbl.iter put_in_array t.name_table;
  let stop_vm = function
    | None    -> ()
    | Some vm -> stop_vm t vm
  in
  Array.iter stop_vm expired_vms 
