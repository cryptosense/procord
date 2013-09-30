open Ocamlbuild_plugin

(* let after_rules () = *)
(*   begin *)
(*     match Sys.os_type with *)
(*       | "Unix" -> *)
(*           flag ["compile"; "c"] (S [A "-ccopt"; A "-DPROCORD_UNIX"]); *)
(*       | "Win32" -> *)
(*           flag ["compile"; "c"] (S [A "-ccopt"; A "-DPROCORD_WIN32"]) *)
(*       | _ -> *)
(*           () *)
(*   end; *)

(*   dep ["link"] ["source/procord_terminate_process.o"]; *)
(*   tag_any ["custom"]; *)

(*   () *)

(* let () = dispatch (function After_rules -> after_rules () | _ -> ()) *)
