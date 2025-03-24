module Process = Abb_process.Make (Abb)

type to_yaml_string_err = Abb_process.check_output_err [@@deriving show]

type of_yaml_string_err =
  [ `Json_decode_err of string
  | `Unexpected_err
  | `Yaml_decode_err of string
  ]
[@@deriving show]

type merge_err = [ `Type_mismatch_err of string option * Yojson.Safe.t * Yojson.Safe.t ]
[@@deriving show]

let to_yaml_string json =
  let open Abb.Future.Infix_monad in
  Process.check_output
    ~input:(Yojson.Safe.to_string json)
    Abb_intf.Process.{ exec_name = "yj"; args = [ "yj"; "-jy" ]; env = None }
  >>= function
  | Ok (stdout, _) -> Abb.Future.return (Ok stdout)
  | Error (#Abb_process.check_output_err as err) -> Abb.Future.return (Error err)

let of_yaml_string yaml_str =
  let open Abb.Future.Infix_monad in
  Process.check_output
    ~input:yaml_str
    Abb_intf.Process.{ exec_name = "yj"; args = [ "yj" ]; env = None }
  >>= function
  | Ok (stdout, _) -> (
      try Abb.Future.return (Ok (Yojson.Safe.from_string stdout))
      with Yojson.Json_error err -> Abb.Future.return (Error (`Json_decode_err err)))
  | Error `E_no_space
  | Error `E_permission
  | Error (`Unexpected _)
  | Error `E_bad_file
  | Error `E_pipe
  | Error `E_again
  | Error `E_invalid
  | Error `E_io
  | Error `E_no_memory
  | Error `E_is_dir -> Abb.Future.return (Error `Unexpected_err)
  | Error (`Run_error (_, _, stderr, _)) ->
      Abb.Future.return (Error (`Yaml_decode_err (CCString.trim stderr)))

let rec merge' ~base override =
  match (base, override) with
  | `Bool _, (`Bool _ as v)
  | `Intlit _, (`Intlit _ as v)
  | `Int _, (`Int _ as v)
  | `Intlit _, (`Int _ as v)
  | `Int _, (`Intlit _ as v)
  | `Float _, (`Float _ as v)
  | `String _, (`String _ as v) -> Ok v
  | `List b, `List o -> Ok (`List (CCList.append o b))
  | (`Assoc b as base), `Assoc o ->
      let open CCResult.Infix in
      CCResult.fold_l
        (fun acc (k, v) ->
          match Yojson.Safe.Util.member k base with
          | `Null -> Ok ((k, v) :: acc)
          | v' -> (
              match merge' ~base:v' v with
              | Ok v -> Ok ((k, v) :: acc)
              | Error (`Type_mismatch_err (None, b, o)) -> Error (`Type_mismatch_err (Some k, b, o))
              | Error (`Type_mismatch_err (Some p, b, o)) ->
                  Error (`Type_mismatch_err (Some (k ^ "." ^ p), b, o))))
        []
        o
      >>= fun override ->
      (* Add back any keys in base not in override *)
      let override =
        CCList.fold_left
          (fun acc (k, v) ->
            if not (CCList.Assoc.mem ~eq:CCString.equal k override) then (k, v) :: acc else acc)
          override
          b
      in
      Ok (`Assoc override)
  | _, `Null -> Ok `Null
  | `Null, v -> Ok v
  | `Tuple _, _ | _, `Tuple _ -> assert false
  | `Variant _, _ | _, `Variant _ -> assert false
  | b, o -> Error (`Type_mismatch_err (None, b, o))

let merge ~base override =
  (merge' ~base override
    : (Yojson.Safe.t, merge_err) result
    :> (Yojson.Safe.t, [> merge_err ]) result)
