(** Delegating tasks to other processes. *)

type 'a process
  (** The type of processes. *)

(** {2 Delegating Tasks} *)

val delegate: ('a, 'b) Procord_task.delegated_task -> 'a -> 'b process
  (** Delegate according to command-line options parsed by
      [Procord_worker.run].

      If [--procord-hostname] is empty, delegate using [Unix.create_process],
      to the executable [Sys.executable_name]. Else, delegate using a socket
      connection to a server worker (started with --procord-server) at
      the address specified by [--procord-hostname], port [--procord-port].

      Call [Procord_worker.run] at the beginning at your program if you plan
      to use this function. Otherwise, use one of the alternatives below. *)

val delegate_task_create_process:
  ?stderr: Unix.file_descr ->
  string -> string array ->
  ('a, 'b) Procord_task.delegated_task -> 'a -> 'b process
  (** Delegate a task, running it in another process on the current machine.
      The process is created using [Unix.create_process].

      Usage: [delegate_task_create_process ?stderr program arguments task input]

      The [program] is the executable file name. It can be the main
      program file name itself ([Sys.executable_name]), if it has a
      way to distinguish whether it is a worker, for instance from
      command-line [arguments].

      @param stderr If specified, the created process will have its standard
        error redirected to [stderr]. If unspecified, everything the created
        process writes on its standard error will be ignored.
        Example: [Unix.stderr] *)

val delegate_task_socket:
  string -> int ->
  ('a, 'b) Procord_task.delegated_task -> 'a -> 'b process
  (** Delegate a task, running it in another process on a remote machine.

      Usage: [delegate_task_socket hostname port task input]

      The task will be delegated to a worker running on remote machine
      [hostname], listening on [port].

      The [hostname] can be an IP address, an IPv6 address or a DNS address. *)

(** {2 Running Processes} *)

(** To run a process, either call [run_process] (which is blocking), or
    call [update] followed by [process_status] regularly. Wait using
    [process_waiter] between two updates. *)

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

val error_message: execution_error -> string
  (** Return a string explaining an error in English. *)

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

val waiter: 'a process -> Procord_connection.waiter
  (** Return a waiter which waits until something happens for a process. *)

val update: 'a process -> unit
  (** Call this regularly to update the [process_status]. *)

val status: 'a process -> 'a status
  (** Get the current status of a process. *)

val run: 'a process -> 'a
  (** Wait (blocking) until a process terminates.

      Return the process return value or, if it raised an exception,
      raise this exception.

      May also raise [Execution_error]. *)

val kill: 'a process -> unit
  (** Terminate a process immediately. *)
