(**************************************************************************)
(*                                                                        *)
(*    Copyright 2014 OCamlPro                                             *)
(*    Copyright 2012 INRIA                                                *)
(*                                                                        *)
(*  All rights reserved.This file is distributed under the terms of the   *)
(*  GNU Lesser General Public License version 3.0 with linking            *)
(*  exception.                                                            *)
(*                                                                        *)
(*  OPAM is distributed in the hope that it will be useful, but WITHOUT   *)
(*  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY    *)
(*  or FITNESS FOR A PARTICULAR PURPOSE.See the GNU General Public        *)
(*  License for more details.                                             *)
(*                                                                        *)
(**************************************************************************)

open OpamTypes

module type ACTION = sig
  type package
  module Pkg : GenericPackage with type t = package
  include OpamParallel.VERTEX with type t = package action
  val to_string: [< t ] -> string
  val to_aligned_strings: [< t ] list -> string list
end

let name_of_action = function
  | `Remove _ -> "remove"
  | `Install _ -> "install"
  | `Upgrade _ -> "upgrade"
  | `Downgrade _ -> "downgrade"
  | `Reinstall _ -> "recompile"
  | `Build _ -> "build"

let symbol_of_action = function
  | `Remove _ -> "\xe2\x8a\x98 "
  | `Install _ -> "\xe2\x88\x97 "
  | `Upgrade _ -> "\xe2\x86\x97 "
  | `Downgrade _ -> "\xe2\x86\x98 "
  | `Reinstall _ -> "\xe2\x86\xbb "
  | `Build _ -> "\xe2\x88\x97 "

let action_strings ?utf8 a =
  if utf8 = None && (OpamConsole.utf8 ()) || utf8 = Some true
  then symbol_of_action a
  else name_of_action a

let action_color c =
  OpamConsole.colorise (match c with
      | `Install _ | `Upgrade _ -> `green
      | `Remove _ | `Downgrade _ -> `red
      | `Reinstall _ | `Build _ -> `yellow)

module MakeAction (P: GenericPackage) : ACTION with type package = P.t
= struct
  module Pkg = P
  type package = P.t
  type t = package action

  let compare t1 t2 =
    (* `Install > `Build > `Upgrade > `Reinstall > `Downgrade > `Remove *)
    match t1,t2 with
    | `Remove p, `Remove q
    | `Install p, `Install q
    | `Reinstall p, `Reinstall q
    | `Build p, `Build q
      -> P.compare p q
    | `Upgrade (p0,p), `Upgrade (q0,q)
    | `Downgrade (p0,p), `Downgrade (q0,q)
      ->
      let c = P.compare p q in
      if c <> 0 then c else P.compare p0 q0
    | `Install _, _ | _, `Remove _ -> 1
    | _, `Install _ | `Remove _, _ -> -1
    | `Build _, _ | _, `Downgrade _ -> 1
    | `Downgrade _, _ | _, `Build _ -> -1
    | `Upgrade _, `Reinstall _ -> 1
    | `Reinstall _, `Upgrade _ -> -1

  let hash a = Hashtbl.hash (OpamTypesBase.map_action P.hash a)

  let equal t1 t2 = compare t1 t2 = 0

  let to_string a = match a with
    | `Remove p | `Install p | `Reinstall p | `Build p ->
      Printf.sprintf "%s %s" (action_strings a) (P.to_string p)
    | `Upgrade (p0,p) | `Downgrade (p0,p) ->
      Printf.sprintf "%s.%s %s %s"
        (P.name_to_string p0)
        (P.version_to_string p0)
        (action_strings a)
        (P.version_to_string p)

  let to_aligned_strings l =
    let tbl =
      List.map (fun a ->
          let a = (a :> package action) in
          (if OpamConsole.utf8 ()
           then action_color a (symbol_of_action a)
           else "-")
          :: name_of_action a
          :: OpamConsole.colorise `bold
            (P.name_to_string (OpamTypesBase.action_contents a))
          :: match a with
          | `Remove p | `Install p | `Reinstall p | `Build p ->
            P.version_to_string p :: []
          | `Upgrade (p0,p) | `Downgrade (p0,p) ->
            Printf.sprintf "%s to %s"
              (P.version_to_string p0) (P.version_to_string p)
            :: [])
        l
    in
    List.map (String.concat " ") (OpamStd.Format.align_table tbl)

  let to_json = function
    | `Remove p -> `O ["remove", P.to_json p]
    | `Install p -> `O ["install", P.to_json p]
    | `Upgrade (o, p) | `Downgrade (o, p) ->
      `O ["change", `A [P.to_json o;P.to_json p]]
    | `Reinstall p -> `O ["recompile", P.to_json p]
    | `Build p -> `O ["build", P.to_json p]

end

module type SIG = sig
  type package
  include OpamParallel.GRAPH with type V.t = package OpamTypes.action
  val reduce: t -> t
  val explicit: t -> t
end

module Make (A: ACTION) : SIG with type package = A.package = struct
  type package = A.package

  include OpamParallel.MakeGraph(A)

  module Map = OpamStd.Map.Make (A.Pkg)

  (* Turn atomic actions (only install and remove) to higher-level actions
     (install, remove, up/downgrade, recompile) *)
  let reduce g =
    let removals =
      fold_vertex (fun v acc -> match v with
          | `Remove p ->
            OpamStd.String.Map.add (A.Pkg.name_to_string p) p acc
          | _ -> acc)
        g OpamStd.String.Map.empty
    in
    let reduced = ref Map.empty in
    let g =
      map_vertex (function
          | `Install p as act ->
            (try
               let p0 = OpamStd.String.Map.find (A.Pkg.name_to_string p) removals in
               let act =
                 match A.Pkg.compare p0 p with
                 | 0 -> `Reinstall p
                 | c when c > 0 -> `Downgrade (p0, p)
                 | _ -> `Upgrade (p0, p)
               in
               reduced := Map.add p0 act !reduced;
               act
             with Not_found -> act)
          | act -> act)
        g
    in
    Map.iter (fun p act ->
        let rm_act = `Remove p in
        iter_pred (fun v -> add_edge g v act) g rm_act;
        remove_vertex g rm_act
      ) !reduced;
    g

  let explicit g0 =
    let g = copy g0 in
    iter_vertex (fun a ->
        match a with
        | `Install p | `Reinstall p | `Upgrade (_, p) | `Downgrade (_, p) ->
          let b = `Build p in
          iter_pred (fun pred -> remove_edge g pred a; add_edge g pred b) g a;
          add_edge g b a
        | `Remove _ -> ()
        | `Build _ -> assert false)
      g0;
    g
end
