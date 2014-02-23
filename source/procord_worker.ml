(******************************************************************************)
(*                                  Redirections                              *)
(******************************************************************************)

(* Store the current connection, if any. *)
let current_connection = ref None

(* Return the current connection, if any. *)
let get_connection () =
  !current_connection

(******************************************************************************)

let redirect_formatter formatter destination =
  (* Retrieve the current printing functions of the formatter,
     for the case where we try to redirect a formatter to itself. *)
  let old_print, old_flush =
    Format.pp_get_formatter_output_functions formatter ()
  in

  (* New printing function.
     It is kind of a dynamic call: the actual destination is resolved each
     time something is printed. *)
  let new_print string offset length =
    match get_connection () with
      | None ->
          (* We are the main program. *)
          let new_formatter =
            Procord_protocol.formatter_of_destination destination
          in
          if formatter == new_formatter then
            (* We are trying to print to ourself. *)
            old_print string offset length
          else
            (* Printing to another formatter. *)
            let new_print, _ =
              Format.pp_get_formatter_output_functions new_formatter ()
            in
            new_print string offset length

      | Some connection ->
          (* We are a connected worker. *)
          let message = String.sub string offset length in
          Procord_protocol.send_print connection destination message
  in

  (* New flushing function. *)
  let new_flush () =
    match get_connection () with
      | None ->
          (* We are the main program. *)
          let new_formatter =
            Procord_protocol.formatter_of_destination destination
          in
          if formatter == new_formatter then
            (* We are trying to print to ourself. *)
            old_flush ()
          else
            (* Printing to another formatter. *)
            let _, new_flush =
              Format.pp_get_formatter_output_functions new_formatter ()
            in
            new_flush ()

      | Some connection ->
          (* We are a connected worker. *)
          Procord_protocol.send_flush connection destination;

          (* We need to actually send the data.
             This may not send everything, so this is not perfect. *)
          Procord_connection.update connection
  in

  (* Redirect. *)
  Format.pp_set_formatter_output_functions
    formatter
    new_print
    new_flush

let redirect_standard_formatters () =
  redirect_formatter Format.std_formatter Procord_protocol.D_stdout;
  redirect_formatter Format.err_formatter Procord_protocol.D_stderr

(******************************************************************************)
(*                                   Task Type                                *)
(******************************************************************************)

(* Hide existential types in a closure. *)
type task =
  {
    name: string;
    run: unit Procord_connection.t -> unit;
    write_exception: exn -> string;
  }

(******************************************************************************)
(*                                    Helpers                                 *)
(******************************************************************************)

(* Wait until everything has been sent, and close a connection. *)
let send_and_disconnect connection =
  Procord_connection.close_nicely connection;
  while Procord_connection.alive connection do
    (* TODO: passive waiting. *)
    Procord_connection.update connection
  done

(******************************************************************************)
(*                                   Run a Task                               *)
(******************************************************************************)

(* Run a task on a given connection. *)
let run_task worker_task connection =
  (* Set the current connection. *)
  current_connection := Some connection;

  (* Receive the input. *)
  let serialized_input = Procord_protocol.blocking_receive_value connection in

  (* Deserialize the input. *)
  let input = Procord_task.read_input worker_task serialized_input in

  (* Perform the task. *)
  let output = Procord_task.run worker_task input in

  (* Serialize the output. *)
  let serialized_output = Procord_task.write_output worker_task output in

  (* Send the output. *)
  Procord_protocol.send_value connection serialized_output

let task worker_task =
  {
    name = Procord_task.worker_task_name worker_task;
    run = run_task worker_task;
    write_exception = Procord_task.write_exception worker_task;
  }

let run_custom ?(input = Unix.stdin) ?(output = Unix.stdout) tasks =
  (* Create the connection. Note that [Procord_connection] cannot fail. *)
  let connection =
    Procord_connection.custom
      ~input
      ~output
      ()
  in

  try
    (* Receive the name of the task we shall execute. *)
    let requested_task_name =
      Procord_protocol.blocking_receive_task_name connection
    in

    (* Find the task with the requested name. *)
    let task =
      try
        List.find
          (fun task -> task.name = requested_task_name)
          tasks
      with Not_found ->
        Procord_protocol.error Procord_protocol.E_task_not_supported
    in

    try
      (* Run the task. *)
      task.run connection;

      (* Close the connection. *)
      send_and_disconnect connection;
    with
      | Procord_protocol.Error _ as exn ->
          (* The error will be caught below, and the connection will be
             closed. *)
          raise exn

      | exn ->
          begin
            try
              (* If the user provided with a serializing function for this
                 exception, send it as a known exception. *)
              let serialized_exn = task.write_exception exn in
              Procord_protocol.send_exception connection serialized_exn;
            with _ ->
              (* We cannot serialize the exception. We send it as an unknown
                 exception. *)
              let exn_as_string = Printexc.to_string exn in
              Procord_protocol.send_unknown_exception connection exn_as_string
          end;

          (* Close the connection. *)
          send_and_disconnect connection
  with
    | Procord_protocol.Error error ->
        Procord_protocol.send_error connection error;

        (* Close the connection. *)
        send_and_disconnect connection

(******************************************************************************)

(* Run a server.
   Do not use [Unix.establish_server] because there is no way to get the
   remote address, and it tries to use [Unix.fork] even on Windows. Also
   there is no way to set the socket options such as [SO_REUSEADDR]. *)
let run_listen
    ?(continue = fun () -> true)
    ?(accept = fun _ -> true)
    ?max_simultaneous_tasks
    ?(reuse_address = false)
    ?(dont_fork = false)
    ~hostname
    ~port
    tasks =

  (* Make the address from [hostname] and [port]. *)
  let address =
    Unix.ADDR_INET (Procord_connection.make_address hostname, port)
  in

  (* Create the socket. *)
  let socket =
    Unix.socket (Unix.domain_of_sockaddr address) Unix.SOCK_STREAM 0
  in

  (* Set socket options. *)
  if reuse_address then
    Unix.setsockopt socket Unix.SO_REUSEADDR true;

  (* Start listening. *)
  Unix.bind socket address;
  let max_pending_requests =
    match max_simultaneous_tasks with
      | None -> 10
      | Some count -> count
  in
  Unix.listen socket max_pending_requests;

  (* Allow Ctrl+C to stop the server properly. *)
  Sys.catch_break true;

  (* try [accept tasks] finally [close the socket] *)
  let children_count = ref 0 in
  try
    while continue () do
      let client_socket, remote_address = Unix.accept socket in
      if accept remote_address then
        begin
          (* Handle the new connection. *)
          (* Close on exec ensures that when we fork, the parent does not
             keep the file descriptor open. *)
          Unix.set_close_on_exec client_socket;
          incr children_count;

          (* Fork if possible and execute the task. *)
          match
            if dont_fork then
              `cannot_fork
            else
              try
                let pid = Unix.fork () in
                if pid = 0 then
                  (* We are the child process. *)
                  `child
                else
                  begin
                    (* We are the parent process. *)
                    incr children_count;
                    `parent
                  end
              with
                | _ ->
                    (* Cannot fork, just run in the current process. *)
                    `cannot_fork
          with
            | `child ->
                (* The child should run the task and exit. *)
                run_custom ~input: client_socket ~output: client_socket tasks;
                exit 0
            | `parent ->
                (* The parent will continue accepting connections. *)
                ()
            | `cannot_fork ->
                (* If we cannot fork we just run the task in the current
                   process. *)
                run_custom ~input: client_socket ~output: client_socket tasks
        end
      else
        begin
          (* Refuse the connection by closing it. *)
          try Unix.close client_socket with _ -> ()
        end;

      (* Reap our zombie children. *)
      begin
        let continue = ref true in
        while !continue do
          try
            let child_pid, _ =
              Unix.waitpid [ Unix.WNOHANG ] (-1)
            in
            if child_pid = 0 then
              continue := false
            else
              decr children_count
          with _ ->
            (* Unix.waitpid not implemented on Windows. *)
            continue := false
        done
      end;

      (* Stop accepting tasks until one of the current ones is finished,
         if we have too many of them already. *)
      match max_simultaneous_tasks with
        | Some count when !children_count > 0 && !children_count >= count ->
            begin
              try
                ignore (Unix.wait ())
              with _ ->
                (* Unix.wait not implemented on Windows. *)
                ()
            end;
            decr children_count
        | _ ->
            ()
    done;

    (* Finished. *)
    Unix.close socket
  with
    | Sys.Break ->
        Unix.close socket
    | exn ->
        Unix.close socket;
        raise exn

(******************************************************************************)

let input_file = ref ""
let output_file = ref ""
let hostname = ref ""
let port = ref 1111
let max_simultaneous_tasks = ref None
let reuse_address = ref false
let dont_fork = ref false

let get_input_file () = !input_file
let get_output_file () = !output_file
let get_hostname () = !hostname
let get_port () = !port
let get_max_simultaneous_tasks () = !max_simultaneous_tasks
let get_reuse_address () = !reuse_address
let get_dont_fork () = !dont_fork

let set_input_file value = input_file := value
let set_output_file value = output_file := value
let set_hostname value = hostname := value
let set_port value = port := value
let set_max_simultaneous_tasks value = max_simultaneous_tasks := value
let set_reuse_address value = reuse_address := value
let set_dont_fork value = dont_fork := value

let run
    ?(spec = [])
    ?(usage = "Usage: " ^ Filename.basename Sys.executable_name ^ " [options]")
    ?(anon = fun arg -> raise (Arg.Bad ("Invalid argument: " ^ arg)))
    tasks =

  (* Redirect [Format.std_formatter] and [Format.err_formatter]. *)
  redirect_standard_formatters ();

  (* Parameters. *)
  let mode = ref `procord_none in

  (* The Procord-specific command-line options. *)
  let procord_spec =
    [
      "--procord-worker",
      Arg.Unit (fun () -> mode := `procord_worker),
      " Execute one task, communicating over stdin and stdout, and exit.";
      "--procord-input-file",
      Arg.String set_input_file,
      "<file> Read inputs from a file instead of stdin.";
      "--procord-output-file",
      Arg.String set_output_file,
      "<file> Read outputs from a file instead of stdout.";
      "--procord-server",
      Arg.Unit (fun () -> mode := `procord_server),
      " Listen for TCP connections and execute one task per connection.";
      "--procord-hostname",
      Arg.String set_hostname,
      "<hostname> The IPv4/IPv6/DNS address to listen to (default 0.0.0.0, \
       i.e. any IPv4 address);";
      "--procord-port",
      Arg.Int set_port,
      "<port> The port to listen to (default 1111);";
      "--procord-max-simultaneous-tasks",
      Arg.Int (fun i -> max_simultaneous_tasks := Some i),
      "<count> Maximum number of tasks that may be executed at the same time.";
      "--procord-reuse-address",
      Arg.Set reuse_address,
      " Set the SO_REUSEADDR option to the listening socket to prevent \
       Address Already in Use errors.";
      "--procord-dont-fork",
      Arg.Set dont_fork,
      " Do not fork, just run the task in the current process.";
    ]
  in

  (* Parse command-line. *)
  Arg.parse (Arg.align (spec @ procord_spec)) anon usage;

  (* Run the selected mode. *)
  match !mode with
    | `procord_none ->
        ()

    | `procord_worker ->
        (* Handle --procord-input-file. *)
        let input =
          if !input_file = "" then
            Unix.stdin
          else
            Unix.handle_unix_error
              (Unix.openfile
                 !input_file
                 [ Unix.O_RDONLY; Unix.O_NONBLOCK ])
                 0o640
        in
        (* Handle --procord-output-file. *)
        let output =
          if !output_file = "" then
            Unix.stdout
          else
            Unix.handle_unix_error
              (Unix.openfile
                 !input_file
                 [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC; Unix.O_NONBLOCK ])
                 0o640
        in
        (* Run. *)
        run_custom ~input ~output tasks;
        (* Exit. *)
        exit 0

    | `procord_server ->
        (* Run. *)
        run_listen
          ?max_simultaneous_tasks: !max_simultaneous_tasks
          ~reuse_address: !reuse_address
          ~dont_fork: !dont_fork
          ~hostname: (if !hostname = "" then "0.0.0.0" else !hostname)
          ~port: !port
          tasks;
        (* Exit. *)
        exit 0
