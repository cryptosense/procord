type t =
  | String of string * int * int (* string, offset, length *)
  | Concat of t * t * int (* int is the length *)

let length rope =
  match rope with
    | String (_, _, length)
    | Concat (_, _, length) ->
        length

let iter_string_pieces rope f =
  (* [aux] is [iter_string_pieces] restricted to the sub-rope starting
     at [offset] and of length [length]. *)
  let rec aux rope rope_offset rope_length =
    if rope_length > 0 then
      match rope with
        | String (string, string_offset, string_length) ->
            f string (rope_offset + string_offset) rope_length

        | Concat (a, b, _) ->
            let length_a = length a in
            if rope_offset + rope_length <= length_a then
              (* Everything in a. *)
              aux a rope_offset rope_length
            else if rope_offset >= length_a then
              (* Everything in b. *)
              aux b (rope_offset - length_a) rope_length
            else
              (* Partly in a and partly in b. *)
              begin
                aux a rope_offset (length_a - rope_offset);
                aux b 0 (rope_length - length_a + rope_offset)
              end
  in
  aux rope 0 (length rope)

let empty = String ("", 0, 0)

let is_empty rope =
  length rope = 0

let to_string rope =
  let result = String.create (length rope) in
  let result_offset = ref 0 in
  iter_string_pieces rope
    begin fun string offset length ->
      String.blit string offset result !result_offset length;
      result_offset := !result_offset + length
    end;
  result

let of_string string =
  String (string, 0, String.length string)

let concat a b =
  Concat (a, b, length a + length b)

(* "unsafe" because it does not check for boundaries.
   This is a precondition. *)
let rec sub_unsafe rope requested_offset requested_length =
  match rope with
    | String (string, string_offset, _string_length) ->
        String (string, string_offset + requested_offset, requested_length)

    | Concat (_, _, rope_length) when rope_length = requested_length ->
        (* In this case we keep the whole rope. No need to recurse and rebuild
           the rope. *)
        rope

    | Concat (a, b, _) ->
        let length_a = length a in
        (* See if a or b can be dropped. *)
        if requested_offset >= length_a then
          (* a can be dropped. *)
          sub_unsafe b (requested_offset - length_a) requested_length
        else if requested_offset + requested_length <= length_a then
          (* b can be dropped. *)
          sub_unsafe a requested_offset requested_length
        else
          (* Maybe there is something in a or b that can be dropped, so we
             recurse. We actually don't have a choice since, by typing, all
             "sub" nodes are actually leaves. *)
          let new_a =
            sub_unsafe a requested_offset (length_a - requested_offset)
          in
          let new_b =
            sub_unsafe b 0 (requested_length - length_a + requested_offset)
          in
          Concat (new_a, new_b, requested_length)

let sub rope requested_offset requested_length =
  let rope_length = length rope in
  if
    requested_offset < 0
    || requested_length < 0
    || requested_offset > rope_length
    || requested_length > rope_length - requested_offset
  then
    invalid_arg "Rope.sub"
  else
    sub_unsafe rope requested_offset requested_length

(* let _unit_tests = *)
(*   List.iter *)
(*     (fun (name, list) -> *)
(*        let index = ref 0 in *)
(*        List.iter *)
(*          (fun (left, right) -> *)
(*             incr index; *)
(*             if to_string left <> right then *)
(*               Printf.printf "test %s.%d: failed\n%!" name !index *)
(*             else *)
(*               Printf.printf "test %s.%d: ok\n%!" name !index) *)
(*          list) *)
(*     [ *)
(*       "of_string", *)
(*       [ *)
(*         of_string "", ""; *)
(*         of_string "a", "a"; *)
(*         of_string "hello", "hello"; *)
(*       ]; *)

(*       "concat", *)
(*       [ *)
(*         concat (of_string "") (of_string ""), ""; *)
(*         concat (of_string "") (of_string "salut"), "salut"; *)
(*         concat (of_string "hello") (of_string ""), "hello"; *)
(*         concat (of_string "hi") (of_string "you"), "hiyou"; *)
(*         concat *)
(*           (concat (of_string "a") (of_string "b")) *)
(*           (of_string "c"), *)
(*         "abc"; *)
(*         concat *)
(*           (concat (of_string "a1") (of_string "b23")) *)
(*           (concat (of_string "c38") (of_string "d20")), *)
(*         "a1b23c38d20"; *)
(*         concat *)
(*           (of_string "c") *)
(*           (concat (of_string "a") (of_string "b")), *)
(*         "cab"; *)
(*       ]; *)

(*       "sub", *)
(*       [ *)
(*         sub (of_string "") 0 0, ""; *)
(*         sub (of_string "a") 0 1, "a"; *)
(*         sub (of_string "a") 1 0, ""; *)
(*         (try sub (of_string "a") 1 1 with _ -> of_string "ok"), "ok"; *)
(*         (try sub (of_string "a") 2 0 with _ -> of_string "ok"), "ok"; *)
(*         sub (of_string "salut") 2 2, "lu"; *)
(*         sub (of_string "salut") 2 3, "lut"; *)
(*         sub (sub (of_string "salut") 2 3) 0 2, "lu"; *)
(*         sub (sub (sub (of_string "salut") 2 3) 0 2) 1 1, "u"; *)
(*         sub (sub (sub (sub (of_string "salut") 2 3) 0 2) 1 1) 1 0, ""; *)
(*         sub (sub (sub (sub (sub (of_string "salut") 2 3) 0 2) 1 1) 1 0) 0 0, ""; *)
(*         sub (of_string "salut") 0 5, "salut"; *)
(*       ]; *)

(*       "complex", *)
(*       [ *)
(*         concat (of_string "hi") (of_string "you"), *)
(*         "hiyou"; *)
(*         sub (concat (of_string "hi") (of_string "you")) 1 3, *)
(*         "iyo"; *)
(*         sub (concat (of_string "hi") (of_string "you")) 0 1, *)
(*         "h"; *)
(*         sub (concat (of_string "hi") (of_string "you")) 1 1, *)
(*         "i"; *)
(*         sub (concat (of_string "hi") (of_string "you")) 2 1, *)
(*         "y"; *)
(*         sub (concat (of_string "hi") (of_string "you")) 3 1, *)
(*         "o"; *)
(*         sub (concat (of_string "hi") (of_string "you")) 4 1, *)
(*         "u"; *)
(*         sub *)
(*           (sub (concat (of_string "hi") (of_string "you")) 1 3) *)
(*           0 2, *)
(*         "iy"; *)
(*         sub (of_string "hopla") 0 5, *)
(*         "hopla"; *)
(*         concat *)
(*           (sub *)
(*              (sub (concat (of_string "hi") (of_string "you")) 1 3) *)
(*              0 2) *)
(*           (sub (of_string "hopla") 0 5), *)
(*         "iyhopla"; *)
(*         sub *)
(*           (concat *)
(*              (sub *)
(*                 (sub (concat (of_string "hi") (of_string "you")) 1 3) *)
(*                 0 2) *)
(*              (sub (of_string "hopla") 0 5)) *)
(*           1 5, *)
(*         "yhopl"; *)
(*       ]; *)
(*     ] *)
