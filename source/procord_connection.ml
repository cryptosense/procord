(******************************************************************************)
(*                                  Connections                               *)
(******************************************************************************)

(** Possible states of connections. *)
type state =
  | Connecting
      (** Waiting for the connection to be established. *)
  | Connected
      (** Connection successful and still alive. *)
  | Disconnecting
      (** Finishing sending, will be disconnected just after. *)
  | Disconnected of (Unix.error * string * string) option
      (** Connection failed, lost, closed or reset by peer.
          If the error is [None], the socket was closed locally.
          The strings are, respectively, the name of the function which
          failed and the string argument to the function, if any. *)

type connection_kind =
  {
    ck_input: Unix.file_descr option;
    ck_output: Unix.file_descr option;
    ck_input_is_a_socket: bool;
    ck_output_is_a_socket: bool;
    ck_input_equals_output: bool;
    ck_remote_address: Unix.sockaddr;
  }

(* The type of connections. *)
type 'a t =
  {
    kind: connection_kind;
    data: 'a;

    mutable send_buffer: Procord_rope.t;
      (* Data to send. *)
    mutable receive_buffer: Procord_rope.t;
      (* Data received but not yet read. *)
    max_receive_buffer_size: int;

    timeout: float option;
      (* The ?timeout argument given to [make]. *)
    ping: string option;
      (* The ?ping argument given to [make]. *)
    mutable idle_starting_time: float;
      (* Set to Unix.gettimeofday everytime a byte is received. *)
    mutable ping_sent: bool;
      (* Has a PING message been sent since the last time
         idle_starting_time was updated? If ping is None, this field may
         still be true (tried to send a ping but no ping to send). *)

    mutable state: state;
      (* [false] if closed. *)

    mutable close_when_sent: float option option;
      (* If [Some timeout], close the connection as soon as send_buffer is
         empty, or, if [timeout] is given, when Unix.gettimeofday is greater
         or equal than [timeout]. *)
  }

(* Call [f x] in an environment where SIGPIPE is transformed as an
   Unix.Unix_error exception.

   Not thread-safe: if another thread changes the handler, something bad
   could happen.

   See:
     http://stackoverflow.com/questions/108183/how-to-prevent-sigpipes-or-handle-them-properly *)
let prevent_sigpipe f x =
  (* Set our own signal handler. *)
  let raise_EPIPE _ =
    raise (Unix.Unix_error (Unix.EPIPE, "(signal)", ""))
  in
  let old_handler =
    try
      Some (Sys.signal Sys.sigpipe (Sys.Signal_handle raise_EPIPE))
    with Invalid_argument _ ->
        (* On the current platform, Sys.set_signal is not implemented. *)
        None
  in
  (* Restore the old handler as the SIGPIPE signal handler. *)
  let restore_handler () =
    match old_handler with
      | None ->
          (* "None" means that the old handler was not replaced by ours. *)
          ()
      | Some handler ->
          try
            Sys.set_signal Sys.sigpipe handler;
          with Invalid_argument _ ->
              ()
  in
  (* try ... finally *)
  try
    let result = f x in
    restore_handler ();
    result
  with exn ->
      restore_handler ();
      raise exn

(* Make a [connection_kind] from a socket file descriptor. *)
let socket_kind socket remote_address =
  {
    ck_input = Some socket;
    ck_output = Some socket;
    ck_input_is_a_socket = true;
    ck_output_is_a_socket = true;
    ck_input_equals_output = true;
    ck_remote_address = remote_address;
  }

(* Return all input file descriptors of a connection. *)
let inputs_of_kind kind =
  match kind.ck_input with
    | None ->
        []
    | Some fd ->
        [ fd ]

(* Return all output file descriptors of a connection. *)
let outputs_of_kind kind =
  match kind.ck_output with
    | None ->
        []
    | Some fd ->
        [ fd ]

(* Return all file descriptors of a connection kind. *)
let file_descriptors_of_kind kind =
  if kind.ck_input_equals_output then
    inputs_of_kind kind
  else
    inputs_of_kind kind @ outputs_of_kind kind

(* Same as [List.iter] but ignore exceptions. *)
let list_iter_try f l =
  List.iter (fun x -> try f x with _ -> ()) l

(* Make a connection record. *)
let make_connection ?timeout ?ping kind data state =
  (* Force non-blocking mode on file descriptors. *)
  list_iter_try
    Unix.set_nonblock
    (file_descriptors_of_kind kind);

  (* Make the record. *)
  {
    kind;
    data;
    send_buffer = Procord_rope.empty;
    receive_buffer = Procord_rope.empty;
    max_receive_buffer_size = 65536;
    timeout;
    ping;
    idle_starting_time = Unix.gettimeofday ();
    ping_sent = false;
    state;
    close_when_sent = None;
  }

let make_address hostname =
  try
    let host = Unix.gethostbyname hostname in
    let addresses = host.Unix.h_addr_list in
    if Array.length addresses > 0 then
      addresses.(0)
    else
      raise Not_found
  with
    | Not_found ->
        (* The address may be an IP address or an IPv6 address. *)
        try
          Unix.inet_addr_of_string hostname
        with
          | _ ->
              (* Give up. *)
              raise
                (Unix.Unix_error
                   (Unix.EFAULT, "Procord_connection.make_address", hostname))

let alive connection =
  match connection.state with
    | Connecting
    | Connected
    | Disconnecting ->
        true
    | Disconnected _ ->
        false

let closing_nicely connection =
  match connection.state with
    | Disconnecting ->
        true
    | Connecting
    | Connected
    | Disconnected _ ->
        false

(* Close the socket if not closed already, and set the state to Disconnected
   with the given reason. *)
let disconnect reason connection =
  if alive connection then
    begin
      (* Close file descriptors if possible. *)
      list_iter_try
        Unix.close
        (file_descriptors_of_kind connection.kind);
      (* Set the state to Disconnected. *)
      connection.state <- Disconnected reason;
      (* If the socket is closed, we cannot send anything anymore.
         We may still want to read the data in the receive buffer though. *)
      connection.send_buffer <- Procord_rope.empty;
    end

(* Call [Unix.shutdown] on the output, if it is a socket, to signify that we
   have nothing else to send. *)
let shutdown_sending_sockets connection =
  if connection.kind.ck_output_is_a_socket then
    match connection.kind.ck_output with
      | None ->
          ()
      | Some output ->
          try
            Unix.shutdown output Unix.SHUTDOWN_SEND
          with Unix.Unix_error (error, fname, sarg) ->
            disconnect (Some (error, fname, sarg)) connection

let connect ?timeout ?ping hostname port data =
  let address = Unix.ADDR_INET (make_address hostname, port) in
  let domain = Unix.domain_of_sockaddr address in
  (* Unix.socket and Unix.set_nonblock may fail, but for reasons which
     are a little specific. *)
  let socket = Unix.socket domain Unix.SOCK_STREAM 0 in
  let kind = socket_kind socket address in
  let connection = make_connection ?timeout ?ping kind data Connecting in
  try
    Unix.connect socket address;
    (* Because of the non-blocking mode we should never be here: connect should
       raise EINPROGRESS. Note that on Windows the Unix implementation
       raises EWOULDBLOCK instead. *)
    connection
  with
    | Unix.Unix_error ((Unix.EINPROGRESS | Unix.EWOULDBLOCK), _, _) ->
        connection
    | Unix.Unix_error (error, fname, sarg) ->
        (* Possible reasons:
           - EADDRINUSE, but this is normally not possible as we do not
             specify the local port;
           - ECONNREFUSED, connection refused;
           - ENETUNREACH, network unreachable. *)
        disconnect (Some (error, fname, sarg)) connection;
        connection

let send_rope connection data =
  if
    alive connection
    && not (closing_nicely connection)
    && connection.kind.ck_output <> None
  then
    connection.send_buffer <- Procord_rope.concat connection.send_buffer data

let send connection data =
  send_rope connection (Procord_rope.of_string data)

let receive_rope connection length =
  let buffer = connection.receive_buffer in
  let buffer_length = Procord_rope.length buffer in
  if buffer_length >= length then
    begin
      let data = Procord_rope.sub buffer 0 length in
      connection.receive_buffer <-
        Procord_rope.sub buffer length (buffer_length - length);
      Some data
    end
  else
    None

let receive connection length =
  match receive_rope connection length with
    | None ->
        None
    | Some rope ->
        Some (Procord_rope.to_string rope)

let receive_rope_poll connection offset length =
  let buffer = connection.receive_buffer in
  let buffer_length = Procord_rope.length buffer in
  if buffer_length >= offset + length then
    begin
      let data = Procord_rope.sub buffer offset length in
      Some data
    end
  else
    None

let receive_poll connection offset length =
  match receive_rope_poll connection offset length with
    | None ->
        None
    | Some rope ->
        Some (Procord_rope.to_string rope)

let receive_rope_poll_part connection offset length =
  let buffer = connection.receive_buffer in
  let buffer_length = Procord_rope.length buffer in
  if buffer_length >= offset + length then
    Procord_rope.sub buffer offset length
  else if buffer_length >= offset then
    Procord_rope.sub buffer offset (buffer_length - offset)
  else
    Procord_rope.empty

let receive_poll_part connection offset length =
  let rope = receive_rope_poll_part connection offset length in
  Procord_rope.to_string rope

let receive_all connection =
  let buffer = connection.receive_buffer in
  connection.receive_buffer <- Procord_rope.empty;
  Procord_rope.to_string buffer

let receive_part connection length =
  let buffer = connection.receive_buffer in
  let buffer_length = Procord_rope.length buffer in
  if buffer_length >= length then
    match receive connection length with
      | None ->
          assert false
      | Some result ->
          result
  else
    receive_all connection

let receive_forget connection length =
  let buffer = connection.receive_buffer in
  let buffer_length = Procord_rope.length buffer in
  if buffer_length >= length then
    connection.receive_buffer <-
      Procord_rope.sub buffer length (buffer_length - length)

let receive_buffer_length connection =
  let buffer = connection.receive_buffer in
  Procord_rope.length buffer

let receive_buffer_empty connection =
  let buffer = connection.receive_buffer in
  Procord_rope.is_empty buffer

(* Return [true] if the connection is still active according to idle time. *)
let check_idle_connection connection =
  match connection.timeout with
    | None ->
        true
    | Some max_idle_delay ->
        let idle_delay =
          Unix.gettimeofday () -. connection.idle_starting_time
        in
        if idle_delay >= max_idle_delay /. 2. && not connection.ping_sent then
          begin
            begin
              match connection.ping with
                | None ->
                    ()
                | Some ping ->
                    send connection ping
            end;
            connection.ping_sent <- true;
            true
          end
        else
          idle_delay < max_idle_delay

let unix_error_means_disconnected error =
  let open Unix in
  match error with
    | E2BIG (* Argument list too long *)
    | EACCES (* Permission denied *)
    | EAGAIN (* Resource temporarily unavailable; try again *)
      -> false
    | EBADF (* Bad file descriptor *)
      (* Socket already closed? *)
      -> true
    | EBUSY (* Resource unavailable *)
    | ECHILD (* No child process *)
    | EDEADLK (* Resource deadlock would occur *)
    | EDOM (* Domain error for math functions, etc. *)
    | EEXIST (* File exists *)
    | EFAULT (* Bad address *)
    | EFBIG (* File too large *)
    | EINTR (* Function interrupted by signal *)
    | EINVAL (* Invalid argument *)
    | EIO (* Hardware I/O error *)
    | EISDIR (* Is a directory *)
    | EMFILE (* Too many open files by the process *)
    | EMLINK (* Too many links *)
    | ENAMETOOLONG (* Filename too long *)
    | ENFILE (* Too many open files in the system *)
    | ENODEV (* No such device *)
    | ENOENT (* No such file or directory *)
    | ENOEXEC (* Not an executable file *)
    | ENOLCK (* No locks available *)
    | ENOMEM (* Not enough memory *)
    | ENOSPC (* No space left on device *)
    | ENOSYS (* Function not supported *)
    | ENOTDIR (* Not a directory *)
    | ENOTEMPTY (* Directory not empty *)
    | ENOTTY (* Inappropriate I/O control operation *)
    | ENXIO (* No such device or address *)
    | EPERM (* Operation not permitted *)
    | EPIPE (* Broken pipe *)
    | ERANGE (* Result too large *)
    | EROFS (* Read-only file system *)
    | ESPIPE (* Invalid seek e.g. on a pipe *)
    | ESRCH (* No such process *)
    | EXDEV (* Invalid link *)
    | EWOULDBLOCK (* Operation would block *)
    | EINPROGRESS (* Operation now in progress *)
    | EALREADY (* Operation already in progress *)
      -> false
    | ENOTSOCK (* Socket operation on non-socket *)
      (* If it is not a socket, then it cannot be connected. *)
      -> true
    | EDESTADDRREQ (* Destination address required *)
    | EMSGSIZE (* Message too long *)
      -> false
    | EPROTOTYPE (* Protocol wrong type for socket *)
    | ENOPROTOOPT (* Protocol not available *)
    | EPROTONOSUPPORT (* Protocol not supported *)
    | ESOCKTNOSUPPORT (* Socket type not supported *)
    | EOPNOTSUPP (* Operation not supported on socket *)
    | EPFNOSUPPORT (* Protocol family not supported *)
    | EAFNOSUPPORT (* Address family not supported by protocol family *)
    | EADDRINUSE (* Address already in use *)
    | EADDRNOTAVAIL (* Can't assign requested address *)
    | ENETDOWN (* Network is down *)
    | ENETUNREACH (* Network is unreachable *)
    | ENETRESET (* Network dropped connection on reset *)
    | ECONNABORTED (* Software caused connection abort *)
    | ECONNRESET (* Connection reset by peer *)
      (* All those errors can be the result of Unix.connect failing
         asynchronously due to the non-blocking mode, or because the connection
         was lost. *)
      -> true
    | ENOBUFS (* No buffer space available *)
    | EISCONN (* Socket is already connected *)
      -> false
    | ENOTCONN (* Socket is not connected *)
    | ESHUTDOWN (* Can't send after socket shutdown *)
      -> true
    | ETOOMANYREFS (* Too many references: can't splice *)
      -> false
    | ETIMEDOUT (* Connection timed out *)
    | ECONNREFUSED (* Connection refused *)
    | EHOSTDOWN (* Host is down *)
    | EHOSTUNREACH (* No route to host *)
      -> true
    | ELOOP (* Too many levels of symbolic links *)
    | EOVERFLOW (* File size or position not representable *)
    | EUNKNOWNERR _ (* Unknown error *)
      -> false

(* Auxiliary function for [update_fd], called in the case that there
   actually is an output file descriptor. *)
let update_send_fd connection output is_a_socket =
  let sent = ref 0 in
  let buffer = connection.send_buffer in
  (* Try to send pieces of the rope until we can't. *)
  begin
    try
      Procord_rope.iter_string_pieces buffer
        begin fun string offset length ->
          try
            let newly_sent =
              (* Unix.write is, in principle, equivalent to Unix.send
                 except that it lacks the message flags
                 parameters. However this is only in principle. Maybe
                 on some OSes it is not the case. *)
              if is_a_socket then
                prevent_sigpipe (Unix.send output string offset length) []
              else
                prevent_sigpipe (Unix.write output string offset) length
            in
            (* If no data was sent, we must try again later and not
               continue with the rest of the buffer. *)
            if newly_sent = 0 then raise Exit;
            sent := !sent + newly_sent
          with
            | Unix.Unix_error (error, fname, sarg)  ->
                if unix_error_means_disconnected error then
                  disconnect (Some (error, fname, sarg)) connection;
                (* Possible reasons not to close:
                   - EMSGSIZE, but normally not for TCP;
                   - EAGAIN or EWOULDBLOCK, try again later;
                   - ENOBUFS, same as EAGAIN but normally not on Linux;
                   - ENOMEM, seems similar to ENOBUFS but worse.
                   We just ignore the error and try again later. *)
                raise Exit
        end
    with Exit ->
        ()
  end;
  (* The connection may have been closed, so we check before continuing. *)
  if alive connection then
    connection.send_buffer <-
      Procord_rope.sub buffer !sent (Procord_rope.length buffer - !sent)

let update_send connection =
  match connection.kind.ck_output with
    | None ->
        (* Nowhere to send, we ignore. *)
        ()
    | Some output ->
        update_send_fd connection output connection.kind.ck_output_is_a_socket

(* Auxiliary function for [update_receive], called in the case that there
   actually is an input file descriptor. *)
let update_receive_fd connection input is_a_socket =
  (* Try to receive data until we can't. *)
  let continue = ref true in
  while
    !continue
    && Procord_rope.length connection.receive_buffer
       < connection.max_receive_buffer_size
  do
    (* Create a buffer to receive data.
       The buffer must be new each time we call recv, or it will be overwritten
       in the rope. *)
    let receive_buffer_size = 512 in
    let receive_buffer = String.create receive_buffer_size in
    try
      (* On Windows, set_nonblock seems to have no effect. Maybe on some other
         platforms too. So we check that there is something to read using
         [Unix.select] to ensure reading will not block. *)
      begin
        match Unix.select [ input ] [] [] 0. with
          | [ _ ], _, _ ->
              (* There is something to read. *)
              ()
          | _ ->
              (* Nothing to read. *)
              raise
                (Unix.Unix_error
                   (Unix.EAGAIN, "Procord_connection.update_receive_fd", ""))
      end;
      let count =
        (* Unix.read is, in principle, equivalent to Unix.recv except
           that it lacks the message flags parameters. However this
           is only in principle. Maybe on some OSes it is not the case. *)
        if is_a_socket then
          prevent_sigpipe
            (Unix.recv input receive_buffer 0 receive_buffer_size) []
        else
          prevent_sigpipe (Unix.read input receive_buffer 0) receive_buffer_size
      in
      (* If the count is 0, and yet there is no error, then it means
         "end of file": the connection has been closed from the other side. *)
      if count = 0 then
        raise
          (Unix.Unix_error
             (Unix.ECONNRESET, "Procord_connection.update_receive", ""))
      else
        begin
          connection.idle_starting_time <- Unix.gettimeofday ();
          connection.ping_sent <- false;
          connection.receive_buffer <-
            Procord_rope.concat
              connection.receive_buffer
              (Procord_rope.sub (Procord_rope.of_string receive_buffer) 0 count)
        end
    with
      | Unix.Unix_error (e, fname, sarg) when unix_error_means_disconnected e ->
          disconnect (Some (e, fname, sarg)) connection;
          continue := false
      | Unix.Unix_error _ ->
          (* Possible reasons:
             - EAGAIN or EWOULDBLOCK, try again later;
             - ENOMEM, seems awful.
             We just ignore the error and stop trying to receive data
             for now. *)
          continue := false
  done

let update_receive connection =
  match connection.kind.ck_input with
    | None ->
        (* Nothing to receive, nowhere to receive from. *)
        ()
    | Some input ->
        update_receive_fd connection input connection.kind.ck_input_is_a_socket

let sending connection =
  not (Procord_rope.is_empty connection.send_buffer)

let timed_out_error =
  Unix.ETIMEDOUT, "Procord_connection.check_auto_close", ""

let check_auto_close connection =
  if alive connection then
    begin
      (* Disconnection due to idle peer? *)
      if not (check_idle_connection connection) then
        disconnect (Some timed_out_error) connection;

      (* Disconnection due to close_nicely? *)
      match connection.close_when_sent with
        | None ->
            (* No close_nicely. *)
            ()
        | Some timeout ->
            (* close_nicely was called. *)
            if sending connection then
              (* Still sending stuff, check timeout. *)
              match timeout with
                | Some timeout when Unix.gettimeofday () >= timeout ->
                    (* Time is out. *)
                    disconnect (Some timed_out_error) connection
                | _ ->
                    (* Wait. *)
                    ()
            else
              (* Nothing left to send, we can close. *)
              (* shutdown_sending_sockets connection; *)
              disconnect None connection
    end

(* Update a connection, assuming it is in the [Connecting] state, and
   assuming it is a socket connection. *)
let update_connecting_socket connection socket =
  (* Are we connected yet? To know this, first we need to test, using
     Unix.select, whether we can write to the socket file
     descriptor. We cannot write until the socket is either connected
     or failed to connect. Then, and only then, getsockopt_error will
     return either None or an error. It will report the error only
     once. *)
  try
    let may_call_getsockopt_error =
      match Unix.select [] [ socket ] [ socket ] 0. with
        | _, [ _ ], _
        | _, _, [ _ ] ->
            (* The next call to getsockopt_error will tell us whether we
               are connected. *)
            true
        | _ ->
            (* Still waiting. *)
            false
    in
    if may_call_getsockopt_error then
      match Unix.getsockopt_error socket with
        | None ->
            (* Connection successful. *)
            connection.state <- Connected
        | Some (_ as reason) ->
            (* Connection failed. *)
            disconnect (Some (reason, "getsockopt_error", "")) connection
    else
      check_auto_close connection
  with
    | Unix.Unix_error (error, fname, sarg) ->
        (* May possibly happen with EBADF on Unix.select. *)
        disconnect (Some (error, fname, sarg)) connection

(* Update a connection, assuming it is in the [Connecting] state. *)
let update_connecting connection =
  (* Update for the input socket. *)
  if connection.kind.ck_input_is_a_socket then
    begin match connection.kind.ck_input with
      | None ->
          (* Should not happen. *)
          ()
      | Some socket ->
          update_connecting_socket connection socket
    end;

  (* Update for the output socket if it is different than the input socket,
     and if the connection is Connected. Note that we never tried to check
     for connection on the output socket before (unless it is a custom
     connection and the user did it), so getsockopt_error will indeed cause
     the Disconnect state if needed.*)
  if
    connection.kind.ck_output_is_a_socket
    && not connection.kind.ck_input_equals_output
    && match connection.state with
      | Connected -> true
      | Connecting | Disconnecting | Disconnected _ -> false
  then
    begin match connection.kind.ck_output with
      | None ->
          (* Should not happen. *)
          ()
      | Some socket ->
          (* The output socket is still in the Connecting state, so is the
             connection. This may imply re-checking for the connection of the
             input socket, but it is not a big deal (actually, re-checking for
             errors as we do might even be a good idea). *)
          connection.state <- Connecting;
          update_connecting_socket connection socket
    end;

  (* Finally, special case if neither the input nor the output is a socket:
     in this case, we are already connected. *)
  if
    not connection.kind.ck_input_is_a_socket
    && not connection.kind.ck_output_is_a_socket
  then
    connection.state <- Connected

let update connection =
  match connection.state with
    | Connecting ->
        (* Check whether we are connected. *)
        update_connecting connection

    | Connected | Disconnecting ->
        (* Send buffered data. *)
        update_send connection;

        (* Receive data and buffer it. *)
        if alive connection then
          begin
            update_receive connection;
            check_auto_close connection;
          end

    | Disconnected _ ->
        (* Nothing to update, one cannot revive a connection. *)
        ()

let data connection =
  connection.data

let close connection =
  disconnect None connection

let close_nicely ?timeout connection =
  if alive connection then
    begin
      begin
        match timeout with
          | None ->
              connection.close_when_sent <- Some None
          | Some timeout ->
              connection.close_when_sent <-
                Some (Some (Unix.gettimeofday () +. timeout))
      end;
      connection.state <- Disconnecting
    end

let state connection =
  connection.state

let remote_address connection =
  connection.kind.ck_remote_address

(******************************************************************************)
(*                               Connections Sets                             *)
(******************************************************************************)

type 'a set = 'a t list ref

let empty_set () =
  ref []

let rec accept_into_set ?timeout ?ping listening_socket make_data connections =
  try
    (* Try to accept one connection. *)
    let client_socket, client_address = Unix.accept listening_socket in

    (* Add the connection to the set. *)
    begin
      match make_data client_address with
        | Some data ->
            connections :=
              make_connection ?timeout ?ping
                (socket_kind client_socket client_address)
                data
                Connected
              :: !connections
        | None ->
            (* Refuse the connection. Actually, it has been accepted already,
               so just close it. *)
            try
              Unix.close client_socket
            with _ ->
              ()
    end;

    (* Continue accepting connections. *)
    accept_into_set listening_socket make_data connections
  with
    | Unix.Unix_error (Unix.EBADF, _, _) as exn ->
        (* This error means the listening socket is closed. It is bad enough
           that we want to re-raise it. *)
        raise exn
    | Unix.Unix_error _ ->
        (* No connection to accept.
           Usually the error can be:
           - EWOULDBLOCK or EAGAIN (nothing to accept right now);
           - ECONNABORTED (connection aborted for some reason);
           - EPERM (firewall refused connection). *)
        ()

let update_set connections =
  (* Update each client connection. *)
  List.iter update !connections;

  (* Remove idle and closed connections. *)
  connections := List.filter alive !connections

let iter connections f =
  List.iter f !connections

(******************************************************************************)
(*                                    Waiting                                 *)
(******************************************************************************)

(* Function which grows the lists given in its argument. *)
type waiter =
  Unix.file_descr list * Unix.file_descr list * Unix.file_descr list ->
  Unix.file_descr list * Unix.file_descr list * Unix.file_descr list

(* Traps which are easy to fall into even though they sound obvious:
   - we should not wait for writing if we have nothing to send;
   - we should wait for writing if have something to send;
   - ignore the above if connecting: we know we are connected if we can
     write, so we wait for writing. *)
let waiter connection ((read, write, except) as acc) =
  match connection.state with
    | Connecting ->
        (* Wait for writing to know when we are connected. *)
        read,
        outputs_of_kind connection.kind @ write,
        file_descriptors_of_kind connection.kind @ except

    | Connected | Disconnecting ->
        (* Wait for writing if we have something to send, and for reading. *)
        let write =
          if sending connection then
            outputs_of_kind connection.kind @ write
          else
            write
        in
        inputs_of_kind connection.kind @ read,
        write,
        file_descriptors_of_kind connection.kind @ except

    | Disconnected _ ->
        (* Don't wait for anything, nothing can happen. *)
        acc

let waiter_of_listening_socket socket (read, write, except) =
  socket :: read, write, socket :: except

let waiter_of_set connections acc =
  List.fold_right waiter !connections acc

let waiter_custom
    ?(read = []) ?(write = []) ?(except = []) ()
    (acc_read, acc_write, acc_except) =
  (* We don't care about the order of file descriptors, so we can use
     List.rev_append to be more efficient. Also, the order is chosen so that
     the expected smallest list is at the left. *)
  List.rev_append read acc_read,
  List.rev_append write acc_write,
  List.rev_append except acc_except

let waiter_of_list list acc =
  List.fold_left
    (fun acc waiter -> waiter acc)
    acc
    list

let instanciate_waiter waiter =
  waiter ([], [], [])

(* Default timeout is negative, i.e. infinite. *)
let wait ?(timeout = -1.) waiter =
  let read, write, except = instanciate_waiter waiter in
  try
    match Unix.select read write except timeout with
      | [], [], [] ->
          false
      | _ ->
          true
  with
    | Unix.Unix_error _ ->
        (* May be EBADF. For sockets we want to interpret this as the socket
           having been closed. *)
        true

let wait' ?timeout waiter =
  let _x: bool = wait ?timeout waiter in ()

(******************************************************************************)
(*                               Low-Level Access                             *)
(******************************************************************************)

let custom
    ?timeout ?ping
    ?input ?output
    ?(remote_address = Unix.ADDR_UNIX "")
    data =

  (* Test equality between input and output. *)
  let ck_input_equals_output =
    match input, output with
      | Some input, Some output ->
          (* We use physical equality because file descriptors are normally
             obtained only once through the Unix module, and structural
             equality is not a good idea on an abstract type. *)
          input == output
      | _ ->
          (* Irrelevant. *)
          false
  in

  (* Test whether a file descriptor in an option is a socket. *)
  let option_is_a_socket = function
    | Some input ->
        begin
          try
            match (Unix.fstat input).Unix.st_kind with
              | Unix.S_SOCK ->
                  true
              | _ ->
                  false
          with
            | _ ->
                (* Maybe [fstat] is not implemented, or the file descriptor is
                   bad. *)
                false
        end
    | None ->
        (* Irrelevant. *)
        false
  in

  let ck_input_is_a_socket = option_is_a_socket input in
  let ck_output_is_a_socket =
    if ck_input_equals_output then
      ck_input_is_a_socket
    else
      option_is_a_socket output
  in

  (* Make the kind. *)
  let kind =
    {
      ck_input = input;
      ck_output = output;
      ck_input_is_a_socket;
      ck_output_is_a_socket;
      ck_input_equals_output;
      ck_remote_address = remote_address;
    }
  in

  (* Make the connection. *)
  make_connection ?timeout ?ping kind data Connecting
