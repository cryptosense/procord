(** Communication protocol between workers and main programs. *)

(** {2 Errors} *)

(** Errors from workers and protocol errors. *)
type error =
  | E_task_not_supported
  | E_unexpected_message
  | E_ill_formed_message
  | E_message_too_long
  | E_disconnected
  | E_invalid_print_destination

exception Error of error
  (** An error has occurred. *)

val error: error -> 'a
  (** Raise an error. *)

val error_message: error -> string
  (** Return a string explaining an error in English. *)

(** {2 Messages} *)

(** Possible destinations when sending messages to print.

    Possible values are:
    - [D_stdout]: print to [Format.std_formatter];
    - [D_stderr]: print to [Format.err_formatter]. *)
type print_destination =
  | D_stdout
  | D_stderr

(** Messages that can be received. *)
type message =
  | M_none
  | M_value of string (** Serialized input or output. *)
  | M_task_name of string
  | M_exception of string (** Serialized exception. *)
  | M_unknown_exception of string (** Exception as a string using [Printexc]. *)
  | M_error of error
  | M_print of print_destination * string (** Destination, message to print. *)
  | M_flush of print_destination

val set_max_message_size: int -> unit
  (** Set the maximum size of packets.

      If you know that your serialized values, exceptions and task names
      are never longer than [n] bytes, consider setting the maximum message
      size to [n]. Otherwise someone can send a ridiculous size, then the
      same ridiculous amount of data, and your process will buffer it all,
      possibly running out of memory.

      By default the maximum size is [max_int]. *)

(** {2 Non-Blocking Functions} *)

val send: 'a Procord_connection.t -> message -> unit
  (** Send a message. *)

val send_value: 'a Procord_connection.t -> string -> unit
  (** Send a value (input or output). *)

val send_task_name: 'a Procord_connection.t -> string -> unit
  (** Send the name of the task to execute. *)

val send_exception: 'a Procord_connection.t -> string -> unit
  (** Send an exception message. *)

val send_unknown_exception: 'a Procord_connection.t -> string -> unit
  (** Send an unknown exception message. *)

val send_error: 'a Procord_connection.t -> error -> unit
  (** Send an error message. *)

val send_print: 'a Procord_connection.t -> print_destination -> string -> unit
  (** Send a message to be printed using [Format.fprintf].

      The worker can use this to make the main program call
      [Format.fprintf]. It is unspecified whether the main program can
      send messages like this to the worker. *)

val send_flush: 'a Procord_connection.t -> print_destination -> unit
  (** Send a flush request.

      The worker can use this to make the main program call
      [Format.pp_print_flush]. It is unspecified whether the main
      program can send messages like this to the worker. *)

val receive: 'a Procord_connection.t -> message
(** Try to receive a message from a connection.

    May raise [Error E_ill_formed_message]. *)

(** {2 Blocking Functions} *)

val blocking_receive: 'a Procord_connection.t -> message
  (** Receive a message.

      May raise [Error]. *)

val blocking_receive_task_name: 'a Procord_connection.t -> string
  (** Receive a task name.

      May raise [Error]. *)

val blocking_receive_value: 'a Procord_connection.t -> string
  (** Receive a serialized value.

      May raise [Error]. *)

(** {2 Formatters and Destinations} *)

val formatter_of_destination: print_destination -> Format.formatter
  (** Return the formatter corresponding to a destination. *)

(** {2 Protocol Description} *)

(** A sequence of messages is sent on the connection. (See type [message].)
    Nothing else can be sent, and [M_none] cannot really be sent either.

    Each message is of the form:

    SIZE KIND BODY

    The SIZE is a sequence of ASCII digits (['0'] to ['9']).
    The KIND is a single character which is not a digit.
    The BODY is a string of SIZE bytes.

    Each message has a specific KIND and a specific way to handle BODY:

    - [M_value]:
      KIND ['V'];
      BODY is to be deserialized using the user function [read_input]
        (for the worker) or [read_output] (for the main program).

    - [M_task_name]:
      KIND ['T'];
      BODY is the task name.

    - [M_exception]:
      KIND ['X'];
      BODY is to be deserialized using the user function [read_exception].

    - [M_unknown_exception]:
      KIND ['U'];
      BODY is the exception as a string using [Printexc].

    - [M_error]:
      KIND ['E'];
      BODY is one of those (quotes not included):
        ["0"] - [E_task_not_supported];
        ["1"] - [E_unexpected_message];
        ["2"] - [E_ill_formed_message];
        ["3"] - [E_message_too_long];
        ["4"] - [E_disconnected];
        ["5"] - [E_invalid_print_destination].

    - [M_print]:
      KIND ['P'];
      BODY starts with the destination, which is one of those
      (quotes not included):
        ["O"] - [`stdout];
        ["E"] - [`stderr].
      BODY continues with the message to be printed.

    - [M_flush]:
      KIND ['F'];
      BODY is one of those (quotes not included):
        ["O"] - [`stdout];
        ["E"] - [`stderr].

    Examples:

    - ["1E2"] has SIZE 1, KIND ['E'] ([M_error]),
      and BODY ["2"] ([E_disconnected]).

    - ["5Thelloworld"] has SIZE 5, KIND ['T'] ([M_task_name]),
      and BODY ["hello"].
      Remainder ["world"] is not part of the message.

    - ["8POmessage"] has SIZE 8, KIND ['P'] ([M_print]),
      and BODY ["Omessage"].
      It is a request to print ["message"] on [Format.std_formatter]. *)
