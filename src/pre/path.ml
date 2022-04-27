open Lang
open MakeCfg

type t = fkey * Node.t list
and path = t

let dummy_path = (("","",[]), []) 

let get_fkey : path -> fkey
= fun (k,_) -> k

let get_bp : path -> Node.t list
= fun (_,bp) -> bp

let to_string : path -> string
= fun (k,bp) ->
  to_string_fkey k ^ " : " ^ to_string_path bp

(* if len(lst) = 2, returns empty list *)
let get_mid : 'a list -> 'a list
= fun lst ->
  match lst with
  | [] -> []
  | hd::tl -> BatList.remove_at (List.length tl - 1) tl

module Path2 = struct
  type t = Node.t option * path
  and path2 = t

  let get_ctx (nop,p) = nop

  let get_fkey (nop,p) = get_fkey p
  let get_bp (nop,p) = get_bp p

  let to_string (nop,p) =
    match nop with
    | None -> to_string p
    | Some n -> "(" ^ Node.to_string n ^ ", " ^ to_string p ^ ")"
end

module PathSet2 = BatSet.Make (struct type t = Path2.t let compare = Stdlib.compare end)

(***************************)
(***************************)
(** Basic Path Generation **)
(***************************)
(***************************)

(* returns (processed path set, processing path set, visited root nodes) *)
(* 'root node' here means cutpoint. *)
let gen_onestep_bp_path : string list -> FuncMap.t -> cfg -> node list -> node BatSet.t ->
                          (node list BatSet.t * node list BatSet.t * node BatSet.t)
= fun cnames fmap g path visited_roots ->
  let last = BatList.last path in
  let nexts = succ last g in
  List.fold_left (fun (processed, processing, acc_visited_roots) next ->
    if is_loophead next g || is_exit next then
      let processed' = BatSet.add (path@[next]) processed in
      let processing' = if BatSet.mem next visited_roots then processing else BatSet.add [next] processing in
      let acc_visited_roots' = BatSet.add next visited_roots in
      (processed', processing', acc_visited_roots')

    else if is_internal_call_node fmap cnames next g then
      let processed' = BatSet.add (path@[next]) processed in
      let processing' = BatSet.add (path@[next]) processing in
      (processed', processing', acc_visited_roots)

    else if is_external_call_node next g then
      let processed' = BatSet.add (path@[next]) processed in
      let processing' = BatSet.add (path@[next]) processing in
      (processed', processing', acc_visited_roots)

    else if is_exception_node next g && !Options.mode = "exploit" && !Options.check_re then
      (processed, processing, acc_visited_roots)

    else
      (processed, BatSet.add (path@[next]) processing, acc_visited_roots)
  ) (BatSet.empty, BatSet.empty, visited_roots) nexts

let gen_onestep_bp : string list -> FuncMap.t -> cfg ->
                     (node list BatSet.t * node list BatSet.t * node BatSet.t) -> 
                     (node list BatSet.t * node list BatSet.t * node BatSet.t)
= fun cnames fmap g (processed, processing, visited_roots) ->
  (* whenever this function is called,
     "processed" and "visited_roots" are accumulated, while processing is reinitialized *)
  BatSet.fold (fun path (acc1, acc2, acc3) ->
    let (new_processed, new_processing, new_visited_roots) = gen_onestep_bp_path cnames fmap g path acc3 in
    (BatSet.union new_processed acc1, BatSet.union new_processing acc2, BatSet.union new_visited_roots acc3)
  ) processing (processed, BatSet.empty, visited_roots)

let is_re_query_node : node -> cfg -> bool
= fun n g ->
  match find_stmt n g with
  | Call (lvop, Lv (MemberAccess (e,"call",_,_)), args, Some eth, gasop, loc, id)
    when BatSet.mem n g.extern_set -> true
  | _ -> false

let all_re_query_in_collected_path : cfg -> node list BatSet.t -> bool
= fun g paths ->
  let nodes = nodes_of g in
  let qnodes = List.filter (fun n -> is_re_query_node n g) nodes in
  List.for_all (fun n -> BatSet.exists (fun path -> List.mem n path) paths) qnodes

let rec fix f cnames fmap g (processed,processing,visited_roots) =
  let (processed',processing',visited_roots') = f cnames fmap g (processed,processing,visited_roots) in
    if BatSet.is_empty processing'
       || (!Options.mode = "exploit" && not !Options.check_re && BatSet.cardinal processed' >= 50) (* to prevent out-of-memory *)
       || (!Options.mode = "exploit" && !Options.check_re && BatSet.cardinal processed' >= 80 && all_re_query_in_collected_path g processed')
      then (processed',processing',visited_roots')
    else fix f cnames fmap g (processed',processing',visited_roots')

let gen_basic_paths_cfg : string list -> FuncMap.t -> cfg -> node list BatSet.t
= fun cnames fmap g ->
  let (basic_paths,_,_) = 
    fix gen_onestep_bp cnames fmap g (BatSet.empty, BatSet.singleton [Node.entry], BatSet.singleton Node.entry) in
  basic_paths

let rec bfs : cfg -> node BatSet.t -> (node * node list) BatSet.t -> node list BatSet.t -> node list BatSet.t
= fun g seeds works bps -> (* works: pending paths *)
  if BatSet.is_empty works (* || (!Options.exploit && BatSet.cardinal bps >= 50) *) then bps
  else
    let ((n,path), works) = BatSet.pop_min works in
    if is_exit n then
      bfs g seeds works (BatSet.add path bps)
    else if is_loophead n g then
      let nexts = succ n g in
      let works = if BatSet.mem n seeds then works else List.fold_left (fun acc n' -> BatSet.add (n', [n;n']) acc) works nexts in
      let seeds = BatSet.add n seeds in
      bfs g seeds works (BatSet.add path bps)
    else
      let nexts = succ n g in
      let works = List.fold_left (fun acc n' -> BatSet.add (n',path@[n']) acc) works nexts in
      bfs g seeds works bps

let rec bfs2 : cfg -> node -> node list -> node list BatSet.t
= fun g n path ->
  if is_exit n then BatSet.singleton path
  else
    let nexts = succ n g in
    List.fold_left (fun acc n' ->
      BatSet.union (bfs2 g n' (path@[n'])) acc
    ) BatSet.empty nexts

let generate_basic_paths : string list -> FuncMap.t -> pgm -> pgm
= fun cnames fmap pgm ->
  List.map (fun c ->
    let funcs = get_funcs c in
    let funcs' =
      List.map (fun f ->
        let g = get_cfg f in
        let bps =
          if !Options.path = 1 then gen_basic_paths_cfg cnames fmap g
          else if !Options.path = 2 then bfs g (BatSet.singleton Node.entry) (BatSet.singleton (Node.entry, [Node.entry])) BatSet.empty
          else if !Options.path = 3 then bfs2 g Node.entry [Node.entry]
          else failwith "improper path options" in
        (* let _ = print_endline "" in
        let _ = print_endline (Vocab.string_of_set ~sep:"\n" Lang.to_string_path bps) in *)
        let g' = {g with basic_paths = bps} in
        update_cfg f g'
      ) funcs in
    update_funcs funcs' c
  ) pgm

(****************************)
(****************************)
(** Collecting Basic Paths **)
(****************************)
(****************************)

module PathSet = BatSet.Make (struct type t = path let compare = Stdlib.compare end)

let collect_bps_f : func -> PathSet.t
= fun f ->
  let fk = Lang.get_fkey f in
  let bps = (Lang.get_cfg f).basic_paths in
  BatSet.fold (fun bp acc ->
    PathSet.add (fk,bp) acc
  ) bps PathSet.empty
    
let collect_bps_c : contract -> PathSet.t
= fun c ->
  (* modifier themselves are not executable paths *)
  let funcs = List.filter (fun f -> not (is_modifier f)) (get_funcs c) in
  List.fold_left (fun acc f ->
    PathSet.union (collect_bps_f f) acc
  ) PathSet.empty funcs 

let collect_bps : pgm -> PathSet.t 
= fun p ->
  List.fold_left (fun acc c ->
    match !Options.mode with
    | "exploit" ->
      if BatString.equal !Options.main_contract (get_cname c) then
        PathSet.union (collect_bps_c c) acc
      else acc
    | _ -> PathSet.union (collect_bps_c c) acc
  ) PathSet.empty p

let generate ?(silent=false) : pgm -> PathSet.t
= fun pgm ->
  if not silent then Profiler.start "[STEP] Generating Paths ... ";
  let cnames = get_cnames pgm in
  let fmap = FuncMap.mk_fmap pgm in
  let pgm = generate_basic_paths cnames fmap pgm in
  let paths = collect_bps pgm in
  if not silent then Profiler.finish "[STEP] Generating Paths ... ";
  if not silent then Profiler.print_log ("- #paths : " ^ string_of_int (PathSet.cardinal paths));
  if not silent then prerr_endline "";
  paths
