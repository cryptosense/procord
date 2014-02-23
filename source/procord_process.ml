(******************************************************************************)
(*                              Errors and Status                             *)
(******************************************************************************)

(** Execution error descriptions. *)
type execution_error =
  | Worker_unknown_exception of string
      (** A worker raised an exception which was not handled by
          [write_exception]. The [string] is obtained using [Printexc]. *)
  | Worker_killed
      (** You killed the worker yourself. *)
  | Worker_disconnected of exn
      (** An exception was raised while trying to connect to, send to,
          or receive from a worker; or the worker was killed, crashed or
          exited without returning any output; or there was an error while
          serializing an input value or deserializing an output value. *)
  | No_worker_available of string
      (** No worker is available to perform the required task, or the
          selected worker cannot perform the required task.
          The string is the task name. *)

exception Execution_error of execution_error
  (** An unexpected error occurred when delegating a task. *)

let error_message error =
  match error with
    | Worker_unknown_exception exn_as_string ->
        Printf.sprintf "Worker unknown exception: %S" exn_as_string
    | Worker_killed ->
        "Worker killed"
    | Worker_disconnected exn ->
        Printf.sprintf "Worker disconnected: %S" (Printexc.to_string exn)
    | No_worker_available task_name ->
        Printf.sprintf "No worker available: %S" task_name

let () =
  Printexc.register_printer
    begin function
      | Execution_error error ->
          Some (error_message error)
      | _ ->
          None
    end

(** Status of a task given to a worker. *)
type 'a status =
  | Working
      (** The task is not finished yet. *)
  | Success of 'a
      (** The task was performed successfully, ['a] is the result. *)
  | Exception of exn
      (** The task resulted in an exception that [write_exception]
          could handle. *)
  | Error of execution_error
      (** Failed to execute the task. *)

(******************************************************************************)
(*                                  Processes                                 *)
(******************************************************************************)

(* A process is basically a killable connection supposed to speak the Procord
   protocol (Protocord?). *)
type 'a process =
  {
    update: unit -> 'a status;
    kill: unit -> unit;
    waiter: Procord_connection.waiter;
    mutable status: 'a status;
  }

let waiter process =
  process.waiter

let update process =
  match process.status with
    | Working ->
        process.status <- process.update ()
    | Success _ | Exception _ | Error _ ->
        ()

let status process =
  process.status

let rec run process =
  match status process with
    | Working ->
        (* Wait and try again. *)
        Procord_connection.wait' process.waiter;
        update process;
        run process

    | Success value ->
        value

    | Exception exn ->
        raise exn

    | Error error ->
        raise (Execution_error error)

let kill process =
  process.kill ();
  process.status <- Error Worker_killed

(******************************************************************************)
(*                         Delegate (Shared Functions)                        *)
(******************************************************************************)

(* The [update] function of a delegated task. It does not depend on the
   method of delegation (create_process or socket). *)
let update_delegated task connection input =
  (* Internal state.
     We put the input here so that it is not a free variable of [update],
     and so that it does not stay in the closure of [update] forever. *)
  let state = ref (`just_started input) in

  (* Auxiliary function for [update_send_and_receive] below.
     It sends the input. It assumes [!state = `just_started]. *)
  let update_just_started input =
    (* Send the task name. *)
    let task_name = Procord_task.delegated_task_name task in
    Procord_protocol.send_task_name connection task_name;
    (* Send the input value. *)
    let serialized_input = Procord_task.write_input task input in
    Procord_protocol.send_value connection serialized_input;
    (* Update the state. *)
    state := `waiting_for_output
  in

  let rec update_waiting_for_output () =
    match Procord_protocol.receive connection with
      | Procord_protocol.M_none ->
          (* Still waiting. *)
          Working

      | Procord_protocol.M_value serialized_output ->
          (* Deserialize the output. *)
          let output =
            Procord_task.read_output task serialized_output
          in
          Success output

      | Procord_protocol.M_task_name _ ->
          (* Unexpected message: the worker is not supposed to give
             us orders. *)
          Procord_protocol.error Procord_protocol.E_unexpected_message

      | Procord_protocol.M_exception serialized_exn ->
          begin
            match Procord_task.read_exception task with
              | None ->
                  (* No deserializing function. *)
                  Error (Worker_unknown_exception serialized_exn)
              | Some read_exception ->
                  let exn = read_exception serialized_exn in
                  Exception exn
          end

      | Procord_protocol.M_unknown_exception exn_as_string ->
          Error (Worker_unknown_exception exn_as_string)

      | Procord_protocol.M_error error ->
          begin
            match error with
              | Procord_protocol.E_task_not_supported ->
                  Error
                    (No_worker_available
                       (Procord_task.delegated_task_name task))

              | Procord_protocol.E_disconnected ->
                  (* Unexpected message: the worker cannot send us
                     E_disconnected if he is disconnected. *)
                  Procord_protocol.error Procord_protocol.E_unexpected_message;

              | Procord_protocol.E_unexpected_message
              | Procord_protocol.E_ill_formed_message
              | Procord_protocol.E_message_too_long as error ->
                  Procord_protocol.error error

              | Procord_protocol.E_invalid_print_destination ->
                  (* The worker should not receive print commands.
                     So it should not send this kind of error. *)
                  Procord_protocol.error error
          end

      | Procord_protocol.M_print (destination, message) ->
          let formatter =
            Procord_protocol.formatter_of_destination destination
          in
          begin
            match formatter with
              | None ->
                  ()
              | Some formatter ->
                  Format.pp_print_string formatter message
          end;
          (* Continue reading messages, there might be more in the queue. *)
          update_waiting_for_output ()

      | Procord_protocol.M_flush destination ->
          let formatter =
            Procord_protocol.formatter_of_destination destination
          in
          begin
            match formatter with
              | None ->
                  ()
              | Some formatter ->
                  Format.pp_print_flush formatter ()
          end;
          (* Continue reading messages, there might be more in the queue. *)
          update_waiting_for_output ()
  in

  (* Auxiliary function for [update] below.
     It sends and receive what needs to be sent and received. *)
  let update_send_and_receive () =
    match !state with
      | `just_started input ->
          update_just_started input;
          Working

      | `waiting_for_output ->
          update_waiting_for_output ()
  in

  (* If we received everything we need, close the connection. *)
  let disconnect_if_finished status =
    match status with
      | Working ->
          ()
      | Success _
      | Exception _
      | Error _ ->
          Procord_connection.close connection
  in

  (* The actual update function. *)
  let update () =
    try
      (* Update the connection. *)
      Procord_connection.update connection;

      (* Check for disconnection. *)
      match Procord_connection.state connection with
        | Procord_connection.Connecting
        | Procord_connection.Connected
        | Procord_connection.Disconnecting ->
            (* Send and receive stuff. *)
            let status = update_send_and_receive () in
            disconnect_if_finished status;
            status

        | Procord_connection.Disconnected (Some (unix_error, fname, sarg)) ->
            (* There may still be data to receive in the buffer. *)
            if Procord_connection.receive_buffer_empty connection then
              (* Nothing will ever be received on this connection anymore. *)
              let error =
                Worker_disconnected (Unix.Unix_error (unix_error, fname, sarg))
              in
              Error error
            else
              (* There is some data left. *)
              update_send_and_receive ()

        | Procord_connection.Disconnected None ->
            Error Worker_killed
    with exn ->
      Procord_connection.close connection;
      Error (Worker_disconnected exn)
  in

  (* Return the update function. *)
  update

(* Make a process which just failed to connect. *)
let make_failed_process exn =
  let status = Error (Worker_disconnected exn) in
  {
    update = (fun () -> status);
    kill = (fun () -> ());
    waiter = Procord_connection.waiter_of_list [];
    status;
  }

(* Make a process which is connecting or just connected. *)
let make_connecting_process task kill connection input =
  (* Make the update function and call it once to send the request. *)
  let update = update_delegated task connection input in
  let status = update () in

  (* Make the process record and return it. *)
  {
    update;
    kill;
    waiter = Procord_connection.waiter connection;
    status;
  }

(******************************************************************************)
(*                       Delegate (Using create_process)                      *)
(******************************************************************************)

let delegate_task_create_process ?stderr program arguments task input =
  try
    (* Prepare pipes for the worker stdin and stdout. *)
    let in_exit, in_entrance = Unix.pipe () in
    let out_exit, out_entrance = Unix.pipe () in
    let err_entrance =
      match stderr with
        | None ->
            let _err_exit, err_entrance = Unix.pipe () in
            err_entrance
        | Some stderr ->
            stderr
    in

    (* Spawn the worker. *)
    let pid =
      Unix.create_process program arguments in_exit out_entrance err_entrance
    in

    (* Make the connection. *)
    let connection =
      Procord_connection.custom
        ~input: out_exit
        ~output: in_entrance
        ()
    in

    (* Make the kill function. *)
    let kill () = Unix.kill pid 9 in

    (* Make the process. *)
    make_connecting_process task kill connection input
  with exn ->
    make_failed_process exn

(******************************************************************************)
(*                           Delegate (Using sockets)                         *)
(******************************************************************************)

let delegate_task_socket remote_host port task input =
  try
    (* Make the connection. *)
    let connection = Procord_connection.connect remote_host port () in

    (* Make the kill function.
       Workers use [Procord_protocol.blocking_receive] which raises an
       error if disconnected. So if the worker tries to receive something,
       it will exit. *)
    let kill () = Procord_connection.close connection in

    (* Make the process. *)
    make_connecting_process task kill connection input
  with exn ->
    make_failed_process exn

(******************************************************************************)
(*                             Delegate (Dispatch)                            *)
(******************************************************************************)

let delegate task input =
  (* Get the --procord-hostname argument value. *)
  let hostname = Procord_worker.get_hostname () in

  (* Depending on the value, delegate to self or to a remote worker. *)
  if hostname = "" then
    (* Delegate to self. *)
    delegate_task_create_process
      Sys.executable_name
      [| Sys.executable_name; "--procord-worker" |]
      task
      ~stderr: Unix.stderr
      input

  else
    (* Delegate to remote. *)
    delegate_task_socket
      hostname
      (Procord_worker.get_port ())
      task
      input
