module E = Pb_exception 
module Pt = Pb_parsing_parse_tree 
module Tt = Pb_typing_type_tree
module Typing_util = Pb_typing_util 

let scope_of_package = function
  | Some s -> {Typing_util.empty_scope with 
    Tt.packages = List.rev @@ Pb_util.rev_split_by_char '.' s
  }
  | None -> Typing_util.empty_scope 

let unresolved_of_string s = 
  match Pb_util.rev_split_by_char '.' s with 
  | [] -> E.programmatic_error E.Invalid_string_split
  | hd :: tl -> {
    Tt.type_path = (List.rev tl); 
    Tt.type_name = hd;
    Tt.from_root = String.get s 0 = '.';
  }

let field_type_of_string = function
 | "double"    -> Tt.Field_type_double 
 | "float"     -> Tt.Field_type_float 
 | "int32"     -> Tt.Field_type_int32 
 | "int64"     -> Tt.Field_type_int64 
 | "uint32"    -> Tt.Field_type_uint32 
 | "uint64"    -> Tt.Field_type_uint64
 | "sint32"    -> Tt.Field_type_sint32 
 | "sint64"    -> Tt.Field_type_sint64 
 | "fixed32"   -> Tt.Field_type_fixed32 
 | "fixed64"   -> Tt.Field_type_fixed64 
 | "sfixed32"  -> Tt.Field_type_sfixed32 
 | "sfixed64"  -> Tt.Field_type_sfixed64
 | "bool"      -> Tt.Field_type_bool 
 | "string"    -> Tt.Field_type_string 
 | "bytes"     -> Tt.Field_type_bytes 
 | s  -> Tt.Field_type_type  (unresolved_of_string s) 

let get_default field_options = 
  match List.assoc "default" field_options with
  | constant -> Some constant 
  | exception Not_found -> None 

let compile_field_p1 field_parsed =

  let {
    Pt.field_type;
    Pt.field_options;_
  } = field_parsed in

  let field_type = field_type_of_string field_type in 
  let field_default = get_default field_options in 
  {
    Tt.field_parsed;
    Tt.field_type;
    Tt.field_default;
    Tt.field_options;
  }

let compile_map_p1 map_parsed = 
  let {
    Pt.map_name;
    Pt.map_number;
    Pt.map_key_type;
    Pt.map_value_type;
    Pt.map_options;
  } = map_parsed in 

  Tt.({
    map_name; 
    map_number;
    map_key_type = field_type_of_string map_key_type;
    map_value_type = field_type_of_string map_value_type;
    map_options;
  })

let compile_oneof_p1 oneof_parsed = 
  let {Pt.oneof_name; Pt.oneof_fields} = oneof_parsed in   

  {
    Tt.oneof_name; 
    Tt.oneof_fields = List.map compile_field_p1 oneof_fields; 
  }
  
let not_found f : bool = 
  try f () ; false 
  with | Not_found -> true 

let rec list_assoc2 x = function
    [] -> raise Not_found
  | (a,b)::l -> if compare b x = 0 then a else list_assoc2 x l

let make_proto_type ~file_name ~file_options ~id ~scope ~spec = { 
  Tt.id; 
  Tt.scope;
  Tt.file_name;
  Tt.file_options;
  Tt.spec; 
}

(* compile a [Pbpt] enum to a [Pbtt] type *) 
let compile_enum_p1 
    ?parent_options:(parent_options = []) file_name 
    file_options scope parsed_enum =
   
  let {Pt.enum_id; enum_name; enum_body}  = parsed_enum in

  let rec aux enum_values enum_options = function
    | [] -> 
      let spec = Tt.Enum {
        Tt.enum_name;
        Tt.enum_values = List.rev enum_values;
        Tt.enum_options = (List.rev enum_options) @ parent_options; 
      } in 
      make_proto_type ~file_name ~file_options ~id:enum_id ~scope ~spec

    | (Pt.Enum_value {Pt.enum_value_name; enum_value_int})::tl -> 
      let enum_value = Tt.({enum_value_name; enum_value_int}) in 
      aux (enum_value::enum_values) enum_options tl 

    | (Pt.Enum_option enum_option)::tl -> 
      aux enum_values (enum_option::enum_options) tl 
  in
  aux [] [] enum_body

(* compile a [Pbpt] message a list of [Pbtt] types (ie messages can 
 * defined more than one type).  *)
let rec validate_message 
    ?parent_options:(parent_options = []) file_name file_options 
    message_scope parsed_message = 
    
  let {Pt.id; Pt.message_name; Pt.message_body} = parsed_message in
  
  let {Tt.message_names; _ } = message_scope in  
  let sub_scope = {message_scope with 
    Tt.message_names = message_names @ [message_name] 
  } in 

  let module Acc = struct 
    (* Ad-hoc module for the "large" accumulated data during the 
       fold_left below. 
     *)

    type ('a, 'b, 'c, 'd) t = {
      message_body : 'a list; 
      extensions : 'b list; 
      options : 'c list; 
      all_types: 'd list; 
    } 

    let e0 parent_options = { 
      message_body = []; 
      extensions = []; 
      options = parent_options; 
      all_types = []; 
    } 
  end  in

  let acc = List.fold_left (fun acc field ->

    let {
      Acc.message_body; 
      extensions; 
      options; 
      all_types
    } = acc in 

    match field with 
    | Pt.Message_field f -> 
      let field = Tt.Message_field (compile_field_p1 f) in 
      {acc with Acc.message_body = field :: message_body} 

    | Pt.Message_map_field m ->
      let field = Tt.Message_map_field (compile_map_p1 m) in
      {acc with Acc.message_body = field :: message_body} 

    | Pt.Message_oneof_field o -> 
      let field = Tt.Message_oneof_field (compile_oneof_p1 o) in 
      {acc with Acc.message_body = field  :: message_body} 

    | Pt.Message_sub m -> 
      let parent_options = options in 
      let all_sub_types = 
        validate_message ~parent_options file_name file_options sub_scope m 
      in 
      {acc with Acc.all_types = all_types @ all_sub_types} 

    | Pt.Message_enum parsed_enum-> 
      let parent_options = options in 
      let enum = compile_enum_p1 
          ~parent_options file_name file_options sub_scope parsed_enum
      in
      {acc with Acc.all_types = all_types @ [enum]}

    | Pt.Message_extension extension_ranges -> 
      {acc with Acc.extensions = extensions @ extension_ranges }
    
    | Pt.Message_reserved _ -> acc 
      (* TODO add support for checking reserved fields *) 

    | Pt.Message_option message_option -> 
      {acc with Acc.options = message_option::options} 

  ) (Acc.e0 parent_options) message_body in
  
  let message_body = List.rev acc.Acc.message_body in 
  
  (* Both field name and field number must be unique 
   * within a message scope. This includes the field in a 
   * oneof field inside the message. 
   *
   * This function verifies this constrain and raises
   * the corresponding Duplicated_field_number exception in 
   * case it is violated. *)
  let validate_duplicate (number_index:(int*string) list) name number = 
    if not_found (fun () -> ignore @@ List.assoc  number number_index) && 
       not_found (fun () -> ignore @@ list_assoc2 name   number_index)
    then 
      (number, name)::number_index
    else 
      E.duplicated_field_number 
        ~field_name:name ~previous_field_name:"" ~message_name ()
  in

  let validate_duplicate_field number_index field = 
    let number = Typing_util.field_number field in 
    let name = Typing_util.field_name field in 
    validate_duplicate number_index name number
  in

  ignore @@ List.fold_left (fun number_index -> function 
    | Tt.Message_field field -> validate_duplicate_field number_index field

    | Tt.Message_oneof_field {Tt.oneof_fields; _ } ->
       List.fold_left validate_duplicate_field number_index oneof_fields

    | Tt.Message_map_field m -> 
      let {Tt.map_name; map_number; _} = m in 
      validate_duplicate number_index map_name map_number

  ) [] message_body ;  

  let spec = Tt.(Message {
    extensions = acc.Acc.extensions; 
    message_options = acc.Acc.options;
    message_name; 
    message_body;
  }) in

  acc.Acc.all_types @ [
    make_proto_type ~file_name ~file_options ~id ~scope:message_scope ~spec 
  ] 

let validate proto  =  
  let {
    Pt.package; 
    Pt.proto_file_name;
    messages; 
    enums; 
    file_options; _; 
  } = proto in 
  let file_name = Pb_util.Option.default "" proto_file_name in 
  let scope = scope_of_package package in 
  let pbtt_msgs = List.fold_right (fun e pbtt_msgs -> 
    (compile_enum_p1 file_name file_options scope e) :: pbtt_msgs 
  ) enums [] in
  List.fold_left (fun pbtt_msgs pbpt_msg -> 
    pbtt_msgs @ validate_message file_name file_options scope pbpt_msg
  ) pbtt_msgs messages 
