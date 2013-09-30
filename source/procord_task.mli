(** Procord task description. *)

(** To use Procord, you must first describe a task.

    A task is basically a function to execute, plus some serializing
    functions for inputs, outputs and exceptions. *)

(** Default serializing functions use the [Marshal] module of the standard
    library. It should only be used for quick prototyping or if you really
    know what you are doing. *)

(** {2 Tasks, From the Worker Point of View} *)

type ('a, 'b) worker_task
  (** Worker tasks contain the information needed by the worker process. *)

val make_worker_task:
  ?read_input: (string -> 'a) ->
  ?write_output: ('b -> string) ->
  ?write_exception: (exn -> string) ->
  string -> ('a -> 'b) -> ('a, 'b) worker_task
  (** Make a [worker_task].

      The worker needs the following information.

      @param read_input Deserialization function for input values.
        This should be compatible with the [write_input] counterpart given
        to [make_delegated_task].

      @param write_output Serialization function for output values.
        This should be compatible with the [read_output] counterpart given
        to [make_delegated_task].

      @param write_exception Serialization function for exceptions.
        This should be compatible with the [read_exception] counterpart given
        to [make_delegated_task]. Marshaling is not used: if unspecified,
        the main program will receive a [Worker_unknown_exception] error.

      The [string] argument is the name of the task. It should be the
      same as the one given to [make_delegated_task]. A given worker
      cannot run two tasks with the same name.

      The last argument is the function that the tasks runs.

      If [read_input] or [write_output] raises an exception, it will be
      passed to [write_exception] for transmission to the main program.

      If [write_exception] raises an exception, it will be serialized as a
      [Worker_unknown_exception] using [Printexc]. *)

val read_input: ('a, 'b) worker_task -> string -> 'a
  (** Get the input deserialization function of a worker task. *)

val write_output: ('a, 'b) worker_task -> 'b -> string
  (** Get the output serialization function of a worker task. *)

val write_exception: ('a, 'b) worker_task -> exn -> string
  (** Get the exception serialization function of a worker task. *)

val run: ('a, 'b) worker_task -> 'a -> 'b
  (** Get the function that a worker task runs. *)

val worker_task_name: ('a, 'b) worker_task -> string
  (** Get the name of a worker task. *)

(** {2 Tasks, From the Main Program Point of View} *)

type ('a, 'b) delegated_task
  (** Delegated tasks contain the information needed by the main program.

      Type parameter ['a] is the type of input values, and type parameter
      ['b] is the type of output values. *)

val make_delegated_task:
  ?write_input: ('a -> string) ->
  ?read_output: (string -> 'b) ->
  ?read_exception: (string -> exn) ->
  string -> ('a, 'b) delegated_task
  (** Make a [delegated_task].

      The worker needs the following information.

      @param write_input Serialization function for input values.
        This should be compatible with the [read_input] counterpart given
        to [make_worker_task].

      @param read_output Deserialization function for output values.
        This should be compatible with the [write_output] counterpart given
        to [make_worker_task].

      @param read_exception Deserialization function for exceptions.
        This should be compatible with the [write_exception] counterpart given
        to [make_worker_task]. If unspecified, received exceptions will
        be handled as [Worker_unknown_exception] errors.

      The [string] argument is the name of the task. It should be the same as
      the one given to [make_worker_task].

      If [write_input] or [read_output] raises an exception, it will result
      in a [Worker_connection_failed] error. If [read_exception] is unspecified
      or raises an exception, it will result in a [Worker_unknown_exception]
      error. *)

val write_input: ('a, 'b) delegated_task -> 'a -> string
  (** Get the input serialization function of a delegated task. *)

val read_output: ('a, 'b) delegated_task -> string -> 'b
  (** Get the output deserialization function of a delegated task. *)

val read_exception: ('a, 'b) delegated_task -> (string -> exn) option
  (** Get the exception deserialization function of a delegated task, if any. *)

val delegated_task_name: ('a, 'b) delegated_task -> string
  (** Get the name of a delegated task. *)

(** {2 Tasks, From Both Points of View} *)

val make:
  ?read_input: (string -> 'a) ->
  ?write_input: ('a -> string) ->
  ?read_output: (string -> 'b) ->
  ?write_output: ('b -> string) ->
  ?read_exception: (string -> exn) ->
  ?write_exception: (exn -> string) ->
  string -> ('a -> 'b) -> ('a, 'b) worker_task * ('a, 'b) delegated_task
  (** Make a [worker_task] and a [delegated_task].

      Using this function ensures the task name is the same in the
      [worker_task] and in the [delegated_task]. *)
