(**
 * Copyright (c) 2013-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

module Ast = Flow_ast
module L = Utils_js.LocMap
module D = Mapper_differ
module J = Js_layout_generator
module F = Ast.Function

type patch = (int * int * string) list

let show_patch p: string =
  ListUtils.to_string ""
    (fun (s, e, p) -> Printf.sprintf "Start: <%d> End: <%d> Patch: <%s>\n" s e p) p

let file_info file_path : string list * (int * int * int) list =
  let input_channel = open_in file_path in
  let rec build_list l =
    match input_line input_channel with
    | line -> build_list (line :: l)
    | exception End_of_file -> close_in input_channel ; List.rev l
  in
  let lines_read = build_list [] in
  let lines, line_counts, _ =
    List.fold_left
      (fun (lines, acc, prev_offset) s ->
        let size = String.length s in
        let new_offset = prev_offset + size in
        (s :: lines, (size, prev_offset, new_offset) :: acc, new_offset + 1) )
      ([], [(0, 0, 0)], 0)
      lines_read
  in
  (lines, line_counts)

let mk_patch (diff : Mapper_differ.t) (ast : (Loc.t, Loc.t) Ast.program)
    (file_path : string) : patch =
  let _, line_counts = file_info file_path in
  let line_counts_arr = Array.of_list (List.rev line_counts) in
  let offset {Loc.line; column; _} =
    let _, line_start, _ = line_counts_arr.(line) in
    line_start + column
  in
  let attached_comments = Flow_prettier_comments.attach_comments ast in
  J.with_attached_comments := Some attached_comments ;
  let spans =
    L.fold
      (fun loc value acc ->
        let {Loc.start; _end; _} = loc in
        let node_string =
          ( match value with
          | D.Statement (_, node) -> J.statement node
          | D.Expression (_, node) -> J.expression node
          | D.Type (_, node) -> J.type_ node
          | D.Return (F.Available annot) -> J.type_annotation annot
          | D.Return (F.Missing _) -> Layout.Empty
          | D.ClassElement (_, node) -> (
            match node with
            | Ast.Class.Body.Method meth -> J.class_method meth
            | Ast.Class.Body.Property prop -> J.class_property prop
            | Ast.Class.Body.PrivateField field -> J.class_private_field field
            ) )
          |> Pretty_printer.print ~skip_endline:true ~source_maps:None
          |> Source.contents
        in
        let node_string =
          match value with
          | D.Return (F.Available _) -> node_string ^ " "
          | _ -> node_string
        in
        (offset start, offset _end, node_string) :: acc )
      diff []
  in
  J.with_attached_comments := None ;
  spans

let mk_patch_ast_differ (diff : Flow_ast_differ.node Flow_ast_differ.change list)
  (ast : (Loc.t, Loc.t) Ast.program) (file_path : string) : patch =

   let _, line_counts = file_info file_path in
   let line_counts_arr = Array.of_list (List.rev line_counts) in
   let offset {Loc.line; column; _} =
     let _, line_start, _ = line_counts_arr.(line) in
     line_start + column in

   let attached_comments = Some (Flow_prettier_comments.attach_comments ast) in
   Ast_diff_printer.edits_of_changes attached_comments diff
   |> List.map (fun (loc, text) -> Loc.(offset loc.start, offset loc._end, text))

let print (patch : patch) (file_path : string) : string =
  let patch_sorted = List.sort
   (fun (start_one, _, _) (start_two, _, _) -> compare start_one start_two)
   patch
  in
  let lines, line_counts = file_info file_path in
  let _, _, file_end = List.hd line_counts in
  let file_string = String.concat "\n" (List.rev lines) in
  (* Apply the spans to the original text *)
  let result_string_minus_end, last_span =
    List.fold_left
      (fun (file, last) (start, _end, text) ->
        let file_curr =
          Printf.sprintf "%s%s%s" file
            (String.sub file_string last (start - last))
            text
        in
        (file_curr, _end) )
      ("", 0) patch_sorted
  in
  let last_span_to_end_size = file_end - last_span in
  let result_string =
    if last_span_to_end_size = 0 then
      Printf.sprintf "%s\n" result_string_minus_end
    else
      Printf.sprintf "%s%s\n" result_string_minus_end
        (String.sub file_string last_span last_span_to_end_size)
  in
  result_string
