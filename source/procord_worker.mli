(** Main function to run a Procord worker. *)

(** Workers are external programs which can execute some tasks.

    The easiest way to build a worker is just to use [run]. If you prefer
    to handle command-line options yourself, use other [run_*] functions. *)

(** Same as [Procord_task.worker_task], but allowing heterogenous lists of
    tasks. *)
type task

val task: ('a, 'b) Procord_task.worker_task -> task
  (** Embed a [Procord_task.worker_task] for use with {!run}. *)

(** {2 Generic Workers} *)

val run:
  ?spec: (Arg.key * Arg.spec * Arg.doc) list ->
  ?usage: Arg.usage_msg ->
  ?anon: Arg.anon_fun ->
  task list -> unit
  (** Parse command-line options and run the appropriate worker, if any.

      This function parses command line options as follows:
      - [--procord-worker]: execute one task, communicating over [stdin]
        and [stdout], and exit;
      - [--procord-input-file <file>]: option for [--procord-worker] which tells
        the worker to read inputs from [<file>] instead of [stdin];
      - [--procord-output-file <file>]: option for [--procord-worker] which
        tells the worker to write outputs from [<file>] instead of [stdout];
      - [--procord-server]: listen for TCP connections and execute one task
        per connection;
      - [--procord-hostname <hostname>]: option for [--procord-server] which
        specifies the IPv4/IPv6/DNS address to listen to (default [0.0.0.0]);
      - [--procord-port <port>]: option for [--procord-server] which
        specifies the port to listen to (default [1111]);
      - [--procord-max-simultaneous-tasks <count>]:
        option for [--procord-server] which specifies the maximum number of
        tasks that may be executed at the same time;
      - [--procord-reuse-address]:
        option for [--procord-server] which tells the server to set the
        [SO_REUSEADDR] option on the listening socket;
      - [--procord-dont-fork]:
        option for [--procord-server] which removes the call to
        [Unix.fork], imlying that only one task can be executed at the same
        time and that crashing a task crashes the server as well.

      If neither [--procord-worker] nor [--procord-server] are given, the
      function returns immediately. Else, the function never returns. Thus
      you may call [run] before your main program starts to allow your
      program to act both as the main program and as a worker.

      The worker will be able to run any of the tasks given in the last
      argument.

      You should not call [Arg.parse] yourself (nor [Arg.align]).
      Instead, pass your specifications using [spec], [usage] and [anon].
      If you need more complex command-line parsing, use the
      other [run_*] functions. *)

val get_input_file: unit -> string
  (** Get the [--procord-input-file] argument.
      Default value is [""]. *)

val set_input_file: string -> unit
  (** Set the [--procord-input-file] argument. *)

val get_output_file: unit -> string
  (** Get the [--procord-output-file] argument.
      Default value is [""]. *)

val set_output_file: string -> unit
  (** Set the [--procord-output-file] argument. *)

val get_hostname: unit -> string
  (** Get the [--procord-hostname] argument.
      Default value is [""]. *)

val set_hostname: string -> unit
  (** Set the [--procord-hostname] argument. *)

val get_port: unit -> int
  (** Get the [--procord-port] argument.
      Default value is [1111]. *)

val set_port: int -> unit
  (** Set the [--procord-port] argument. *)

val get_max_simultaneous_tasks: unit -> int option
  (** Get the [--procord-max-simultaneous-tasks] argument.
      Default value is [None] (infinite). *)

val set_max_simultaneous_tasks: int option -> unit
  (** Set the [--procord-max-simultaneous-tasks] argument. *)

val get_reuse_address: unit -> bool
  (** Get the [--procord-reuse-address] argument.
      Default value is [false]. *)

val set_reuse_address: bool -> unit
  (** Set the [--procord-reuse-address] argument. *)

val get_dont_fork: unit -> bool
  (** Get the [--procord-dont-fork] argument.
      Default value is [false]. *)

val set_dont_fork: bool -> unit
  (** Set the [--procord-dont-fork] argument. *)

(** {2 Custom Workers} *)

val run_custom:
  ?input: Unix.file_descr ->
  ?output: Unix.file_descr ->
  task list -> unit
  (** Run a worker which will accomplish one task amongst several on given
      file descriptors.

      @param input File descriptor for reading. Default [Unix.stdin].
      @param output File descriptor for writing. Default [Unix.stdout].

      The last parameter is the list of tasks that the worker can handle. *)

val run_listen:
  ?continue: (unit -> bool) ->
  ?accept: (Unix.sockaddr -> bool) ->
  ?max_simultaneous_tasks: int ->
  ?reuse_address: bool ->
  ?dont_fork: bool ->
  hostname: string ->
  port: int ->
  task list -> unit
  (** Run a worker which will listen for network connections.

      @param continue Function called before each call to
        [Unix.accept]. If it returns [false], the worker stops
        accepting new connections, and will exit after all tasks are
        executed. If unspecified, [run_listen] never returns.

      @param accept Function called after each call to [Unix.accept].
        It is given the remote address of the new connection.
        If it returns [false], the connection is closed immediately.

      @param max_simultaneous_tasks The maximum number of tasks that
        the server may execute at the same time. On Windows, only one
        task can be executed at the same time (no [fork]).

      @param reuse_address If [true], set [SO_REUSEADDR], preventing the
        "Address already in use" error. This is useful for debugging but
        could potentially be abused by malware.

      @param dont_fork If [true], do not fork to run the tasks.

      @param hostname Specifies the interface to listen to. Examples:
      - ["localhost"]: only accept local IPv4 connections;
      - ["::1"]: only accept local IPv6 connections;
      - ["0.0.0.0"]: accept all IPv4 connections;
      - ["::"]: accept all IPv6 connections.

      @param port Specifies the port to listen to.

      Raise [Unix_error] if the server cannot be established. *)

(** {2 Redirecting Standard Outputs} *)

(** Workers should not print on their own [stdout] as, in local mode,
    workers communicate with the main program using [stdout]. In remote
    mode, workers communicate with the main program using sockets, and
    writing on [stdout] is not an issue. However, this will print on the
    standard output of the worker, not of the main program.

    Using the functions below allows you to continue using the
    [Format] module normally. Everything you write will actually be
    printed by the main program. This allows you to write your tasks
    as if they were running in the main program process.
    The functions below have no effect on the input/output functions
    of [Pervasives], [Unix], [Printf] and [Scanf]. *)

(** {3 Default Redirections} *)

val redirect_standard_formatters: unit -> unit
  (** Redirect [Format.std_formatter] and [Format.err_formatter] to the main
      program.

      Everything you write to [Format.std_formatter] (for example using
      [Format.printf]) will be sent to the main program, which will print
      it on its own [stdout].

      Similarly, everything you write to [Format.err_formatter] (for
      example using [Format.eprintf]) will be sent to the main program,
      which will print it on its own [stderr].

      This function is automatically called by {!run}, but not by
      other [run_*] functions.

      You may call this function from the main program, typically
      before calling a [run_*] function, or from a task. The
      redirection will continue if the main program becomes a
      worker. *)

(** {3 Custom Redirections} *)

val redirect_formatter:
  Format.formatter -> Procord_protocol.print_destination -> unit
  (** Redirect a formatter.

      Everything you write to the formatter given in argument will be
      redirected to the specified destination of the main program.

      You may call this function from the main program, typically
      before calling a [run_*] function, or from a task. The
      redirection will continue if the main program becomes a
      worker. *)

val make_redirected_formatter:
  Procord_protocol.print_destination -> Format.formatter
  (** Create a new formatter which is already redirected. *)
