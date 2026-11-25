(* Where declarations are in the source: their first line from the .glob file,
   their last line by reading the sentences of the .v file. *)

let read_file f =
  try
    let ic = open_in_bin f in
    let s = really_input_string ic (in_channel_length ic) in
    close_in ic; Some s
  with Sys_error _ -> None

(* entries of a .glob file that are not kernel declarations, but may have their names *)
let not_decls = ["sec"; "mod"; "modtype"; "var"; "binder"; "not"; "lib"; "syndef"; "abbrev"]

(* The definitions of a .glob file: lines "<kind> <start>:<end> <secpath> <name>",
   as full name -> (kind, byte offset). The first one of a name wins. *)
let glob_defs lib glob =
  let tbl = Hashtbl.create 1024 in
  (match read_file glob with
   | None -> ()
   | Some s ->
     List.iter (fun l ->
         match String.split_on_char ' ' l with
         | [kind; pos; sec; name] when kind <> "" && kind.[0] <> 'R' && not (List.mem kind not_decls) ->
           (match String.index_opt pos ':' with
            | Some i ->
              (match int_of_string_opt (String.sub pos 0 i) with
               | Some off ->
                 let full = String.concat "." (lib :: (if sec = "<>" then [] else [sec]) @ [name]) in
                 if not (Hashtbl.mem tbl full) then Hashtbl.add tbl full (kind, off)
               | None -> ())
            | None -> ())
         | _ -> ())
       (String.split_on_char '\n' s));
  tbl

(* line number (from 1) of each byte offset *)
let line_index src =
  let starts = ref [0] in
  String.iteri (fun i c -> if c = '\n' then starts := (i + 1) :: !starts) src;
  let a = Array.of_list (List.rev !starts) in
  fun off ->
    let lo = ref 0 and hi = ref (Array.length a - 1) in
    while !lo < !hi do
      let m = (!lo + !hi + 1) / 2 in
      if a.(m) <= off then lo := m else hi := m - 1
    done;
    !lo + 1

let is_space c = c = ' ' || c = '\n' || c = '\t' || c = '\r'

(* The end (offset of the final '.') of the sentence containing offset [i],
   skipping comments and strings; also its text has ":=" or not. *)
let sentence_end src i =
  let n = String.length src in
  let rec go i depth instr assign =
    if i >= n then (n - 1, assign)
    else
      let c = src.[i] in
      let next = if i + 1 < n then src.[i + 1] else ' ' in
      if instr then
        (if c = '"' && next = '"' then go (i + 2) 0 true assign   (* "" inside a string *)
         else go (i + 1) 0 (c <> '"') assign)
      else if c = '(' && next = '*' then go (i + 2) (depth + 1) false assign
      else if depth > 0 && c = '*' && next = ')' then go (i + 2) (depth - 1) false assign
      else if depth > 0 then go (i + 1) depth false assign
      else if c = '"' then go (i + 1) 0 true assign
      else if c = ':' && next = '=' then go (i + 2) 0 false true
      else if c = '.' && is_space next && (i = 0 || src.[i - 1] <> '.') then (i, assign)
      else go (i + 1) 0 false assign
  in
  go i 0 false false

(* the first word of the sentence after offset [i] (skipping blanks and comments) *)
let rec next_word src i =
  let n = String.length src in
  let i = ref (i + 1) in
  while !i < n && is_space src.[!i] do incr i done;
  if !i + 1 < n && src.[!i] = '(' && src.[!i + 1] = '*' then
    (* skip the comment, then look again *)
    let rec skip j d =
      if j + 1 >= n then n
      else if src.[j] = '(' && src.[j + 1] = '*' then skip (j + 2) (d + 1)
      else if src.[j] = '*' && src.[j + 1] = ')' then (if d = 1 then j + 1 else skip (j + 2) (d - 1))
      else skip (j + 1) d
    in
    next_word src (skip !i 0)
  else begin
    let j = ref !i in
    while !j < n && (match src.[!j] with 'A'..'Z' | 'a'..'z' | '_' -> true | _ -> false) do incr j done;
    (String.sub src !i (!j - !i), !i)
  end

(* The end of the constructor ([sep] = '|') or record field ([sep] = ';') whose name
   is at [off]: before the next [sep] or closing bracket outside brackets, or the end
   of the sentence. *)
let item_end src off sep =
  let e = fst (sentence_end src off) in
  let before i =
    let j = ref (i - 1) in
    while !j > off && is_space src.[!j] do decr j done;
    !j in
  let rec go i depth =
    if i >= e then e
    else match src.[i] with
      | '(' when i + 1 < e && src.[i + 1] = '*' ->
        go (skip_comment (i + 2) 1) depth
      | '(' | '[' | '{' -> go (i + 1) (depth + 1)
      | ')' | ']' | '}' when depth = 0 -> before i
      | ')' | ']' | '}' -> go (i + 1) (depth - 1)
      | c when c = sep && depth = 0 && (i + 1 >= e || src.[i + 1] <> sep) && src.[i - 1] <> sep ->
        if sep = ';' then i else before i
      | _ -> go (i + 1) depth
  and skip_comment i d =
    if i + 1 >= e then e
    else if src.[i] = '(' && src.[i + 1] = '*' then skip_comment (i + 2) (d + 1)
    else if src.[i] = '*' && src.[i + 1] = ')' then (if d = 1 then i + 2 else skip_comment (i + 2) (d - 1))
    else skip_comment (i + 1) d
  in
  go off 0

let terminators = ["Qed"; "Defined"; "Admitted"; "Save"; "Abort"]

(* The offset where the declaration whose name is at [off] ends: its sentence,
   and the proof after it, when there is one. [proof_mode] says whether the
   declaration can be stated without ":=" and proved by tactics. *)
let decl_end src off proof_mode =
  let e, assign = sentence_end src off in
  let w, _ = next_word src e in
  if w = "Proof" || proof_mode && not assign then
    let rec find e =
      if e >= String.length src - 1 then None
      else
        let w, j = next_word src e in
        let e' = fst (sentence_end src j) in
        if List.mem w terminators then Some e' else if e' <= e then None else find e'
    in
    (match find e with Some e' -> e' | None -> e)
  else e
