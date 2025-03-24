let trigger_words = [ "terrateam"; "terraform"; "tofu" ]

type t =
  | Plan of { tag_query : Terrat_tag_query.t }
  | Apply of { tag_query : Terrat_tag_query.t }
  | Apply_autoapprove of { tag_query : Terrat_tag_query.t }
  | Apply_force of { tag_query : Terrat_tag_query.t }
  | Unlock of string list
  | Help
  | Feedback of string
  | Repo_config
  | Index

type err =
  [ `Not_terrateam
  | `Unknown_action of string
  | Terrat_tag_query_ast.err
  ]
[@@deriving show]

let parse s =
  let split_s =
    match CCString.Split.left ~by:" " (CCString.trim s) with
    | Some (trigger_word, action_rest)
      when CCList.mem ~eq:CCString.equal (CCString.lowercase_ascii trigger_word) trigger_words -> (
        match CCString.Split.left ~by:" " (CCString.trim action_rest) with
        | Some (action, rest) -> Some (action, rest)
        | None -> Some (action_rest, ""))
    | _ -> None
  in
  let open CCResult.Infix in
  match split_s with
  | Some ("unlock", rest) ->
      Ok
        (Unlock
           (rest
           |> CCString.split_on_char ' '
           |> CCList.map CCString.trim
           |> CCList.filter CCFun.(CCString.is_empty %> not)))
  | Some ("plan", rest) ->
      Terrat_tag_query.of_string rest >>= fun tag_query -> Ok (Plan { tag_query })
  | Some ("apply", rest) ->
      Terrat_tag_query.of_string rest >>= fun tag_query -> Ok (Apply { tag_query })
  | Some ("apply-autoapprove", rest) ->
      Terrat_tag_query.of_string rest >>= fun tag_query -> Ok (Apply_autoapprove { tag_query })
  | Some ("apply-force", rest) ->
      Terrat_tag_query.of_string rest >>= fun tag_query -> Ok (Apply_force { tag_query })
  | Some ("help", _) -> Ok Help
  | Some ("feedback", rest) -> Ok (Feedback rest)
  | Some ("repo-config", _) -> Ok Repo_config
  | Some ("index", _) -> Ok Index
  | Some (action, rest) -> Error (`Unknown_action action)
  | None -> Error `Not_terrateam

let to_string = function
  | Plan { tag_query } -> "terrateam plan " ^ Terrat_tag_query.to_string tag_query
  | Apply { tag_query } -> "terrateam apply " ^ Terrat_tag_query.to_string tag_query
  | Apply_autoapprove { tag_query } ->
      "terrateam apply-autoapprove " ^ Terrat_tag_query.to_string tag_query
  | Apply_force { tag_query } -> "terrateam apply-force " ^ Terrat_tag_query.to_string tag_query
  | Unlock ids -> "terrateam unlock " ^ CCString.concat " " ids
  | Help -> "terrateam help"
  | Feedback feedback -> "terrateam feedback " ^ feedback
  | Repo_config -> "terrateam repo-config"
  | Index -> "terrateam index"
