(* The dependency graph of the loaded libraries, in the depgraph format
   (../../FORMAT.md): what each constant, inductive type and constructor uses,
   read from the kernel terms (types and bodies, opaque proofs included). *)

open Names
open Declarations

let json_string s =
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '"';
  String.iter (fun c -> match c with
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | '\n' -> Buffer.add_string b "\\n"
      | c when Char.code c < 0x20 -> Buffer.add_string b (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char b c) s;
  Buffer.add_char b '"';
  Buffer.contents b

let name_of gr =
  try Libnames.string_of_path (Nametab.path_of_global gr)
  with Not_found -> match gr with
    | GlobRef.ConstRef c -> Constant.to_string c
    | GlobRef.IndRef (m, _) -> MutInd.to_string m
    | GlobRef.ConstructRef ((m, _), j) -> MutInd.to_string m ^ "#" ^ string_of_int j
    | GlobRef.VarRef id -> Id.to_string id

(* the constant of a primitive projection, or else its record type *)
let projection env p =
  let (mind, i) = Projection.inductive p in
  let fallback = GlobRef.IndRef (mind, i) in
  match (Environ.lookup_mind mind env).mind_packets.(i).mind_record with
  | PrimRecord { projections; _ } ->
    let c = Constant.make2 (MutInd.modpath mind) (Label.of_id projections.(Projection.arg p)) in
    if Environ.mem_constant c env then GlobRef.ConstRef c else fallback
  | _ -> fallback
  | exception Not_found -> fallback

let rec uses env acc t =
  let open Constr in
  match kind t with
  | Const (c, _) -> GlobRef.Set.add (GlobRef.ConstRef c) acc
  | Ind (i, _) -> GlobRef.Set.add (GlobRef.IndRef i) acc
  | Construct (c, _) -> GlobRef.Set.add (GlobRef.ConstructRef c) acc
  | Proj (p, _, c) -> uses env (GlobRef.Set.add (projection env p) acc) c
  | _ -> Constr.fold (uses env) acc t

let rel_context_uses env acc ctx =
  List.fold_left (fun acc d -> Context.Rel.Declaration.fold_constr (fun t a -> uses env a t) d acc) acc ctx

(* the library (compiled file) a declaration is in *)
let library_of_modpath mp = ModPath.dp mp

type decl = { gr : GlobRef.t; kind : string; deps : GlobRef.Set.t }

let source_file vo =
  let v = Filename.remove_extension vo ^ ".v" in
  (* dune builds in _build/default/: show the original file *)
  let marker = "/_build/default/" in
  let v = match Str.search_forward (Str.regexp_string marker) v 0 with
    | i -> String.sub v 0 i ^ "/" ^ String.sub v (i + String.length marker)
             (String.length v - i - String.length marker)
    | exception Not_found -> v in
  v

let write ~opaque_access file prefixes =
  let env = Global.env () in
  let prefixes = List.map (fun p -> Libnames.dirpath_of_string p) prefixes in
  let libs = List.filter (fun dp -> List.exists (fun p -> Libnames.is_dirpath_prefix_of p dp) prefixes)
      (Library.loaded_libraries ()) in
  let shown = Hashtbl.create 64 in
  List.iter (fun dp -> Hashtbl.replace shown dp ()) libs;
  let decls = Hashtbl.create 64 in
  let add mp d = let dp = library_of_modpath mp in
    if Hashtbl.mem shown dp then Hashtbl.add decls dp d in
  Environ.fold_constants (fun c cb () ->
      let deps = uses env GlobRef.Set.empty cb.const_type in
      let deps = match Global.body_of_constant_body opaque_access cb with
        | Some (b, _, _) -> uses env deps b
        | None -> deps in
      let kind = match cb.const_body with
        | Undef _ -> "axiom" | Def _ -> "definition" | OpaqueDef _ -> "theorem"
        | Primitive _ -> "primitive" | Symbol _ -> "symbol" in
      add (Constant.modpath c) { gr = GlobRef.ConstRef c; kind; deps }) env ();
  Environ.fold_inductives (fun m mib () ->
      let params = rel_context_uses env GlobRef.Set.empty mib.mind_params_ctxt in
      Array.iteri (fun i oib ->
          let lc = Array.map (uses env GlobRef.Set.empty) oib.mind_user_lc in
          let deps = Array.fold_left GlobRef.Set.union (uses env params oib.mind_user_arity) lc in
          let kind = if oib.mind_record = NotRecord then "inductive" else "record" in
          add (MutInd.modpath m) { gr = GlobRef.IndRef (m, i); kind; deps };
          Array.iteri (fun j d ->
              add (MutInd.modpath m) { gr = GlobRef.ConstructRef ((m, i), j + 1); kind = "constructor";
                                       deps = GlobRef.Set.add (GlobRef.IndRef (m, i)) d }) lc)
        mib.mind_packets) env ();
  let oc = open_out_bin file in
  Printf.fprintf oc "{\"depgraph\":1,\"library\":%s}\n" (json_string (List.hd (List.map DirPath.to_string prefixes)));
  List.iter (fun dp ->
      let modname = DirPath.to_string dp in
      let vo = match Loadpath.locate_qualified_library (Libnames.qualid_of_dirpath dp) with
        | Ok (_, f) -> Some f | Error _ -> None in
      let src = Option.bind vo (fun f -> Ranges.read_file (source_file f)) in
      let globs = match vo with
        | Some f -> Ranges.glob_defs modname (Filename.remove_extension f ^ ".glob")
        | None -> Hashtbl.create 1 in
      let line_of = Option.map Ranges.line_index src in
      Printf.fprintf oc "{\"module\":%s%s}\n" (json_string modname)
        (match vo with Some f -> ",\"file\":" ^ json_string (source_file f) | None -> "");
      let lines = List.map (fun d ->
          let name = name_of d.gr in
          let range = match Hashtbl.find_opt globs name, src, line_of with
            | Some (gkind, off), Some src, Some line_of ->
              let last = match d.gr with
                | GlobRef.ConstRef _ when gkind = "proj" -> Ranges.item_end src off ';'
                | GlobRef.ConstRef _ ->
                  Ranges.decl_end src off (d.kind = "theorem" || d.kind = "definition")
                | GlobRef.ConstructRef _ -> Ranges.item_end src off '|'
                | _ -> fst (Ranges.sentence_end src off) in
              (off, Printf.sprintf ",\"line\":%d,\"end\":%d" (line_of off) (line_of last))
            | _ -> (max_int, "") in
          let kind = match Hashtbl.find_opt globs name with
            | Some ("inst", _) -> "instance" | Some ("proj", _) -> "projection"
            | Some ("class", _) -> "class" | Some ("scheme", _) -> "scheme"
            | _ -> d.kind in
          let deps = GlobRef.Set.elements (GlobRef.Set.remove d.gr d.deps) in
          ((fst range, kind = "scheme"), Printf.sprintf "{\"decl\":%s,\"module\":%s,\"kind\":%s%s,\"uses\":[%s]}\n"
             (json_string name) (json_string modname) (json_string kind) (snd range)
             (String.concat "," (List.map (fun g -> json_string (name_of g)) deps))))
          (List.rev (Hashtbl.find_all decls dp)) in
      (* in the order of the source; schemes after their inductive type *)
      List.iter (fun (_, l) -> output_string oc l) (List.stable_sort (fun a b -> compare (fst a) (fst b)) lines))
    libs;
  close_out oc;
  Feedback.msg_info Pp.(str "depgraph: " ++ int (List.length libs) ++ str " modules, "
                        ++ int (Hashtbl.length decls) ++ str " declarations in " ++ str file)
