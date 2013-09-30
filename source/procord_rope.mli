(** Strings represented by multiple actual strings. *)

type t
  (** Strings of strings. *)

val empty: t
  (** The empty rope. *)

val is_empty: t -> bool
  (** Test whether a rope is empty.
      Equivalent to testing whether the length is [0]. *)

val of_string: string -> t
  (** Make a rope from a string. *)

val to_string: t -> string
  (** Convert a rope back into a string.
      You should avoid doing this as much as possible. *)

val iter_string_pieces: t -> (string -> int -> int -> unit) -> unit
  (** Iterate on the string pieces of a rope.

      Usage: [iter_string_pieces rope f]

      Function [f] is called as [f string offset length] for each
      piece of the rope, left-to-right. *)

val concat: t -> t -> t
  (** Rope concatenation.

      Complexity: O(1). *)

val sub: t -> int -> int -> t
  (** Make a rope from a part of another rope.

      Usage: [sub rope offset length]

      If [offset] and [length] do not designate a valid piece of the rope,
      raise [Invalid_arg].

      Complexity: O(n) where n is the size of the tree (not the length of the
      rope, there is no string copying involved). *)

val length: t -> int
  (** Return the length, in bytes, of a rope.

      Complexity: O(1). *)
