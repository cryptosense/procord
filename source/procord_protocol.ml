(******************************************************************************)
(*                                    Errors                                  *)
(******************************************************************************)

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

let error error =
  raise (Error error)

let error_message error =
  match error with
    | E_task_not_supported ->
        "Task not supported"
    | E_unexpected_message ->
        "Unexpected message"
    | E_ill_formed_message ->
        "Ill formed message"
    | E_message_too_long ->
        "Message too long"
    | E_disconnected ->
        "Disconnected"
    | E_invalid_print_destination ->
        "Invalid print destination"

let () =
  Printexc.register_printer
    begin function
      | Error error ->
          Some (error_message error)
      | _ ->
          None
    end

(******************************************************************************)
(*                                   Messages                                 *)
(******************************************************************************)

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

let max_message_size = ref max_int

let set_max_message_size size =
  (* We set a minimum size of 1 to ensure that errors can go through. *) 
  max_message_size := max size 1

(******************************************************************************)
(*                          Serializing Destinations                          *)
(******************************************************************************)

(* Convert a destination into a string. *)
let serialize_destination destination =
  match destination with
    | D_stdout -> "O"
    | D_stderr -> "E"

(* Parse a destination from a string. Return the destination and the offset
   of the first character after it. *)
let deserialize_destination string =
  if String.length string > 0 then
    match string.[0] with
      | 'O' -> D_stdout, 1
      | 'E' -> D_stderr, 1
      | _ ->
          error E_invalid_print_destination
  else
    error E_invalid_print_destination

(******************************************************************************)
(*                           Non-Blocking Functions                           *)
(******************************************************************************)

let send_message connection kind body =
  (* Send the SIZE. *)
  Procord_connection.send connection (string_of_int (String.length body));
  (* Send the KIND. *)
  Procord_connection.send connection (String.make 1 kind);
  (* Send the BODY. *)
  Procord_connection.send connection body

let send connection message =
  match message with
    | M_none ->
        ()
    | M_value serialized_value ->
        send_message connection 'V' serialized_value
    | M_task_name name ->
        send_message connection 'T' name
    | M_exception serialized_exn ->
        send_message connection 'X' serialized_exn
    | M_unknown_exception exn_as_string ->
        send_message connection 'U' exn_as_string
    | M_error error ->
        let body =
          match error with
            | E_task_not_supported -> "0"
            | E_unexpected_message -> "1"
            | E_ill_formed_message -> "2"
            | E_message_too_long -> "3"
            | E_disconnected -> "4"
            | E_invalid_print_destination -> "5"
        in
        send_message connection 'E' body
    | M_print (destination, message) ->
        let body = serialize_destination destination ^ message in
        send_message connection 'P' body
    | M_flush destination ->
        let body = serialize_destination destination in
        send_message connection 'F' body

let parse_message kind body =
  match kind with
    | 'V' ->
        M_value body
    | 'T' ->
        M_task_name body
    | 'X' ->
        M_exception body
    | 'U' ->
        M_unknown_exception body
    | 'E' ->
        begin
          match body with
            | "0" -> M_error E_task_not_supported
            | "1" -> M_error E_unexpected_message
            | "2" -> M_error E_ill_formed_message
            | "3" -> M_error E_message_too_long
            | "4" -> M_error E_disconnected
            | "5" -> M_error E_invalid_print_destination
            | _ -> error E_ill_formed_message
        end
    | 'P' ->
        let destination, message_offset = deserialize_destination body in
        let message =
          String.sub body message_offset (String.length body - message_offset)
        in
        M_print (destination, message)
    | 'F' ->
        let destination, message_offset = deserialize_destination body in
        if message_offset <> String.length body then
          error E_ill_formed_message
        else
          M_flush destination
    | _ ->
        error E_ill_formed_message

(* Auxiliary function for [receive], which is used once the SIZE is known. *)
let receive_knowing_size connection size kind_index kind =
  (* Compute the full size of the message. *)
  let full_size = kind_index + 1 + size in

  (* Receive the full message if possible. *)
  if Procord_connection.receive_buffer_length connection >= full_size then
    begin
      (* Remove SIZE and KIND from the connection buffer. *)
      Procord_connection.receive_forget connection (kind_index + 1);

      (* Receive BODY. *)
      let body =
        match Procord_connection.receive connection size with
          | None ->
              assert false
          | Some body ->
              body
      in

      (* Parse the message. *)
      parse_message kind body
    end
  else
    (* BODY not received yet, try again later. *)
    M_none

let receive connection =
  (* Poll some bytes, enough to fit a 64bits integer plus a KIND. *)
  let max_length = 20 in
  let bytes =
    Procord_connection.receive_poll_part connection 0 max_length
  in
  let actual_length = String.length bytes in

  (* Find out whether there is a KIND already, i.e. a non-digit character. *)
  let rec find_kind index =
    if index >= actual_length then
      None
    else
      match bytes.[index] with
        | '0' .. '9' ->
            find_kind (index + 1)
        | kind ->
            Some (index, kind)
  in

  match find_kind 0 with
    | None ->
        (* No kind in [bytes]. *)
        if actual_length = max_length then
          (* SIZE is unreasonably big. *)
          error E_message_too_long
        else
          (* Try again later, maybe we did not receive the KIND yet. *)
          M_none

    | Some (kind_index, kind) ->
        (* Parse SIZE. *)
        let size_as_string =
          String.sub bytes 0 kind_index
        in
        let size =
          try
            int_of_string size_as_string
          with _ ->
            (* SIZE does not fit in an [int] or is empty. *)
            if size_as_string = "" then
              error E_ill_formed_message
            else
              error E_message_too_long
        in

        (* Check that SIZE is not too big. *)
        if size > !max_message_size then
          error E_message_too_long;

        (* Receive the BODY if possible. *)
        receive_knowing_size connection size kind_index kind

(******************************************************************************)

let send_value connection serialized_value =
  send connection (M_value serialized_value)

let send_task_name connection task_name =
  send connection (M_task_name task_name)

let send_exception connection serialized_exn =
  send connection (M_exception serialized_exn)

let send_unknown_exception connection exn_as_string =
  send connection (M_unknown_exception exn_as_string)

let send_error connection error =
  send connection (M_error error)

let send_print connection destination message =
  send connection (M_print (destination, message))

let send_flush connection destination =
  send connection (M_flush destination)

(******************************************************************************)
(*                             Blocking Functions                             *)
(******************************************************************************)

let rec blocking_receive connection =
  (* Update the connection. *)
  Procord_connection.update connection;

  (* Check for disconnection. *)
  match Procord_connection.state connection with
    | Procord_connection.Connecting
    | Procord_connection.Connected
    | Procord_connection.Disconnecting ->
        (* Receive stuff. *)
        blocking_receive_assuming_connection_is_alive connection

    | Procord_connection.Disconnected _ ->
        error E_disconnected

and blocking_receive_assuming_connection_is_alive connection =
  match receive connection with
    | M_none ->
        (* Wait and try again. *)
        Procord_connection.wait' (Procord_connection.waiter connection);
        blocking_receive connection

    | message ->
        message

let blocking_receive_task_name connection =
  match blocking_receive connection with
    | M_task_name name ->
        name
    | M_none
        (* Cannot happen with blocking_receive. *)
    | M_value _
    | M_exception _
    | M_unknown_exception _
    | M_error _
    | M_print _
    | M_flush _ ->
        (* Unexpected message. *)
        error E_unexpected_message

let blocking_receive_value connection =
  match blocking_receive connection with
    | M_value value ->
        value
    | M_none
        (* Cannot happen with blocking_receive. *)
    | M_task_name _
    | M_exception _
    | M_unknown_exception _
    | M_error _
    | M_print _
    | M_flush _ ->
        (* Unexpected message. *)
        error E_unexpected_message

(******************************************************************************)
(*                         Formatters and Destinations                        *)
(******************************************************************************)

let formatter_of_destination destination =
  match destination with
    | D_stdout -> Format.std_formatter
    | D_stderr -> Format.err_formatter
