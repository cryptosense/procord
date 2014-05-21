(** Connection through UNIX file descriptors. *)

(** Connections are similar to sockets with the following added features:
    - handling of the non-blocking mode;
    - built-in buffer management;
    - automatic ping sending and idle detection. *)

(** This module can manage connections on sockets or on regular file
    descriptors. You can, for instance, simulate a connection with the
    parent process using [Unix.stdin] for input and [Unix.stdout] or
    [Unix.stderr] for output; or simulate a connection through pipes. *)

(** {2 Connections} *)

type 'a t
  (** Connections, i.e. sockets with added features.

      You may associate your own data with each connection.
      Parameter ['a] is the type of the data that is associated with the
      socket. *)

val connect: ?timeout: float -> ?ping: string -> string -> int -> 'a ->
  'a t
  (** Connect to a server using a socket.

      Usage: [connect ?timeout ?ping hostname port data]

      @param timeout If the connection has been idle (nothing received)
        for [timeout] seconds, disconnect automatically.
      @param ping If the connection has been idle (nothing received)
        for [timeout /. 2.] seconds, send this message automatically.
        Ignored if [timeout] is unspecified.
      @param hostname The remote host, which can be an IP address, an IPv6
        address, or a DNS address.
      @param port The remote port.
      @param data Data associated with the connection.

      May raise [Unix.Unix_error] if the address is already in use or is not
      available, or in case of any other error that immediately prevents
      a connection.

      The resulting connection is usually in the [Connecting] state.
      Call [update] and [state] to wait for the connection to be established. *)

val update: 'a t -> unit
  (** Update a connection.
      Send and receive data from and to the internal buffers, send a ping
      message if needed, and close the connection if it is idle. *)

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
          failed and the string argument to the function, if any.

          Warning: there may still be data to be [receive]d.
          Call [receive_buffer_empty] to check. *)

val state: 'a t -> state
  (** Get the state of the connection at the last [update]. *)

val alive: 'a t -> bool
  (** Return whether a connection is alive.

      Return [true] if [state] is [Connecting], [Connected] or [Disconnecting].
      Return [false] if [state] is [Disconnected]. *)

val send: 'a t -> string -> unit
  (** Send data to a connection.

      The data is put in the connection buffer.
      Call [update] regularly to ensure the data is sent eventually.

      You may call [send] while the connection is establishing.
      The data will be sent eventually if you call [update].

      You may call [send] after the socket is disconnected, but nothing will
      happen. *)

val receive: 'a t -> int -> string option
  (** Receive data from a connection.

      Usage: [receive connection length]

      If at least [length] bytes are available in the connection
      buffer, return [length] bytes (not more, not less). Else, return
      [None].

      Calling [receive] while the connection is establishing returns [None].

      Note that there might still be bytes to read even if the socket is
      disconnected. *)

val receive_poll: 'a t -> int -> int -> string option
  (** Same as [receive], but do not remove the data from the buffer.

      Usage: [receive_poll connection offset length]

      If at least [offset + length] bytes are available in the connection
      buffer, return [length] bytes (not more, not less) starting at [offset].
      Else, return [None]. *)

val receive_poll_part: 'a t -> int -> int -> string
  (** Same as [receive_poll], but may receive less data than requested.

      Usage: [receive_poll connection offset length]

      Return at most [length] bytes starting at [offset] in the buffer,
      possibly [0]. *)

val receive_all: 'a t -> string
  (** Same as [receive], but receive everything.

      Usage: [receive_all connection]

      Receive everything which is available in the buffer, possibly nothing. *)

val receive_part: 'a t -> int -> string
  (** Same as [receive], but may receive less data than requested.

      Usage: [receive_part connection length]

      If at least [length] bytes are available from the buffer, receive
      [length] bytes. Else, receive as much bytes as possible, possibly [0]. *)

val receive_forget: 'a t -> int -> unit
  (** Same as [receive], but do not actually return the received data.

      This is more efficient if you do not need the data. *)

val receive_buffer_length: 'a t -> int
  (** Return the length of the receive buffer. *)

val receive_buffer_empty: 'a t -> bool
  (** Return whether the receive buffer is empty. *)

val close: 'a t -> unit
  (** Close a connection if it is not closed already. *)

val close_nicely: ?timeout: float -> 'a t -> unit
  (** Same as close, but wait until all data is sent first.
      This is the only way the state can become [Disconnecting].

      @param timeout If specified, do not wait more than [timeout] seconds.

      As usual, the wait is non-blocking: call [update] until the socket
      is disconnected. *)

val data: 'a t -> 'a
  (** Get the data associated to a connection. *)

val timeout: 'a t -> float option
  (** Get the [timeout] argument which was passed to [connect] or [custom]. *)

(** {2 Synchronous Interface} *)

(** Synchronous interface to procord connections. *)
module Sync:
sig
  (** Synchronous interface to procord connections. *)

  (** These functions can be mixed with the asynchronous ones.
      They wait until either their condition is met or until [state]
      returns [Disconnected]. *)

  (** Same as [connect], but wait until the connection is established. *)
  val connect: ?timeout: float -> ?ping: string -> string ->
    int -> 'a -> 'a t

  (** Same as [close_nicely], but wait until the connection is closed. *)
  val close_nicely: ?timeout: float -> 'a t -> unit

  (** Same as [send], but wait until the sending buffer is empty. *)
  val send: 'a t -> string -> unit

  (** Same as [receive], but wait until the data is available. *)
  val receive: 'a t -> int -> string option
end

(** {2 Addresses (Socket Connections Only)} *)

val remote_address: 'a t -> Unix.sockaddr
  (** Get the remote address of a connection. *)

val make_address: string -> Unix.inet_addr
  (** Make a socket address from an IPv4, IPv6 or DNS address. *)

(** {2 Connection Sets} *)

(** This section is useful for servers. *)

type 'a set
  (** Client connection sets.

      Sets are mutable lists of connections.

      It could be argued that it would be easy to make this immutable.
      However, there is only one set of connection at any given time; it
      makes no sense to have several which live together. If a connection
      is closed, it should not be used anymore. Having the set mutable
      reflects this fact. *)

val empty_set: unit -> 'a set
  (** Create a new empty set of connections. *)

val accept_into_set:
  ?timeout: float -> ?ping: string -> Unix.file_descr ->
  (Unix.sockaddr -> 'a option) -> 'a set -> unit
  (** Accept new connections from a socket and add them to a set of
      connections.

      Usage: [accept_into_set ?timeout ?ping socket make_data connections]

      Function [make_data] is given the address of the remote peer,
      and shall return [Some data] where [data] is the data to
      associate with the connection, or [None] to close the connection
      immediately.

      See {!connect} for the meaning of [timeout] and [ping], which
      are applied to accepted connections.

      May raise [Unix_error (EBADF, ...)]. *)

val update_set: 'a set -> unit
(** Update all connections of a set, and remove closed connections. *)

val iter: 'a set -> ('a t -> unit) -> unit
  (** Iterate on all connections of a connection set. *)

(** {2 Waiting} *)

(** Waiting for something to happen using [Unix.select] can be tricky.
    It is easy to give the wrong set of file descriptors, resulting in
    unwanted delays or, on the opposite, the program using all the CPU.
    This section provides facilities to call [Unix.select] correctly
    on sockets.

    First, define a [waiter]. You may do it once and for all for connections
    using [waiter], even for servers using [waiter_of_listening_socket]
    and [waiter_of_set]. Then, just call [wait]. *)

type waiter
  (** Waiters for the [wait] function. *)

val waiter: 'a t -> waiter
  (** Make a waiter from a connection.

      The waiter will wait on the socket:
      - for reading, if the socket is [Connected];
      - for writing, if the socket is [Connecting] (to detect connection
        or errors) or if the socket is [Connected] and there is something
        to send;
      - for exceptional conditions, if the socket is [Connecting] (although
        this may not be necessary) or if it is [Connected].

      In other words, it will wait until it is worth calling [update] on
      the connection. *)

val waiter_of_listening_socket: Unix.file_descr -> waiter
  (** Make a waiter from a listening socket.

      The waiter will wait on the socket for reading and for exceptional
      conditions.

      In other words, it will wait until it is worth calling [Unix.accept]
      on the socket. *)

val waiter_of_set: 'a set -> waiter
  (** Make a waiter from a set of connections.

      The waiter will behave as if [waiter_of_list] was called on the list of
      waiters for all connections of a set. This list may change as the
      set grows and shrinks.

      In other words, it will wait until it is worth calling [update_set]
      on the set of connections. *)

val waiter_custom:
  ?read: Unix.file_descr list ->
  ?write: Unix.file_descr list ->
  ?except: Unix.file_descr list ->
  unit -> waiter
  (** Make a custom waiter from file descriptors.

      The waiter will wait:
      - for reading on all file descriptors in [read];
      - for writing on all file descriptors in [write];
      - for exceptional conditions on all file descriptors in [except]. *)

val waiter_of_list: waiter list -> waiter
  (** Make a waiter from a list of waiters.

      The waiter will wait until one of the waiters in the list wants to
      stop waiting. *)

val instanciate_waiter:
  waiter -> Unix.file_descr list * Unix.file_descr list * Unix.file_descr list
  (** Get the file descriptor lists for [Unix.select] from a waiter.

      Allows you to call [Unix.select] yourself. *)

val wait: ?timeout: float -> waiter -> bool
  (** Wait until something new happens.

      @param timeout If specified, stop waiting after [timeout] seconds.

      Return [true] if something happened, [false] in case of timeout. *)

val wait': ?timeout: float -> waiter -> unit
  (** Same as [wait] but ignore the result. *)

(** {2 Low-Level Access} *)

val custom:
  ?timeout: float ->
  ?ping: string ->
  ?input: Unix.file_descr ->
  ?output: Unix.file_descr ->
  ?remote_address: Unix.sockaddr ->
  'a -> 'a t
  (** Create a connection from custom file descriptors.

      Similar to [connect], but instead of taking an address as input, take
      file descriptors.

      @param input The file descriptor to read or receive data from.
        If unspecified, no data will ever be received.

      @param output The file descriptor to write or send data to.
        If unspecified, data sent will be ignored.

      @param remote_address The address returned by [remote_address].
        The default value is a dummy one, [ADDR_UNIX ""]. *)
