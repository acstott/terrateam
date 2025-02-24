module List = ListLabels
module Sys_stdlib = Sys
module Unix = UnixLabels

module Native = struct
  type t = Unix.file_descr
end

module Fd_map = CCMap.Make (struct
  type t = Unix.file_descr

  let compare = compare
end)

module Timers = struct
  module Timer_map = Map.Make (struct
    type t = (Mtime.span[@compare Mtime.Span.compare]) * int [@@deriving ord]
  end)

  type 'a t = 'a Timer_map.t

  let empty = Timer_map.empty
  let add id timestamp f t = Timer_map.add (timestamp, id) f t
  let remove id timestamp t = Timer_map.remove (timestamp, id) t
  let next t = Timer_map.min_binding t
end

let sec_ns = Mtime.Span.(to_float_ns s)

(* El is short for Event Loop *)
module El = struct
  type t = {
    reads : (t Abb_fut.State.t -> t Abb_fut.State.t) Fd_map.t;
    writes : (t Abb_fut.State.t -> t Abb_fut.State.t) Fd_map.t;
    timers : (t Abb_fut.State.t -> t Abb_fut.State.t) Timers.t;
    next_timer_id : int;
    curr_time : float;
    mono_time : Mtime.span;
    exec_duration : float -> unit;
    thread_pool : (Unix.file_descr * Unix.file_descr) Abb_thread_pool.t;
    ignore_reads : Unix.file_descr list;
    ignore_writes : Unix.file_descr list;
  }

  type t_ = t

  module Future = Abb_fut.Make (struct
    type t = t_
  end)

  let create ?(exec_duration = fun _ -> ()) () =
    let t =
      {
        reads = Fd_map.empty;
        writes = Fd_map.empty;
        timers = Timers.empty;
        next_timer_id = 0;
        curr_time = Unix.gettimeofday ();
        mono_time = Mtime_clock.elapsed ();
        exec_duration;
        thread_pool = Abb_thread_pool.create ~capacity:100 ~wait:Unix.pipe;
        ignore_reads = [];
        ignore_writes = [];
      }
    in
    t

  let destroy t = Abb_thread_pool.destroy t.thread_pool
  let read_fds t = Iter.to_list (Fd_map.keys t.reads)
  let write_fds t = Iter.to_list (Fd_map.keys t.writes)

  let dispatch fds get set ignores s =
    ListLabels.fold_left
      ~init:s
      ~f:(fun s fd ->
        let ignore_list = ignores s in
        if not (CCList.mem ~eq:( = ) fd ignore_list) then
          let m = get s in
          let f = Fd_map.find fd m in
          let s = set (Fd_map.remove fd m) s in
          f s
        else s)
      fds

  let dispatch_reads reads s =
    dispatch
      reads
      (fun s -> (Abb_fut.State.state s).reads)
      (fun reads s ->
        let t = Abb_fut.State.state s in
        Abb_fut.State.set_state { t with reads } s)
      (fun s -> (Abb_fut.State.state s).ignore_reads)
      s

  let dispatch_writes writes s =
    dispatch
      writes
      (fun s -> (Abb_fut.State.state s).writes)
      (fun writes s ->
        let t = Abb_fut.State.state s in
        Abb_fut.State.set_state { t with writes } s)
      (fun s -> (Abb_fut.State.state s).ignore_writes)
      s

  let rec dispatch_timers s =
    let t = Abb_fut.State.state s in
    try
      match Timers.next t.timers with
      | (ts, id), f when Mtime.Span.compare ts t.mono_time <= 0 ->
          let t = { t with timers = Timers.remove id ts t.timers } in
          let s = Abb_fut.State.set_state t s in
          dispatch_timers (f s)
      | _ -> s
    with Not_found -> s

  let wait_on_event s =
    let t = Abb_fut.State.state s in

    let timeout =
      try
        match Timers.next t.timers with
        | (ts, _), _ when Mtime.Span.compare ts t.mono_time > 0 ->
            Mtime.Span.(to_float_ns (abs_diff ts t.mono_time) /. sec_ns)
        | _ -> 0.0
      with Not_found -> -1.0
    in
    assert (timeout >= -1.0);
    let read = read_fds t in
    let write = write_fds t in
    assert ((not (CCList.is_empty read && CCList.is_empty write)) || timeout >= 0.0);
    let reads, writes, _ =
      try Unix.select ~read ~write ~except:[] ~timeout
      with Unix.Unix_error (Unix.EINTR, _, _) -> ([], [], [])
    in
    let t =
      {
        t with
        curr_time = Unix.gettimeofday ();
        mono_time = Mtime_clock.elapsed ();
        ignore_reads = [];
        ignore_writes = [];
      }
    in
    let s = Abb_fut.State.set_state t s in
    let s = s |> dispatch_reads reads |> dispatch_writes writes |> dispatch_timers in
    let end_time = Mtime_clock.elapsed () in
    let duration = Mtime.Span.(to_float_ns (abs_diff end_time t.mono_time) /. sec_ns) in
    (Abb_fut.State.state s).exec_duration duration;
    s

  let rec loop s done_fut =
    match Future.state done_fut with
    | `Det _ | `Aborted | `Exn _ -> s
    | `Undet ->
        let s = wait_on_event s in
        loop s done_fut
end

module Future = El.Future

module Scheduler = struct
  type t = El.t Abb_fut.State.t

  let create ?exec_duration () = Abb_fut.State.create (El.create ?exec_duration ())
  let destroy t = El.destroy (Abb_fut.State.state t)

  let run t f =
    ignore Sys.(signal sigpipe Signal_ignore);
    let ret = f () in
    let t = Future.run_with_state ret t in
    let t = El.loop t ret in
    match Future.state ret with
    | (`Det _ | `Aborted | `Exn _) as r -> (t, r)
    | `Undet -> assert false

  let run_with_state ?exec_duration f =
    let t = create ?exec_duration () in
    let t, r = run t f in
    destroy t;
    r
end

module Sys = struct
  let sleep duration =
    Future.with_state (fun s ->
        let t = Abb_fut.State.state s in
        let timer_id = t.El.next_timer_id in
        (* Add one [ns] to the duration just to ensure we do not get caught in a
           tight loop by sleeping 0 seconds. *)
        let duration_span =
          CCOption.get_exn_or
            "negative sleep duration"
            (Mtime.Span.of_float_ns (duration *. sec_ns))
        in
        let ts = Mtime.Span.(add t.El.mono_time (add duration_span ns)) in
        let p =
          Future.Promise.create
            ~abort:(fun () ->
              Future.with_state (fun s ->
                  let t = Abb_fut.State.state s in
                  let t = { t with El.timers = Timers.remove timer_id ts t.El.timers } in
                  let s = Abb_fut.State.set_state t s in
                  (s, Future.return ())))
            ()
        in
        let f s = Future.run_with_state (Future.Promise.set p ()) s in
        let t =
          {
            t with
            El.next_timer_id = t.El.next_timer_id + 1;
            timers = Timers.add timer_id ts f t.El.timers;
          }
        in

        let s = Abb_fut.State.set_state t s in
        (s, Future.Promise.future p))

  let time () =
    Future.with_state (fun s ->
        let t = Abb_fut.State.state s in
        (s, Future.return t.El.curr_time))

  let monotonic () =
    Future.with_state (fun s ->
        let t = Abb_fut.State.state s in
        (s, Future.return Mtime.Span.(to_float_ns t.El.mono_time /. sec_ns)))
end

module Thread = struct
  let run f =
    Future.with_state (fun s ->
        let t = Abb_fut.State.state s in
        let ret = ref None in
        let trigger (_, trigger) res =
          ret := Some res;
          (* Send something on the pipe to trigger the read side *)
          (try ignore (Unix.write trigger ~buf:(Bytes.of_string "0") ~pos:0 ~len:1)
           with Unix.Unix_error _ ->
             (* If the other side has closed the trigger, this write will fail,
                so ignore any write error. *)
             ());
          Unix.close trigger
        in
        let wait, _ = Abb_thread_pool.enqueue t.El.thread_pool ~f ~trigger in
        let abort () =
          (* It would be nice to kill the thread here but several issues arise,
             including: the thread may have allocated resources it needs to clean
             up, and Thread.kill is not actually implemented. *)
          Future.with_state (fun s ->
              let t = Abb_fut.State.state s in
              let t =
                {
                  t with
                  El.reads = Fd_map.remove wait t.El.reads;
                  ignore_reads = wait :: t.El.ignore_reads;
                  ignore_writes = wait :: t.El.ignore_writes;
                }
              in
              Unix.close wait;
              let s = Abb_fut.State.set_state t s in
              (s, Future.return ()))
        in
        let p = Future.Promise.create ~abort () in
        let handler s =
          let open Future.Infix_monad in
          let fut =
            match !ret with
            | Some (Ok v) -> Future.Promise.set p v >>| fun () -> Unix.close wait
            | Some (Error exn) -> Future.Promise.set_exn p exn >>| fun () -> Unix.close wait
            | None -> assert false
          in
          Future.run_with_state fut s
        in
        let t = { t with El.reads = Fd_map.add wait handler t.El.reads } in
        let s = Abb_fut.State.set_state t s in
        (s, Future.Promise.future p))
end

let safe_call f = try Ok (f ()) with e -> Error (`Unexpected e)

(** The filesystem calls are implemented through a thread call because there is no guarantee that
    they will not block, for example on an NFS system. *)
module File = struct
  type t = Unix.file_descr

  let to_native t = t
  let of_native t = t
  let stdin = Unix.stdin
  let stdout = Unix.stdout
  let stderr = Unix.stderr

  let mode_of_flags flags =
    List.map
      ~f:
        Abb_intf.File.Flag.(
          function
          | Read_only -> Unix.O_RDONLY
          | Write_only -> Unix.O_WRONLY
          | Create _ -> Unix.O_CREAT
          | Read_write -> Unix.O_RDWR
          | Append -> Unix.O_APPEND
          | Truncate -> Unix.O_TRUNC
          | Exclusive -> Unix.O_EXCL)
      flags

  let perm_of_flags flags =
    let creates =
      List.filter
        ~f:
          Abb_intf.File.Flag.(
            function
            | Create _ -> true
            | _ -> false)
        flags
    in
    match creates with
    | [ Abb_intf.File.Flag.Create perm ] -> perm
    | _ -> 0

  let open_file ~flags path =
    Thread.run (fun () ->
        try
          let t = Unix.openfile path ~mode:(mode_of_flags flags) ~perm:(perm_of_flags flags) in
          (* FIXME Possible descriptor leak here? *)
          Unix.set_close_on_exec t;
          Ok t
        with
        | Unix.Unix_error (err, _, _) as exn ->
            let open Unix in
            Error
              (match err with
              | ENOTDIR -> `E_not_dir
              | ENAMETOOLONG -> `E_name_too_long
              | ENOENT -> `E_no_entity
              | EACCES -> `E_access
              | EROFS | EPERM -> `E_permission
              | ELOOP -> `E_loop
              | ENFILE | EMFILE -> `E_file_table_full
              | ENOSPC -> `E_no_space
              | EIO -> `E_io
              | EEXIST -> `E_exists
              | EINVAL -> `E_invalid
              | _ -> `Unexpected exn)
        | exn -> Error (`Unexpected exn))

  let safe_read t ~buf ~pos ~len =
    try Ok (Unix.read t ~buf ~pos ~len) with
    | Unix.Unix_error (err, _, _) as exn ->
        let open Unix in
        Error
          (match err with
          | EBADF -> `E_bad_file
          | EIO -> `E_io
          | EINVAL -> `E_invalid
          | EISDIR -> `E_is_dir
          | _ -> `Unexpected exn)
    | exn -> Error (`Unexpected exn)

  let read t ~buf ~pos ~len = Thread.run (fun () -> safe_read t ~buf ~pos ~len)

  let pread t ~offset ~buf ~pos ~len =
    Thread.run (fun () ->
        try
          let n = Unix.lseek t offset ~mode:Unix.SEEK_SET in
          assert (n = offset);
          safe_read t ~buf ~pos ~len
        with
        | Unix.Unix_error (Unix.ENXIO, _, _) -> Error `E_nxio
        | exn -> Error (`Unexpected exn))

  let rec write_buf t buf =
    let n =
      Unix.write
        t
        ~buf:buf.Abb_intf.Write_buf.buf
        ~pos:buf.Abb_intf.Write_buf.pos
        ~len:buf.Abb_intf.Write_buf.len
    in
    match n with
    | n when n < buf.Abb_intf.Write_buf.len ->
        let buf = Abb_intf.Write_buf.{ buf with pos = buf.pos + n; len = buf.len - n } in
        n + write_buf t buf
    | n -> n

  let write_bufs t bufs =
    let rec write_bufs' t = function
      | [] -> 0
      | b :: bs ->
          let n = write_buf t b in
          n + write_bufs' t bs
    in
    try Ok (write_bufs' t bufs) with
    | Unix.Unix_error (err, _, _) as exn ->
        let open Unix in
        Error
          (match err with
          | EBADF -> `E_bad_file
          | EPIPE -> `E_pipe
          | EINVAL -> `E_invalid
          | ENOSPC -> `E_no_space
          | EIO -> `E_io
          | EROFS -> `E_permission
          | _ -> `Unexpected exn)
    | exn -> Error (`Unexpected exn)

  let write t bufs = Thread.run (fun () -> write_bufs t bufs)

  let pwrite t ~offset bufs =
    Thread.run (fun () ->
        try
          let n = Unix.lseek t offset ~mode:Unix.SEEK_SET in
          assert (n = offset);
          write_bufs t bufs
        with
        | Unix.Unix_error (Unix.ENXIO, _, _) -> Error `E_nxio
        | exn -> Error (`Unexpected exn))

  let lseek' t ~offset = function
    | Abb_intf.File.Seek.Cur ->
        ignore (Unix.lseek t offset ~mode:Unix.SEEK_CUR);
        Ok ()
    | Abb_intf.File.Seek.Set ->
        ignore (Unix.lseek t offset ~mode:Unix.SEEK_SET);
        Ok ()
    | Abb_intf.File.Seek.End ->
        ignore (Unix.lseek t offset ~mode:Unix.SEEK_END);
        Ok ()

  let lseek t ~offset seek =
    try lseek' t ~offset seek with
    | Unix.Unix_error (err, _, _) as exn ->
        let open Unix in
        Error
          (match err with
          | EBADF -> `E_bad_file
          | ENXIO -> `E_nxio
          | EINVAL -> `E_invalid
          | _ -> `Unexpected exn)
    | exn -> Error (`Unexpected exn)

  let close t =
    Thread.run (fun () ->
        try Ok (Unix.close t) with
        | Unix.Unix_error (err, _, _) as exn ->
            let open Unix in
            Error
              (match err with
              | EBADF -> `E_bad_file
              | ENOSPC -> `E_no_space
              | _ -> `Unexpected exn)
        | exn -> Error (`Unexpected exn))

  let unlink path =
    Thread.run (fun () ->
        try Ok (Unix.unlink path) with
        | Unix.Unix_error (err, _, _) as exn ->
            let open Unix in
            Error
              (match err with
              | ENOTDIR -> `E_not_dir
              | EISDIR -> `E_is_dir
              | ENAMETOOLONG -> `E_name_too_long
              | ENOENT -> `E_no_entity
              | EACCES -> `E_access
              | ELOOP -> `E_loop
              | EPERM -> `E_permission
              | EIO -> `E_io
              | ENOSPC -> `E_no_space
              | _ -> `Unexpected exn)
        | exn -> Error (`Unexpected exn))

  let mkdir path perm =
    Thread.run (fun () ->
        try Ok (Unix.mkdir ~perm path) with
        | Unix.Unix_error (err, _, _) as exn ->
            let open Unix in
            Error
              (match err with
              | ENOTDIR -> `E_not_dir
              | EISDIR -> `E_is_dir
              | ENAMETOOLONG -> `E_name_too_long
              | ENOENT -> `E_no_entity
              | EACCES -> `E_access
              | ELOOP -> `E_loop
              | EPERM -> `E_permission
              | EIO -> `E_io
              | ENOSPC -> `E_no_space
              | EEXIST -> `E_exists
              | _ -> `Unexpected exn)
        | exn -> Error (`Unexpected exn))

  let rmdir path =
    Thread.run (fun () ->
        try Ok (Unix.rmdir path) with
        | Unix.Unix_error (err, _, _) as exn ->
            let open Unix in
            Error
              (match err with
              | ENOTDIR -> `E_not_dir
              | ENAMETOOLONG -> `E_name_too_long
              | ENOENT -> `E_no_entity
              | ENOTEMPTY -> `E_not_empty
              | EACCES -> `E_access
              | ELOOP -> `E_loop
              | EPERM -> `E_permission
              | EINVAL -> `E_invalid
              | EBUSY -> `E_busy
              | EIO -> `E_io
              | EEXIST -> `E_exists
              | _ -> `Unexpected exn)
        | exn -> Error (`Unexpected exn))

  let readdir path =
    Thread.run (fun () -> safe_call (fun () -> Array.to_list (Sys_stdlib.readdir path)))

  let of_unix_stat stat =
    let of_file_kind = function
      | Unix.S_REG -> Abb_intf.File.File_kind.Regular
      | Unix.S_DIR -> Abb_intf.File.File_kind.Directory
      | Unix.S_CHR -> Abb_intf.File.File_kind.Char
      | Unix.S_BLK -> Abb_intf.File.File_kind.Block
      | Unix.S_LNK -> Abb_intf.File.File_kind.Symlink
      | Unix.S_FIFO -> Abb_intf.File.File_kind.Fifo
      | Unix.S_SOCK -> Abb_intf.File.File_kind.Socket
    in
    Abb_intf.File.Stat.
      {
        dev = stat.Unix.st_dev;
        inode = stat.Unix.st_ino;
        kind = of_file_kind stat.Unix.st_kind;
        perm = stat.Unix.st_perm;
        num_links = stat.Unix.st_nlink;
        uid = stat.Unix.st_uid;
        gid = stat.Unix.st_gid;
        rdev = stat.Unix.st_rdev;
        size = stat.Unix.st_size;
        atime = stat.Unix.st_atime;
        mtime = stat.Unix.st_mtime;
        ctime = stat.Unix.st_ctime;
      }

  let stat path =
    Thread.run (fun () ->
        try Ok (of_unix_stat (Unix.stat path)) with
        | Unix.Unix_error (err, _, _) as exn ->
            let open Unix in
            Error
              (match err with
              | EACCES -> `E_access
              | EIO -> `E_io
              | ELOOP -> `E_loop
              | ENAMETOOLONG -> `E_name_too_long
              | ENOENT -> `E_no_entity
              | ENOTDIR -> `E_not_dir
              | _ -> `Unexpected exn)
        | exn -> Error (`Unexpected exn))

  let fstat t =
    Thread.run (fun () ->
        try Ok (of_unix_stat (Unix.fstat t)) with
        | Unix.Unix_error (err, _, _) as exn ->
            let open Unix in
            Error
              (match err with
              | EBADF -> `E_bad_file
              | EINVAL -> `E_invalid
              | EACCES -> `E_access
              | EIO -> `E_io
              | ELOOP -> `E_loop
              | ENAMETOOLONG -> `E_name_too_long
              | ENOENT -> `E_no_entity
              | ENOTDIR -> `E_not_dir
              | _ -> `Unexpected exn)
        | exn -> Error (`Unexpected exn))

  let lstat path =
    Thread.run (fun () ->
        try Ok (of_unix_stat (Unix.lstat path)) with
        | Unix.Unix_error (err, _, _) as exn ->
            let open Unix in
            Error
              (match err with
              | EACCES -> `E_access
              | EIO -> `E_io
              | ELOOP -> `E_loop
              | ENAMETOOLONG -> `E_name_too_long
              | ENOENT -> `E_no_entity
              | ENOTDIR -> `E_not_dir
              | _ -> `Unexpected exn)
        | exn -> Error (`Unexpected exn))

  let rename ~src ~dst =
    Thread.run (fun () ->
        try Ok (Unix.rename ~src ~dst) with
        | Unix.Unix_error (err, _, _) as exn ->
            let open Unix in
            Error
              (match err with
              | ENAMETOOLONG -> `E_name_too_long
              | ENOENT -> `E_no_entity
              | EACCES -> `E_access
              | EPERM | EROFS -> `E_permission
              | ELOOP -> `E_loop
              | ENOTDIR -> `E_not_dir
              | EISDIR -> `E_is_dir
              | ENOSPC -> `E_no_space
              | EIO -> `E_io
              | EINVAL -> `E_invalid
              | ENOTEMPTY -> `E_not_empty
              | _ -> `Unexpected exn)
        | exn -> Error (`Unexpected exn))

  let truncate path len =
    Thread.run (fun () ->
        try Ok (Unix.truncate path ~len:(Int64.to_int len)) with
        | Unix.Unix_error (err, _, _) as exn ->
            let open Unix in
            Error
              (match err with
              | ENOTDIR -> `E_not_dir
              | ENAMETOOLONG -> `E_name_too_long
              | ENOENT -> `E_no_entity
              | EACCES -> `E_access
              | ELOOP -> `E_loop
              | EROFS | EPERM -> `E_permission
              | EISDIR -> `E_is_dir
              | EINVAL -> `E_invalid
              | EIO -> `E_io
              | _ -> `Unexpected exn)
        | exn -> Error (`Unexpected exn))

  let ftruncate t len =
    Thread.run (fun () ->
        try Ok (Unix.ftruncate t ~len:(Int64.to_int len)) with
        | Unix.Unix_error (err, _, _) as exn ->
            let open Unix in
            Error
              (match err with
              | EBADF -> `E_bad_file
              | ENOTDIR -> `E_not_dir
              | ENAMETOOLONG -> `E_name_too_long
              | ENOENT -> `E_no_entity
              | EACCES -> `E_access
              | ELOOP -> `E_loop
              | EROFS | EPERM -> `E_permission
              | EISDIR -> `E_is_dir
              | EINVAL -> `E_invalid
              | EIO -> `E_io
              | _ -> `Unexpected exn)
        | exn -> Error (`Unexpected exn))

  let chmod path mode =
    Thread.run (fun () ->
        try Ok (Unix.chmod path ~perm:mode) with
        | Unix.Unix_error (err, _, _) as exn ->
            let open Unix in
            Error
              (match err with
              | ENOTDIR -> `E_not_dir
              | ENAMETOOLONG -> `E_name_too_long
              | ENOENT -> `E_no_entity
              | EACCES -> `E_access
              | ELOOP -> `E_loop
              | EROFS | EPERM -> `E_permission
              | EIO -> `E_io
              | _ -> `Unexpected exn)
        | exn -> Error (`Unexpected exn))

  let fchmod t mode =
    Thread.run (fun () ->
        try Ok (Unix.fchmod t ~perm:mode) with
        | Unix.Unix_error (err, _, _) as exn ->
            let open Unix in
            Error
              (match err with
              | EBADF -> `E_bad_file
              | EINVAL -> `E_invalid
              | ENOTDIR -> `E_not_dir
              | ENAMETOOLONG -> `E_name_too_long
              | ENOENT -> `E_no_entity
              | EACCES -> `E_access
              | ELOOP -> `E_loop
              | EROFS | EPERM -> `E_permission
              | EIO -> `E_io
              | _ -> `Unexpected exn)
        | exn -> Error (`Unexpected exn))

  let symlink ~src ~dst =
    Thread.run (fun () ->
        try Ok (Unix.symlink ~to_dir:false ~src ~dst) with
        | Unix.Unix_error (err, _, _) as exn ->
            let open Unix in
            Error
              (match err with
              | ENOTDIR -> `E_not_dir
              | ENAMETOOLONG -> `E_name_too_long
              | ENOENT -> `E_no_entity
              | EACCES -> `E_access
              | ELOOP -> `E_loop
              | EEXIST -> `E_exists
              | EROFS | EPERM -> `E_permission
              | EIO -> `E_io
              | ENOSPC -> `E_no_space
              | _ -> `Unexpected exn)
        | exn -> Error (`Unexpected exn))

  let link ~src ~dst =
    Thread.run (fun () ->
        try Ok (Unix.link ~follow:true ~src ~dst) with
        | Unix.Unix_error (err, _, _) as exn ->
            let open Unix in
            Error
              (match err with
              | ENOTDIR -> `E_not_dir
              | ENAMETOOLONG -> `E_name_too_long
              | ENOENT -> `E_no_entity
              | EOPNOTSUPP -> `E_op_not_supported
              | EACCES -> `E_access
              | ELOOP -> `E_loop
              | EEXIST -> `E_exists
              | EROFS | EPERM -> `E_permission
              | EIO -> `E_io
              | ENOSPC -> `E_no_space
              | _ -> `Unexpected exn)
        | exn -> Error (`Unexpected exn))

  let chown path ~uid ~gid =
    Thread.run (fun () ->
        try Ok (Unix.chown path ~uid ~gid) with
        | Unix.Unix_error (err, _, _) as exn ->
            let open Unix in
            Error
              (match err with
              | ENOTDIR -> `E_not_dir
              | ENAMETOOLONG -> `E_name_too_long
              | ENOENT -> `E_no_entity
              | EACCES -> `E_access
              | ELOOP -> `E_loop
              | EROFS | EPERM -> `E_permission
              | EIO -> `E_io
              | _ -> `Unexpected exn)
        | exn -> Error (`Unexpected exn))

  let fchown t ~uid ~gid =
    Thread.run (fun () ->
        try Ok (Unix.fchown t ~uid ~gid) with
        | Unix.Unix_error (err, _, _) as exn ->
            let open Unix in
            Error
              (match err with
              | EBADF -> `E_bad_file
              | ENOTDIR -> `E_not_dir
              | ENAMETOOLONG -> `E_name_too_long
              | ENOENT -> `E_no_entity
              | EACCES -> `E_access
              | ELOOP -> `E_loop
              | EROFS | EPERM -> `E_permission
              | EIO -> `E_io
              | _ -> `Unexpected exn)
        | exn -> Error (`Unexpected exn))
end

module Socket = struct
  type tcp
  type udp
  type _ t = Unix.file_descr

  let unix_of_domain = function
    | Abb_intf.Socket.Domain.Unix -> Unix.PF_UNIX
    | Abb_intf.Socket.Domain.Inet4 -> Unix.PF_INET
    | Abb_intf.Socket.Domain.Inet6 -> Unix.PF_INET6

  let domain_of_unix = function
    | Unix.PF_UNIX -> Abb_intf.Socket.Domain.Unix
    | Unix.PF_INET -> Abb_intf.Socket.Domain.Inet4
    | Unix.PF_INET6 -> Abb_intf.Socket.Domain.Inet6

  let socket_type_of_unix = function
    | Unix.SOCK_STREAM -> Abb_intf.Socket.Socket_type.Stream
    | Unix.SOCK_DGRAM -> Abb_intf.Socket.Socket_type.Dgram
    | Unix.SOCK_RAW -> Abb_intf.Socket.Socket_type.Raw
    | Unix.SOCK_SEQPACKET -> Abb_intf.Socket.Socket_type.Seqpacket

  let unix_of_socket_type = function
    | Abb_intf.Socket.Socket_type.Stream -> Unix.SOCK_STREAM
    | Abb_intf.Socket.Socket_type.Dgram -> Unix.SOCK_DGRAM
    | Abb_intf.Socket.Socket_type.Raw -> Unix.SOCK_RAW
    | Abb_intf.Socket.Socket_type.Seqpacket -> Unix.SOCK_SEQPACKET

  let addrinfo_of_unix_addrinfo ai =
    let family = domain_of_unix ai.Unix.ai_family in
    let sock_type = socket_type_of_unix ai.Unix.ai_socktype in
    let addr =
      match ai.Unix.ai_addr with
      | Unix.ADDR_UNIX s -> Abb_intf.Socket.Sockaddr.Unix s
      | Unix.ADDR_INET (a, p) -> Abb_intf.Socket.Sockaddr.(Inet { addr = a; port = p })
    in
    Abb_intf.Socket.Addrinfo.
      { family; sock_type; protocol = ai.Unix.ai_protocol; addr; canon_name = ai.Unix.ai_canonname }

  let unix_sockaddr_of_sockaddr = function
    | Abb_intf.Socket.Sockaddr.Unix s -> Unix.ADDR_UNIX s
    | Abb_intf.Socket.Sockaddr.Inet inet ->
        Abb_intf.Socket.Sockaddr.(Unix.ADDR_INET (inet.addr, inet.port))

  let sockaddr_of_unix_sockaddr = function
    | Unix.ADDR_UNIX s -> Abb_intf.Socket.Sockaddr.Unix s
    | Unix.ADDR_INET (addr, port) -> Abb_intf.Socket.Sockaddr.(Inet { addr; port })

  let getaddrinfo_options_of_hints hints =
    List.map
      ~f:
        Abb_intf.Socket.Addrinfo_hints.(
          function
          | Family domain -> Unix.AI_FAMILY (unix_of_domain domain)
          | Socket_type socktype -> Unix.AI_SOCKTYPE (unix_of_socket_type socktype)
          | Protocol p -> Unix.AI_PROTOCOL p
          | Numeric_host -> Unix.AI_NUMERICHOST
          | Canon_name -> Unix.AI_CANONNAME
          | Passive -> Unix.AI_PASSIVE)
      hints

  let getaddrinfo ?hints query =
    Thread.run (fun () ->
        safe_call (fun () ->
            let hints =
              match hints with
              | Some h -> h
              | None -> []
            in
            let ai =
              match query with
              | Abb_intf.Socket.Addrinfo_query.Host h ->
                  Unix.getaddrinfo h "" (getaddrinfo_options_of_hints hints)
              | Abb_intf.Socket.Addrinfo_query.Service s ->
                  Unix.getaddrinfo "" s (getaddrinfo_options_of_hints hints)
              | Abb_intf.Socket.Addrinfo_query.Host_service (h, s) ->
                  Unix.getaddrinfo h s (getaddrinfo_options_of_hints hints)
            in
            List.map ~f:addrinfo_of_unix_addrinfo ai))

  let getsockname t =
    match Unix.getsockname t with
    | Unix.ADDR_UNIX str -> Abb_intf.Socket.Sockaddr.Unix str
    | Unix.ADDR_INET (addr, port) -> Abb_intf.Socket.Sockaddr.(Inet { addr; port })

  let getpeername t =
    match Unix.getpeername t with
    | Unix.ADDR_UNIX str -> Abb_intf.Socket.Sockaddr.Unix str
    | Unix.ADDR_INET (addr, port) -> Abb_intf.Socket.Sockaddr.(Inet { addr; port })

  let recvfrom t ~buf ~pos ~len =
    let p =
      Future.Promise.create
        ~abort:(fun () ->
          Future.with_state (fun s ->
              let el = Abb_fut.State.state s in
              let el =
                {
                  el with
                  El.reads = Fd_map.remove t el.El.reads;
                  ignore_reads = t :: el.El.ignore_reads;
                }
              in
              let s = Abb_fut.State.set_state el s in
              (s, Future.return ())))
        ()
    in
    let handler s =
      Future.run_with_state
        (Future.Promise.set
           p
           (try
              let n, addr = Unix.recvfrom t ~buf ~pos ~len ~mode:[] in
              Ok (n, sockaddr_of_unix_sockaddr addr)
            with
           | Unix.Unix_error (err, _, _) as exn ->
               let open Unix in
               Error
                 (match err with
                 | EBADF -> `E_bad_file
                 | ECONNRESET -> `E_connection_reset
                 | _ -> `Unexpected exn)
           | exn -> Error (`Unexpected exn)))
        s
    in
    Future.with_state (fun s ->
        let el = Abb_fut.State.state s in
        let el = { el with El.reads = Fd_map.add t handler el.El.reads } in
        let s = Abb_fut.State.set_state el s in
        (s, Future.Promise.future p))

  let sendto t ~bufs sockaddr =
    let p =
      Future.Promise.create
        ~abort:(fun () ->
          Future.with_state (fun s ->
              let el = Abb_fut.State.state s in
              let el =
                {
                  el with
                  El.writes = Fd_map.remove t el.El.writes;
                  ignore_writes = t :: el.El.ignore_writes;
                }
              in
              let s = Abb_fut.State.set_state el s in
              (s, Future.return ())))
        ()
    in
    let addr = unix_sockaddr_of_sockaddr sockaddr in
    let rec send' total = function
      | [] -> Future.Promise.set p (Ok total)
      | wb :: bufs -> (
          try
            let n =
              Unix.sendto
                t
                ~buf:wb.Abb_intf.Write_buf.buf
                ~pos:wb.Abb_intf.Write_buf.pos
                ~len:wb.Abb_intf.Write_buf.len
                ~mode:[]
                ~addr
            in
            (* FIXME Make this handle incomplete sends *)
            assert (n = wb.Abb_intf.Write_buf.len);
            send' (n + total) bufs
          with
          | Unix.Unix_error (Unix.EAGAIN, _, _) | Unix.Unix_error (Unix.EWOULDBLOCK, _, _) ->
              let handler s = Future.run_with_state (send' total (wb :: bufs)) s in
              Future.with_state (fun s ->
                  let el = Abb_fut.State.state s in
                  let el = { el with El.writes = Fd_map.add t handler el.El.writes } in
                  let s = Abb_fut.State.set_state el s in
                  (s, Future.return ()))
          | Unix.Unix_error (err, _, _) as exn ->
              let open Unix in
              Future.Promise.set
                p
                (Error
                   (match err with
                   | EBADF -> `E_bad_file
                   | EACCES -> `E_access
                   | ENOBUFS -> `E_no_buffers
                   | EHOSTUNREACH -> `E_host_unreachable
                   | EHOSTDOWN -> `E_host_down
                   | ECONNREFUSED -> `E_connection_refused
                   | _ -> `Unexpected exn))
          | exn -> Future.Promise.set p (Error (`Unexpected exn)))
    in
    let open Future.Infix_monad in
    send' 0 bufs >>= fun () -> Future.Promise.future p

  let close t =
    try
      Unix.close t;
      Future.return (Ok ())
    with
    | Unix.Unix_error (err, _, _) as exn ->
        let open Unix in
        Future.return
          (Error
             (match err with
             | EBADF -> `E_bad_file
             | ECONNRESET -> `E_connection_reset
             | _ -> `Unexpected exn))
    | exn -> Future.return (Error (`Unexpected exn))

  let listen t ~backlog =
    try
      Unix.listen t ~max:backlog;
      Ok ()
    with
    | Unix.Unix_error (err, _, _) as exn ->
        let open Unix in
        Error
          (match err with
          | EBADF -> `E_bad_file
          | EDESTADDRREQ -> `E_dest_address_required
          | EINVAL -> `E_invalid
          | EOPNOTSUPP -> `E_op_not_supported
          | _ -> `Unexpected exn)
    | exn -> Error (`Unexpected exn)

  let accept t =
    try
      let fd, _ = Unix.accept ~cloexec:true t in
      Unix.set_nonblock fd;
      Future.return (Ok fd)
    with Unix.Unix_error (Unix.EAGAIN, _, _) | Unix.Unix_error (Unix.EWOULDBLOCK, _, _) ->
      let p =
        Future.Promise.create
          ~abort:(fun () ->
            Future.with_state (fun s ->
                let el = Abb_fut.State.state s in
                let el =
                  {
                    el with
                    El.reads = Fd_map.remove t el.El.reads;
                    ignore_reads = t :: el.El.ignore_reads;
                  }
                in
                let s = Abb_fut.State.set_state el s in
                (s, Future.return ())))
          ()
      in
      let handler s =
        Future.run_with_state
          (Future.Promise.set
             p
             (try
                let fd, _ = Unix.accept t in
                Unix.set_nonblock fd;
                Ok fd
              with
             | Unix.Unix_error (err, _, _) as exn ->
                 let open Unix in
                 Error
                   (match err with
                   | EBADF -> `E_bad_file
                   | EMFILE | ENFILE -> `E_file_table_full
                   | EINVAL -> `E_invalid
                   | ECONNABORTED -> `E_connection_aborted
                   | _ -> `Unexpected exn)
             | exn -> Error (`Unexpected exn)))
          s
      in
      Future.with_state (fun s ->
          let el = Abb_fut.State.state s in
          let el = { el with El.reads = Fd_map.add t handler el.El.reads } in
          let s = Abb_fut.State.set_state el s in
          (s, Future.Promise.future p))

  let readable t =
    let p =
      Future.Promise.create
        ~abort:(fun () ->
          Future.with_state (fun s ->
              let el = Abb_fut.State.state s in
              let el =
                {
                  el with
                  El.reads = Fd_map.remove t el.El.reads;
                  ignore_reads = t :: el.El.ignore_reads;
                }
              in
              let s = Abb_fut.State.set_state el s in
              (s, Future.return ())))
        ()
    in
    let handler s = Future.run_with_state (Future.Promise.set p ()) s in
    Future.with_state (fun s ->
        let el = Abb_fut.State.state s in
        let el = { el with El.reads = Fd_map.add t handler el.El.reads } in
        let s = Abb_fut.State.set_state el s in
        (s, Future.Promise.future p))

  let writable t =
    let p =
      Future.Promise.create
        ~abort:(fun () ->
          Future.with_state (fun s ->
              let el = Abb_fut.State.state s in
              let el =
                {
                  el with
                  El.writes = Fd_map.remove t el.El.writes;
                  ignore_writes = t :: el.El.ignore_writes;
                }
              in
              let s = Abb_fut.State.set_state el s in
              (s, Future.return ())))
        ()
    in
    let handler s = Future.run_with_state (Future.Promise.set p ()) s in
    Future.with_state (fun s ->
        let el = Abb_fut.State.state s in
        let el = { el with El.writes = Fd_map.add t handler el.El.writes } in
        let s = Abb_fut.State.set_state el s in
        (s, Future.Promise.future p))

  let create_sock ~kind ~domain =
    (* FIXME Possible leak here? *)
    try
      let t = Unix.socket ~cloexec:true ~domain:(unix_of_domain domain) ~kind ~protocol:0 in
      Unix.set_nonblock t;
      Ok t
    with
    | Unix.Unix_error (err, _, _) as exn ->
        let open Unix in
        Error
          (match err with
          | EACCES -> `E_access
          | EAFNOSUPPORT -> `E_address_family_not_supported
          | EMFILE | ENFILE -> `E_file_table_full
          | ENOBUFS -> `E_no_buffers
          | EPERM -> `E_permission
          | EPROTONOSUPPORT -> `E_protocol_not_supported
          | EPROTOTYPE -> `E_protocol_type
          | _ -> `Unexpected exn)
    | exn -> Error (`Unexpected exn)

  module Tcp = struct
    let to_native t = t
    let of_native t = t
    let create = create_sock ~kind:Unix.SOCK_STREAM

    let bind t addr =
      try
        Unix.setsockopt t Unix.SO_REUSEADDR true;
        let sa = unix_sockaddr_of_sockaddr addr in
        Unix.bind t ~addr:sa;
        Ok ()
      with
      | Unix.Unix_error (err, _, _) as exn ->
          let open Unix in
          Error
            (match err with
            | ENOTSOCK | EBADF -> `E_bad_file
            | EAGAIN -> `E_again
            | EINVAL -> `E_invalid
            | EADDRNOTAVAIL -> `E_address_not_available
            | EADDRINUSE -> `E_address_in_use
            | EAFNOSUPPORT -> `E_address_family_not_supported
            | EACCES -> `E_access
            | ENOTDIR -> `E_not_dir
            | EROFS | EPERM -> `E_permission
            | ENAMETOOLONG -> `E_name_too_long
            | ENOENT -> `E_no_entity
            | ELOOP -> `E_loop
            | EIO -> `E_io
            | EISDIR -> `E_is_dir
            | _ -> `Unexpected exn)
      | exn -> Error (`Unexpected exn)

    let connect t addr =
      let open Future.Infix_monad in
      let p =
        Future.Promise.create
          ~abort:(fun () ->
            Future.with_state (fun s ->
                let el = Abb_fut.State.state s in
                let el =
                  {
                    el with
                    El.writes = Fd_map.remove t el.El.writes;
                    ignore_writes = t :: el.El.ignore_writes;
                  }
                in
                let s = Abb_fut.State.set_state el s in
                (s, Future.return ())))
          ()
      in
      let sa = unix_sockaddr_of_sockaddr addr in
      try
        Unix.connect t ~addr:sa;
        Future.Promise.set p (Ok ()) >>= fun () -> Future.Promise.future p
      with
      | Unix.Unix_error (Unix.EINPROGRESS, _, _) ->
          let handler s = Future.run_with_state (Future.Promise.set p (Ok ())) s in
          Future.with_state (fun s ->
              let el = Abb_fut.State.state s in
              let el = { el with El.writes = Fd_map.add t handler el.El.writes } in
              let s = Abb_fut.State.set_state el s in
              (s, Future.Promise.future p))
      | Unix.Unix_error (err, _, _) as exn ->
          let open Unix in
          Future.return
            (Error
               (match err with
               | EBADF -> `E_bad_file
               | EINVAL -> `E_invalid
               | EADDRNOTAVAIL -> `E_address_not_available
               | EAFNOSUPPORT -> `E_address_family_not_supported
               | EISCONN -> `E_is_connected
               | ECONNREFUSED -> `E_connection_refused
               | ECONNRESET -> `E_connection_reset
               | ENETUNREACH -> `E_network_unreachable
               | EHOSTUNREACH -> `E_host_unreachable
               | EADDRINUSE -> `E_address_in_use
               | EACCES -> `E_access
               | _ -> `Unexpected exn))
      | exn -> Future.return (Error (`Unexpected exn))

    let recv t ~buf ~pos ~len =
      let p =
        Future.Promise.create
          ~abort:(fun () ->
            Future.with_state (fun s ->
                let el = Abb_fut.State.state s in
                let el =
                  {
                    el with
                    El.reads = Fd_map.remove t el.El.reads;
                    ignore_reads = t :: el.El.ignore_reads;
                  }
                in
                let s = Abb_fut.State.set_state el s in
                (s, Future.return ())))
          ()
      in
      let handler s =
        Future.run_with_state
          (Future.Promise.set
             p
             (try Ok (Unix.recv t ~buf ~pos ~len ~mode:[]) with
             | Unix.Unix_error (err, _, _) as exn ->
                 let open Unix in
                 Error
                   (match err with
                   | ENOTSOCK | EBADF -> `E_bad_file
                   | ECONNRESET -> `E_connection_reset
                   | ENOTCONN -> `E_not_connected
                   | _ -> `Unexpected exn)
             | exn -> Error (`Unexpected exn)))
          s
      in
      Future.with_state (fun s ->
          let el = Abb_fut.State.state s in
          let el = { el with El.reads = Fd_map.add t handler el.El.reads } in
          let s = Abb_fut.State.set_state el s in
          (s, Future.Promise.future p))

    let send t ~bufs =
      let p =
        Future.Promise.create
          ~abort:(fun () ->
            Future.with_state (fun s ->
                let el = Abb_fut.State.state s in
                let el =
                  {
                    el with
                    El.writes = Fd_map.remove t el.El.writes;
                    ignore_writes = t :: el.El.ignore_writes;
                  }
                in
                let s = Abb_fut.State.set_state el s in
                (s, Future.return ())))
          ()
      in
      let rec send' total = function
        | [] -> Future.Promise.set p (Ok total)
        | wb :: bufs -> (
            try
              let n =
                Unix.send
                  t
                  ~buf:wb.Abb_intf.Write_buf.buf
                  ~pos:wb.Abb_intf.Write_buf.pos
                  ~len:wb.Abb_intf.Write_buf.len
                  ~mode:[]
              in
              send' (total + n) bufs
            with
            | Unix.Unix_error (Unix.EAGAIN, _, _) | Unix.Unix_error (Unix.EWOULDBLOCK, _, _) ->
                let handler s = Future.run_with_state (send' total (wb :: bufs)) s in
                Future.with_state (fun s ->
                    let el = Abb_fut.State.state s in
                    let el = { el with El.writes = Fd_map.add t handler el.El.writes } in
                    let s = Abb_fut.State.set_state el s in
                    (s, Future.return ()))
            | Unix.Unix_error (err, _, _) as exn ->
                let open Unix in
                Future.Promise.set
                  p
                  (Error
                     (match err with
                     | ENOTSOCK | EBADF -> `E_bad_file
                     | EACCES -> `E_access
                     | ENOBUFS -> `E_no_buffers
                     | EHOSTUNREACH -> `E_host_unreachable
                     | EHOSTDOWN -> `E_host_down
                     | EPIPE -> `E_pipe
                     | _ -> `Unexpected exn))
            | exn -> Future.Promise.set p (Error (`Unexpected exn)))
      in
      let open Future.Infix_monad in
      send' 0 bufs >>= fun () -> Future.Promise.future p

    let nodelay t enabled =
      try
        Unix.setsockopt t Unix.TCP_NODELAY enabled;
        Ok ()
      with
      | Unix.Unix_error (err, _, _) as exn ->
          let open Unix in
          Error
            (match err with
            | ENOTSOCK | EBADF -> `E_bad_file
            | _ -> `Unexpected exn)
      | exn -> Error (`Unexpected exn)
  end

  module Udp = struct
    let to_native t = t
    let of_native t = t
    let create = create_sock ~kind:Unix.SOCK_DGRAM
    let bind = Tcp.bind
  end
end

module Process = struct
  module Pid = struct
    type t = int
    type native = int

    let of_native n = n
    let to_native t = t
  end

  type t = {
    pid : Pid.t;
    exit_code : Abb_intf.Process.Exit_code.t Future.t;
  }

  let int_of_signal = function
    | Abb_intf.Process.Signal.SIGHUP -> 1
    | Abb_intf.Process.Signal.SIGINT -> 2
    | Abb_intf.Process.Signal.SIGQUIT -> 3
    | Abb_intf.Process.Signal.SIGABRT -> 6
    | Abb_intf.Process.Signal.SIGKILL -> 9
    | Abb_intf.Process.Signal.SIGBUS -> 10
    | Abb_intf.Process.Signal.SIGSEGV -> 11
    | Abb_intf.Process.Signal.SIGPIPE -> 13
    | Abb_intf.Process.Signal.SIGALRM -> 14
    | Abb_intf.Process.Signal.SIGTERM -> 15
    | Abb_intf.Process.Signal.SIGSTOP -> 17
    | Abb_intf.Process.Signal.SIGCONT -> 19
    | Abb_intf.Process.Signal.SIGCHLD -> 20
    | Abb_intf.Process.Signal.SIGUSR1 -> 30
    | Abb_intf.Process.Signal.SIGUSR2 -> 31
    | Abb_intf.Process.Signal.Num s -> s

  let signal_of_int = function
    | 1 -> Abb_intf.Process.Signal.SIGHUP
    | 2 -> Abb_intf.Process.Signal.SIGINT
    | 3 -> Abb_intf.Process.Signal.SIGQUIT
    | 6 -> Abb_intf.Process.Signal.SIGABRT
    | 9 -> Abb_intf.Process.Signal.SIGKILL
    | 10 -> Abb_intf.Process.Signal.SIGBUS
    | 11 -> Abb_intf.Process.Signal.SIGSEGV
    | 13 -> Abb_intf.Process.Signal.SIGPIPE
    | 14 -> Abb_intf.Process.Signal.SIGALRM
    | 15 -> Abb_intf.Process.Signal.SIGTERM
    | 17 -> Abb_intf.Process.Signal.SIGSTOP
    | 19 -> Abb_intf.Process.Signal.SIGCONT
    | 20 -> Abb_intf.Process.Signal.SIGCHLD
    | 30 -> Abb_intf.Process.Signal.SIGUSR1
    | 31 -> Abb_intf.Process.Signal.SIGUSR2
    | n -> Abb_intf.Process.Signal.Num n

  let wait_on_pid pid =
    Thread.run (fun () ->
        let pid', signal = Unix.waitpid ~mode:[] pid in
        assert (pid = pid');
        match signal with
        | Unix.WEXITED code -> Abb_intf.Process.Exit_code.Exited code
        | Unix.WSIGNALED code -> Abb_intf.Process.Exit_code.Signaled (signal_of_int code)
        | Unix.WSTOPPED code -> Abb_intf.Process.Exit_code.Stopped (signal_of_int code))

  let spawn ~stdin ~stdout ~stderr init_args =
    try
      let pid =
        let module P = Abb_intf.Process in
        match init_args.P.env with
        | Some env ->
            let env =
              CCArray.of_list @@ CCList.map (fun (k, v) -> CCString.concat "=" [ k; v ]) env
            in
            Unix.create_process_env
              ~prog:init_args.P.exec_name
              ~args:(CCArray.of_list init_args.P.args)
              ~env
              ~stdin
              ~stdout
              ~stderr
        | None ->
            Unix.create_process
              ~prog:init_args.P.exec_name
              ~args:(CCArray.of_list init_args.P.args)
              ~stdin
              ~stdout
              ~stderr
      in
      Ok { pid; exit_code = wait_on_pid pid }
    with
    | Unix.Unix_error (err, _, _) as exn ->
        let open Unix in
        Error
          (match err with
          | EAGAIN -> `E_again
          | ENOMEM -> `E_no_memory
          | _ -> `Unexpected exn)
    | exn -> Error (`Unexpected exn)

  let pid t = t.pid
  let wait t = t.exit_code

  let exit_code t =
    match Future.state t.exit_code with
    | `Det exit_code -> Some exit_code
    | `Undet | `Aborted | `Exn _ -> None

  let signal_pid ~pid signal = Unix.kill ~pid ~signal:(int_of_signal signal)
  let signal t signal = signal_pid ~pid:t.pid signal
end
