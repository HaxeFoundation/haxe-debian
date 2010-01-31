(*
 *  haXe/PHP Compiler
 *  Copyright (c)2008 Franco Ponticelli
 *  based on and including code by (c)2005-2008 Nicolas Cannasse
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program; if not, write to the Free Software
 *  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 *)
open Ast
open Type
open Common

type method_name = {
	mutable mpath : path;
	mutable mname : string;
}

type context = {
	com : Common.context;
	ch : out_channel;
	buf : Buffer.t;
	path : path;
	stack : Codegen.stack_context;
	mutable curclass : tclass;
	mutable curmethod : string;
	mutable tabs : string;
	mutable in_value : string option;
	mutable in_loop : bool;
	mutable handle_break : bool;
	mutable imports : (string,string list list) Hashtbl.t;
	mutable extern_required_paths : (string list * string) list;
	mutable extern_classes_with_init : path list;
	mutable locals : (string,string) PMap.t;
	mutable inv_locals : (string,string) PMap.t;
	mutable local_types : t list;
	mutable inits : texpr list;
	mutable constructor_block : bool;
	mutable quotes : int;
	mutable all_dynamic_methods: method_name list;
	mutable dynamic_methods: tclass_field list;
	mutable is_call : bool;
	mutable cwd : string;
}

let join_class_path path separator =
	let result = match fst path, snd path with
	| [], s -> s
	| el, s -> String.concat separator el ^ separator ^ s in
	if (String.contains result '+') then begin
		let idx = String.index result '+' in
		(String.sub result 0 idx) ^ (String.sub result (idx+1) ((String.length result) - idx -1 ) )
	end else
		result;;

(*  Get a string to represent a type.
	 The "suffix" will be nothing or "_obj", depending if we want the name of the
	 pointer class or the pointee (_obj class *)
let rec class_string klass suffix params =
	(match klass.cl_path with
	(* Array class *)
	|  ([],"Array") -> (snd klass.cl_path) ^ suffix ^ "<" ^ (String.concat ","
					 (List.map type_string  params) ) ^ " >"
	| _ when klass.cl_kind=KTypeParameter -> "Dynamic"
	|  ([],"#Int") -> "/* # */int"
	|  (["haxe";"io"],"Unsigned_char__") -> "unsigned char"
	|  ([],"Class") -> "Class"
	|  ([],"Null") -> (match params with
			| [t] ->
				(match follow t with
				| TInst ({ cl_path = [],"Int" },_)
				| TInst ({ cl_path = [],"Float" },_)
				| TEnum ({ e_path = [],"Bool" },_) -> "Dynamic"
				| _ -> "/*NULL*/" ^ (type_string t) )
			| _ -> assert false); 
	(* Normal class *)
	| _ -> (join_class_path klass.cl_path "::") ^ suffix
	)
and type_string_suff suffix haxe_type =
	(match haxe_type with
	| TMono r -> (match !r with None -> "Dynamic" | Some t -> type_string_suff suffix t)
	| TEnum ({ e_path = ([],"Void") },[]) -> "Void"
	| TEnum ({ e_path = ([],"Bool") },[]) -> "bool"
	| TInst ({ cl_path = ([],"Float") },[]) -> "double"
	| TInst ({ cl_path = ([],"Int") },[]) -> "int"
	| TEnum (enum,params) ->  (join_class_path enum.e_path "::") ^ suffix
	| TInst (klass,params) ->  (class_string klass suffix params)
	| TType (type_def,params) ->
		(match type_def.t_path with
		| [] , "Null" ->
			(match params with
			| [t] ->
				(match follow t with
				| TInst ({ cl_path = [],"Int" },_)
				| TInst ({ cl_path = [],"Float" },_)
				| TEnum ({ e_path = [],"Bool" },_) -> "Dynamic"
				| _ -> type_string_suff suffix t)
			| _ -> assert false);
		| [] , "Array" ->
			(match params with
			| [t] -> "Array<" ^ (type_string (follow t) ) ^ " >"
			| _ -> assert false)
		| _ ->  type_string_suff suffix (apply_params type_def.t_types params type_def.t_type)
		)
	| TFun (args,haxe_type) -> "Dynamic"
	| TAnon anon -> "Dynamic"
	| TDynamic haxe_type -> "Dynamic"
	| TLazy func -> type_string_suff suffix ((!func)())
	)
and type_string haxe_type = 
	type_string_suff "" haxe_type;;

let debug_expression expression type_too =
	"/* " ^
	(match expression.eexpr with
	| TConst _ -> "TConst"
	| TLocal _ -> "TLocal"
	| TEnumField _ -> "TEnumField"
	| TArray (_,_) -> "TArray"
	| TBinop (_,_,_) -> "TBinop"
	| TField (_,_) -> "TField"
	| TClosure _ -> "TClosure"
	| TTypeExpr _ -> "TTypeExpr"
	| TParenthesis _ -> "TParenthesis"
	| TObjectDecl _ -> "TObjectDecl"
	| TArrayDecl _ -> "TArrayDecl"
	| TCall (_,_) -> "TCall"
	| TNew (_,_,_) -> "TNew"
	| TUnop (_,_,_) -> "TUnop"
	| TFunction _ -> "TFunction"
	| TVars _ -> "TVars"
	| TBlock _ -> "TBlock"
	| TFor (_,_,_,_) -> "TFor"
	| TIf (_,_,_) -> "TIf"
	| TWhile (_,_,_) -> "TWhile"
	| TSwitch (_,_,_) -> "TSwitch"
	| TMatch (_,_,_,_) -> "TMatch"
	| TTry (_,_) -> "TTry"
	| TReturn _ -> "TReturn"
	| TBreak -> "TBreak"
	| TContinue -> "TContinue"
	| TThrow _ -> "TThrow" ) ^
	(if (type_too) then " = " ^ (type_string expression.etype) else "") ^
	" */";;

let rec escphp n =
	if n = 0 then "" else if n = 1 then "\\" else ("\\\\" ^ escphp (n-1))

let rec register_extern_required_path ctx path = 
	if (List.exists(fun p -> p = path) ctx.extern_classes_with_init) && not (List.exists(fun p -> p = path) ctx.extern_required_paths) then
		ctx.extern_required_paths <- path :: ctx.extern_required_paths
		
let s_expr_expr e =
	match e.eexpr with
	| TConst _ -> "TConst"
	| TLocal _ -> "TLocal"
	| TEnumField _ -> "TEnumField"
	| TArray (_,_) -> "TArray"
	| TBinop (_,_,_) -> "TBinop"
	| TField (_,_) -> "TField"
	| TClosure (_,_) -> "TClosure"
	| TTypeExpr _ -> "TTypeExpr"
	| TParenthesis _ -> "TParenthesis"
	| TObjectDecl _ -> "TObjectDecl"
	| TArrayDecl _ -> "TArrayDecl"
	| TCall (_,_) -> "TCall"
	| TNew (_,_,_) -> "TNew"
	| TUnop (_,_,_) -> "TUnop"
	| TFunction _ -> "TFunction"
	| TVars _ -> "TVars"
	| TBlock _ -> "TBlock"
	| TFor (_,_,_,_) -> "TFor"
	| TIf (_,_,_) -> "TIf"
	| TWhile (_,_,_) -> "TWhile"
	| TSwitch (_,_,_) -> "TSwitch"
	| TMatch (_,_,_,_) -> "TMatch"
	| TTry (_,_) -> "TTry"
	| TReturn _ -> "TReturn"
	| TBreak -> "TBreak"
	| TContinue -> "TContinue"
	| TThrow _ -> "TThrow"

let s_expr_name e =
	s_type (print_context()) e.etype

let s_type_name t =
	s_type (print_context()) t
	
let rec is_uncertain_type t =
	match follow t with
	| TInst (c, _) -> c.cl_interface
	| TMono _ -> true
	| TAnon a ->
	  (match !(a.a_status) with
	  | Statics _
	  | EnumStatics _ -> false
	  | _ -> true)
	| TDynamic _ -> true
	| _ -> false

let is_uncertain_expr e =
	is_uncertain_type e.etype

let rec is_anonym_type t =
	match follow t with
	| TAnon a ->
	  (match !(a.a_status) with
	  | Statics _
	  | EnumStatics _ -> false
	  | _ -> true)
	| TDynamic _ -> true
	| _ -> false

let is_anonym_expr e = is_anonym_type e.etype

let rec is_unknown_type t =
	match follow t with
	| TMono r ->
		(match !r with
		| None -> true
		| Some t -> is_unknown_type t)
	| _ -> false

let is_unknown_expr e =	is_unknown_type e.etype

let rec is_string_type t =
	match follow t with
	| TInst ({cl_path = ([], "String")}, _) -> true
	| TAnon a ->
	   (match !(a.a_status) with
	   | Statics ({cl_path = ([], "String")}) -> true
	   | _ -> false)
	| _ -> false

let is_string_expr e = is_string_type e.etype

let spr ctx s = Buffer.add_string ctx.buf s
let print ctx = Printf.kprintf (fun s -> Buffer.add_string ctx.buf s)

let s_path ctx path isextern p =
	if isextern then begin
		register_extern_required_path ctx path;
		snd path
	end else begin
		(match path with
		| ([],"List")			-> "HList"
		| ([],name)				-> name
		| (["php"],"PhpXml__")	-> "Xml"
		| (["php"],"PhpDate__")	-> "Date"
		| (["php"],"PhpMath__")	-> "Math"
		| (pack,name) ->
			(try
				(match Hashtbl.find ctx.imports name with
				| [p] when p = pack ->
					()
				| packs ->
					if not (List.mem pack packs) then Hashtbl.replace ctx.imports name (pack :: packs))
			with Not_found ->
				Hashtbl.add ctx.imports name [pack]);
			String.concat "_" pack ^ "_" ^ name);
	end

let s_path_haxe path =
	match fst path, snd path with
	| [], s -> s
	| el, s -> String.concat "." el ^ "." ^ s

let s_ident n =
	let suf = "h" in
(*
haxe reserved words that match php ones: break, case, class, continue, default, do, else, extends, for, function, if, new, return, static, switch, var, while, interface, implements, public, private, try, catch, throw
 *)
(* PHP only (for future use): cfunction, old_function *)
	match n with
	| "and" | "or" | "xor" | "__FILE__" | "exception" | "__LINE__" | "array"
	| "as" | "const" | "declare" | "die" | "echo"| "elseif" | "empty"
	| "enddeclare" | "endfor" | "endforeach" | "endif" | "endswitch"
	| "endwhile" | "eval" | "exit" | "foreach"| "global" | "include"
	| "include_once" | "isset" | "list" | "print" | "require" | "require_once"
	| "unset" | "use" | "__FUNCTION__" | "__CLASS__" | "__METHOD__" | "final" 
	| "php_user_filter" | "protected" | "abstract" | "__set" | "__get" | "__call"
	| "clone" -> suf ^ n
	| _ -> n
	
let s_ident_local n =
	let suf = "h" in
	match n with
	| "GLOBALS" | "_SERVER" | "_GET" | "_POST" | "_COOKIE" | "_FILES" 
	| "_ENV" | "_REQUEST" | "_SESSION" -> suf ^ n
	| _ -> n

let write_resource dir name data =
	let i = ref 0 in
	String.iter (fun c ->
		if c = '\\' || c = '/' || c = ':' || c = '*' || c = '?' || c = '"' || c = '<' || c = '>' || c = '|' then String.blit "_" 0 name !i 1;
		incr i
	) name;
	let rdir = dir ^ "/res" in
	if not (Sys.file_exists dir) then Unix.mkdir dir 0o755;
	if not (Sys.file_exists rdir) then Unix.mkdir rdir 0o755;
	let ch = open_out_bin (rdir ^ "/" ^ name) in
	output_string ch data;
	close_out ch
	
let stack_init com use_add =
	Codegen.stack_context_init com "GLOBALS['%s']" "GLOBALS['%e']" "�spos" "�tmp" use_add null_pos

let init com cwd path def_type =
	let rec create acc = function
		| [] -> ()
		| d :: l ->
			let pdir = String.concat "/" (List.rev (d :: acc)) in
			if not (Sys.file_exists pdir) then Unix.mkdir pdir 0o755;
			create (d :: acc) l
	in
	let dir = if cwd <> "" then com.file :: (cwd :: fst path) else com.file :: fst path; in
	create [] dir;
	let filename path =
		(match snd path with
		| "List" -> "HList";
		| s -> s) in
	let ch = open_out (String.concat "/" dir ^ "/" ^ (filename path) ^ (if def_type = 0 then ".class" else if def_type = 1 then ".enum"  else if def_type = 2 then ".interface" else ".extern") ^ ".php") in
	let imports = Hashtbl.create 0 in
	Hashtbl.add imports (snd path) [fst path];
	{
		com = com;
		stack = stack_init com false;
		tabs = "";
		ch = ch;
		path = path;
		buf = Buffer.create (1 lsl 14);
		in_value = None;
		in_loop = false;
		handle_break = false;
		imports = imports;
		extern_required_paths = [];
		extern_classes_with_init = [];
		curclass = null_class;
		curmethod = "";
		locals = PMap.empty;
		inv_locals = PMap.empty;
		local_types = [];
		inits = [];
		constructor_block = false;
		quotes = 0;
		dynamic_methods = [];
		all_dynamic_methods = [];
		is_call = false;
		cwd = cwd;
	}

let unsupported p = error "This expression cannot be generated to PHP" p

let newline ctx =
	match Buffer.nth ctx.buf (Buffer.length ctx.buf - 1) with
	| '}' | '{' | ':' -> print ctx "\n%s" ctx.tabs
	| _ -> print ctx ";\n%s" ctx.tabs

let rec concat ctx s f = function
	| [] -> ()
	| [x] -> f x
	| x :: l ->
		f x;
		spr ctx s;
		concat ctx s f l

let open_block ctx =
	let oldt = ctx.tabs in
	ctx.tabs <- "\t" ^ ctx.tabs;
	(fun() -> ctx.tabs <- oldt)

let parent e =
	match e.eexpr with
	| TParenthesis _ -> e
	| _ -> mk (TParenthesis e) e.etype e.epos

let inc_extern_path ctx path =
	let rec slashes n =
		if n = 0 then "" else ("../" ^ slashes (n-1))
	in
	let pre = if ctx.cwd = "" then "lib/" else "" in
	match path with
		| ([],name) ->
		pre ^ (slashes (List.length (fst ctx.path))) ^ name ^ ".extern.php"
		| (pack,name) ->
		pre ^ (slashes (List.length (fst ctx.path))) ^ String.concat "/" pack ^ "/" ^ name ^ ".extern.php"
	
let close ctx =
	output_string ctx.ch "<?php\n";
	List.iter (fun path ->
		if path <> ctx.path then output_string ctx.ch ("require_once dirname(__FILE__).'/" ^ inc_extern_path ctx path ^ "';\n");
	) (List.rev ctx.extern_required_paths);
	output_string ctx.ch "\n";
	output_string ctx.ch (Buffer.contents ctx.buf);
	close_out ctx.ch

let save_locals ctx =
	let old = ctx.locals in
	(fun() -> ctx.locals <- old)

let define_local ctx l =
	let rec loop n =
	let name = (if n = 1 then s_ident_local l else s_ident_local (l ^ string_of_int n)) in
	if PMap.mem name ctx.inv_locals then
		loop (n+1)
	else begin
		ctx.locals <- PMap.add l name ctx.locals;
		ctx.inv_locals <- PMap.add name l ctx.inv_locals;
		name
	end
	in
	loop 1

let rec iter_switch_break in_switch e =
	match e.eexpr with
	| TFunction _ | TWhile _ | TFor _ -> ()
	| TSwitch _ | TMatch _ when not in_switch -> iter_switch_break true e
	| TBreak when in_switch -> raise Exit
	| _ -> iter (iter_switch_break in_switch) e

let handle_break ctx e =
	let old = ctx.in_loop, ctx.handle_break in
	ctx.in_loop <- true;
	try
		iter_switch_break false e;
		ctx.handle_break <- false;
		(fun() ->
			ctx.in_loop <- fst old;
			ctx.handle_break <- snd old;
		)
	with
		Exit ->
			spr ctx "try {";
			let b = open_block ctx in
			newline ctx;
			ctx.handle_break <- true;
			(fun() ->
				b();
				ctx.in_loop <- fst old;
				ctx.handle_break <- snd old;
				newline ctx;
				let p = escphp ctx.quotes in
				print ctx "} catch(_hx_break_exception %s$�e){}" p;
			)

let this ctx =
	let p = escphp ctx.quotes in
	if ctx.in_value <> None then (p ^ "$�this") else (p ^ "$this")

let escape_bin s quotes =
	let b = Buffer.create 0 in
	for i = 0 to String.length s - 1 do
		match Char.code (String.unsafe_get s i) with
		| c when c = Char.code('\\') or c = Char.code('"') or c = Char.code('$') ->
			Buffer.add_string b (escphp (quotes+1)); 
			Buffer.add_char b (Char.chr c)
		| c when c < 32 ->
			Buffer.add_string b (Printf.sprintf "\\x%.2X" c)
		| c -> 
			Buffer.add_char b (Char.chr c)
	done;
	Buffer.contents b

let gen_constant ctx p = function
	| TInt i -> print ctx "%ld" i
	| TFloat s -> spr ctx s
	| TString s ->
		print ctx "%s\"%s%s\"" (escphp ctx.quotes) (escape_bin (s) (ctx.quotes)) (escphp ctx.quotes)
	| TBool b -> spr ctx (if b then "true" else "false")
	| TNull -> spr ctx "null"
	| TThis -> spr ctx (this ctx)
	| TSuper -> spr ctx "ERROR /* unexpected call to super in gen_constant */"

let s_funarg ctx arg t p c =
	let byref = if (String.length arg > 7 && String.sub arg 0 7 = "byref__") then "&" else "" in
	print ctx "%s%s$%s" byref (escphp ctx.quotes) (s_ident_local arg)
(*
	(match t with
	| TInst (cl,_) ->
		(match cl.cl_path with
		| ([], "Float")
		| ([], "String")
		| ([], "Array")
		| ([], "Int")
		| ([], "Enum")
		| ([], "Class")
		| ([], "Bool") ->
			print ctx "%s%s$%s" byref (escphp ctx.quotes) arg;
		| _ ->
			if cl.cl_kind = KNormal && not cl.cl_extern then
				print ctx "%s%s$%s" byref (escphp ctx.quotes) arg
			else begin
				print ctx "%s%s$%s" byref (escphp ctx.quotes) arg;
			end)
	| _ ->
		print ctx "%s%s$%s" byref (escphp ctx.quotes) arg;
	)
*)

let is_in_dynamic_methods ctx e s =
	List.exists (fun dm ->
		(* TODO: I agree, this is a mess ... but after hours of trials and errors I gave up; maybe in a calmer day *)
		((String.concat "." ((fst dm.mpath) @ ["#" ^ (snd dm.mpath)])) ^ "." ^ dm.mname) = (s_type_name e.etype ^ "." ^ s)
	) ctx.all_dynamic_methods

let is_dynamic_method f =
	(match f.cf_set with
		| NormalAccess -> true
		| MethodAccess true -> true
		| _ -> false)
		
let fun_block ctx f p =
	let e = (match f.tf_expr with { eexpr = TBlock [{ eexpr = TBlock _ } as e] } -> e | e -> e) in
	let e = List.fold_left (fun e (a,c,t) ->
		match c with
		| None | Some TNull -> e
		| Some c -> Codegen.concat (Codegen.set_default ctx.com a c t p) e
	) e f.tf_args in
	if ctx.com.debug then begin
		Codegen.stack_block ctx.stack ctx.curclass ctx.curmethod e
	end else 
		mk_block e

let gen_function_header ctx name f params p =
	let old = ctx.in_value in
	let old_l = ctx.locals in
	let old_li = ctx.inv_locals in
	let old_t = ctx.local_types in
	ctx.in_value <- None;
	ctx.local_types <- List.map snd params @ ctx.local_types;
	(match name with
	| None ->
		spr ctx "create_function('";
		concat ctx ", " (fun (arg,o,t) ->
		let arg = define_local ctx arg in
			s_funarg ctx arg t p o;
		) f.tf_args;
		print ctx "', '') "
	| Some n ->
		let byref = if (String.length n > 9 && String.sub n 0 9 = "__byref__") then "&" else "" in
		print ctx "function %s%s(" byref n;
		concat ctx ", " (fun (arg,o,t) ->
		let arg = define_local ctx arg in
			s_funarg ctx arg t p o;
		) f.tf_args;
		print ctx ") ");
	(fun () ->
		ctx.in_value <- old;
		ctx.locals <- old_l;
		ctx.inv_locals <- old_li;
		ctx.local_types <- old_t;
	)

let s_escape_php_vars ctx code =
	String.concat ((escphp ctx.quotes) ^ "$") (ExtString.String.nsplit code "$")

let rec gen_array_args ctx lst =
	match lst with
	| [] -> ()
	| h :: t ->
		spr ctx "[";
		gen_value ctx h;
		spr ctx "]";				
		gen_array_args ctx t
		
and gen_call ctx e el =
	let rec genargs lst =
		(match lst with
		| [] -> ()
		| h :: [] ->
			spr ctx " = ";
			gen_value ctx h;
		| h :: t ->
			spr ctx "[";
			gen_value ctx h;
			spr ctx "]";
			genargs t)
	in
	match e.eexpr , el with
	| TConst TSuper , params ->
		(match ctx.curclass.cl_super with
		| None -> assert false
		| Some (c,_) ->
			spr ctx "parent::__construct(";
			concat ctx "," (gen_value ctx) params;
			spr ctx ")";
		);
	| TField ({ eexpr = TConst TSuper },name) , params ->
		(match ctx.curclass.cl_super with
		| None -> assert false
		| Some (c,_) ->
			print ctx "parent::%s(" (name);
			concat ctx "," (gen_value ctx) params;
			spr ctx ")";
		);
	| TLocal "__set__" , { eexpr = TConst (TString code) } :: el ->
		print ctx "%s$%s" (escphp ctx.quotes) code;
		genargs el;
	| TLocal "__set__" , e :: el ->
		gen_value ctx e;
		genargs el;
	| TLocal "__setfield__" , e :: (f :: el) ->
		gen_value ctx e;
		spr ctx "->{";
		gen_value ctx f;
		spr ctx "}";
		genargs el;
	| TLocal "__field__" , e :: (f :: el) ->
		gen_value ctx e;
		spr ctx "->";
		gen_value ctx f;
		gen_array_args ctx el;
	| TLocal "__var__" , { eexpr = TConst (TString code) } :: el ->
		print ctx "%s$%s" (escphp ctx.quotes) code;
		gen_array_args ctx el;
	| TLocal "__var__" , e :: el ->
		gen_value ctx e;
		gen_array_args ctx el;
	| TLocal "__call__" , { eexpr = TConst (TString code) } :: el ->
		spr ctx code;
		spr ctx "(";
		concat ctx ", " (gen_value ctx) el;
		spr ctx ")";
	| TLocal "__php__", [{ eexpr = TConst (TString code) }] ->
		spr ctx (s_escape_php_vars ctx code)
	| TLocal "__physeq__" ,  [e1;e2] ->
		gen_value ctx e1;
		spr ctx " === ";
		gen_value ctx e2
	| TLocal _, el
	| TFunction _, el ->
		ctx.is_call <- true;
		spr ctx "call_user_func_array(";
		gen_value ctx e;
		ctx.is_call <- false;
		spr ctx ", array(";
		concat ctx ", " (gen_value ctx) el;
		spr ctx "))"
	| TCall (x,_), el when (match x.eexpr with | TLocal _ -> false | _ -> true) ->
		ctx.is_call <- true;
		spr ctx "call_user_func_array(";
		gen_value ctx e;
		ctx.is_call <- false;
		spr ctx ", array(";
		concat ctx ", " (gen_value ctx) el;
		spr ctx "))"
	| TBlock _, el ->
		ctx.is_call <- true;
		spr ctx "call_user_func_array(";
		gen_value ctx e;
		ctx.is_call <- false;
		spr ctx ", array(";
		concat ctx ", " (gen_value ctx) el;
		spr ctx "))"
(*
	| TField (ex,name), el ->
		spr ctx (debug_expression ex true);
		ctx.is_call <- true;
		spr ctx "call_user_func_array(";
		gen_value ctx e;
		ctx.is_call <- false;
		spr ctx ", array(";
		concat ctx ", " (gen_value ctx) el;
		spr ctx "))"
*)
	| _ ->
		ctx.is_call <- true;
		gen_value ctx e;
		ctx.is_call <- false;
		spr ctx "(";
		concat ctx ", " (gen_value ctx) el;
		spr ctx ")";

and could_be_string_var s =
	s = "length"

and gen_uncertain_string_var ctx s e =
	match s with
	| "length" ->
		spr ctx "_hx_len(";
		gen_value ctx e;
		spr ctx ")"
	| _ ->
		gen_field_access ctx true e s;

and gen_string_var ctx s e =
	match s with
	| "length" ->
		spr ctx "strlen(";
		gen_value ctx e;
		spr ctx ")"
	| _ ->
		unsupported e.epos;

and gen_string_static_call ctx s e el =
	match s with
	| "fromCharCode" ->
		spr ctx "chr(";
		concat ctx ", " (gen_value ctx) el;
		spr ctx ")";
	| _ -> unsupported e.epos;

and could_be_string_call s =
	s = "substr" || s = "charAt" || s = "charCodeAt" || s = "indexOf" ||
	s = "lastIndexOf" || s = "split" || s = "toLowerCase" || s = "toString" || s = "toUpperCase"

and gen_string_call ctx s e el =
	match s with
	| "substr" ->
		spr ctx "_hx_substr(";
		gen_value ctx e;
		spr ctx ", ";
		concat ctx ", " (gen_value ctx) el;
		spr ctx ")"
	| "charAt" ->
		spr ctx "substr(";
		gen_value ctx e;
		spr ctx ", ";
		concat ctx ", " (gen_value ctx) el;
		spr ctx ", 1)"
	| "cca" ->
		spr ctx "ord(";
		gen_value ctx e;
		spr ctx "{";
		concat ctx ", " (gen_value ctx) el;
		spr ctx "})"
	| "charCodeAt" ->
		spr ctx "_hx_char_code_at(";
		gen_value ctx e;
		spr ctx ", ";
		concat ctx ", " (gen_value ctx) el;
		spr ctx ")"
	| "indexOf" ->
		spr ctx "_hx_index_of(";
		gen_value ctx e;
		spr ctx ", ";
		concat ctx ", " (gen_value ctx) el;
		spr ctx ")"
	| "lastIndexOf" ->
		spr ctx "_hx_last_index_of(";
		gen_value ctx e;
		spr ctx ", ";
		concat ctx ", " (gen_value ctx) el;
		spr ctx ")"
	| "split" ->
		spr ctx "_hx_explode(";
		concat ctx ", " (gen_value ctx) el;
		spr ctx ", ";
		gen_value ctx e;
		spr ctx ")"
	| "toLowerCase" ->
		spr ctx "strtolower(";
		gen_value ctx e;
		spr ctx ")"
	| "toUpperCase" ->
		spr ctx "strtoupper(";
		gen_value ctx e;
		spr ctx ")"
	| "toString" ->
		gen_value ctx e;
	| _ ->
		unsupported e.epos;

and gen_uncertain_string_call ctx s e el =
	let p = escphp ctx.quotes in
	spr ctx "_hx_string_call(";
	gen_value ctx e;
	print ctx ", %s\"%s%s\", array(" p s p;
	concat ctx ", " (gen_value ctx) el;
	spr ctx "))"

and gen_field_op ctx e =
	match e.eexpr with
	| TField (f,s) ->
		(match follow e.etype with
		| TFun _ ->
			gen_field_access ctx true f s
		| _ ->
			gen_value_op ctx e)
	| _ ->
		gen_value_op ctx e

and gen_value_op ctx e =
	match e.eexpr with
	| TBinop (op,_,_) when op = Ast.OpAnd || op = Ast.OpOr || op = Ast.OpXor ->
		spr ctx "(";
		gen_value ctx e;
		spr ctx ")";
	| _ ->
		gen_value ctx e

and is_static t =
	match follow t with
	| TAnon a -> (match !(a.a_status) with
		| Statics c -> true
		| _ -> false)
	| _ -> false

and gen_member_access ctx isvar e s =
	match follow e.etype with
	| TAnon a ->
		(match !(a.a_status) with
		| EnumStatics _
		| Statics _ -> print ctx "::%s%s" (if isvar then ((escphp ctx.quotes) ^ "$") else "") (s_ident s)
		| _ -> print ctx "->%s" (s_ident s))
	| _ -> print ctx "->%s" (s_ident s)

and gen_field_access ctx isvar e s =
	match e.eexpr with
	| TTypeExpr t ->
		spr ctx (s_path ctx (t_path t) false e.epos);
		gen_member_access ctx isvar e s
	| TLocal _ ->
		gen_expr ctx e;
		print ctx "->%s" (s_ident s)
	| TArray (e1,e2) ->
		spr ctx "_hx_array_get(";
		gen_value ctx e1;
		spr ctx ", ";
		gen_value ctx e2;
		spr ctx ")";
		gen_member_access ctx isvar e s
	| TBlock _
	| TParenthesis _
	| TObjectDecl _
	| TArrayDecl _
	| TNew _ ->
		spr ctx "_hx_deref(";
		ctx.is_call <- true;
		gen_value ctx e;
		ctx.is_call <- false;
		spr ctx ")";
		gen_member_access ctx isvar e s
	| _ ->
		gen_expr ctx e;
		gen_member_access ctx isvar e s

and gen_dynamic_function ctx isstatic name f params p =
	let old = ctx.in_value in
	let old_l = ctx.locals in
	let old_li = ctx.inv_locals in
	let old_t = ctx.local_types in
	ctx.in_value <- None;
	ctx.local_types <- List.map snd params @ ctx.local_types;
	let byref = if (String.length name > 9 && String.sub name 0 9 = "__byref__") then "&" else "" in
	print ctx "function %s%s(" byref name;
	concat ctx ", " (fun (arg,o,t) ->
	let arg = define_local ctx arg in
		s_funarg ctx arg t p o;
		) f.tf_args;
	spr ctx ") {";

	if (List.length f.tf_args) > 0 then begin
		if isstatic then
			print ctx " return call_user_func_array(self::$%s, array("  name
		else
			print ctx " return call_user_func_array($this->%s, array("  name;
		concat ctx ", " (fun (arg,o,t) ->
			spr ctx ((escphp ctx.quotes) ^ "$" ^ arg)
		) f.tf_args;
		print ctx ")); }";
	end else if isstatic then
		print ctx " return call_user_func(self::$%s); }"  name
	else
		print ctx " return call_user_func($this->%s); }"  name;

	newline ctx;
	if isstatic then
		print ctx "public static $%s = null" name
	else
		print ctx "public $%s = null" name;
	ctx.in_value <- old;
	ctx.locals <- old_l;
	ctx.inv_locals <- old_li;
	ctx.local_types <- old_t

and gen_function ctx name f params p =
	let old = ctx.in_value in
	let old_l = ctx.locals in
	let old_li = ctx.inv_locals in
	let old_t = ctx.local_types in
	ctx.in_value <- None;
	ctx.local_types <- List.map snd params @ ctx.local_types;
	let byref = if (String.length name > 9 && String.sub name 0 9 = "__byref__") then "&" else "" in
	print ctx "function %s%s(" byref name;
	concat ctx ", " (fun (arg,o,t) ->
		let arg = define_local ctx arg in
		s_funarg ctx arg t p o;
	) f.tf_args;
	print ctx ") ";
	gen_expr ctx (fun_block ctx f p);
	ctx.in_value <- old;
	ctx.locals <- old_l;
	ctx.inv_locals <- old_li;
	ctx.local_types <- old_t

	
and gen_inline_function ctx f params p =
	let old = ctx.in_value in
	let old_l = ctx.locals in
	let old_li = ctx.inv_locals in
	let old_t = ctx.local_types in
	ctx.in_value <- Some "closure";
	ctx.local_types <- List.map snd params @ ctx.local_types;

	spr ctx "array(new _hx_lambda(array(";

	let pq = escphp ctx.quotes in
	let c = ref 0 in

	PMap.iter (fun n _ ->
		if !c > 0 then spr ctx ", ";
		incr c;
		print ctx "%s\"%s%s\" => &%s$%s" pq n pq pq n;
	) old_li;

	print ctx "), null, array(";
	let cargs = ref 0 in
	concat ctx "," (fun (arg,o,t) ->
		let arg = define_local ctx arg in
		print ctx "'%s'" arg;
		incr cargs;
	) f.tf_args;
	print ctx "), %s\"" pq;
	ctx.quotes <- ctx.quotes + 1;
	gen_expr ctx (fun_block ctx f p);
	ctx.quotes <- ctx.quotes - 1;
	print ctx "%s\"), 'execute%d')" pq !cargs;
	ctx.in_value <- old;
	ctx.locals <- old_l;
	ctx.inv_locals <- old_li;
	ctx.local_types <- old_t

and gen_while_expr ctx e =
	match e.eexpr with
	| TBlock (el) ->	
		let old_l = ctx.inv_locals in
		let b = save_locals ctx in
		print ctx "{";
		let bend = open_block ctx in
		List.iter (fun e -> newline ctx; gen_expr ctx e) el;
		newline ctx;
		let lst = ref [] in
		PMap.iter (fun n _ ->
		    if not (PMap.exists n old_l) then
				lst := [(escphp ctx.quotes) ^ "$" ^  n] @ !lst;
		) ctx.inv_locals;
		
		if (List.length !lst) > 0 then begin
			spr ctx "unset(";
			concat ctx "," (fun (s) -> spr ctx s; ) !lst;
			spr ctx ")"
		end;
		
		bend();
		newline ctx;
		print ctx "}";
		b();
	| _ ->
		gen_expr ctx e

and gen_expr ctx e =
	match e.eexpr with
	| TConst c ->
		gen_constant ctx e.epos c
	| TLocal s ->
		spr ctx ((escphp ctx.quotes) ^ "$" ^ (try PMap.find s ctx.locals with Not_found -> (s_ident_local s)))
(*		spr ctx ((escphp ctx.quotes) ^ "$" ^ (s_ident_local s)) *)
	| TEnumField (en,s) ->
		(match (try PMap.find s en.e_constrs with Not_found -> error ("Unknown local " ^ s) e.epos).ef_type with
		| TFun (args,_) -> print ctx "%s::%s" (s_path ctx en.e_path en.e_extern e.epos) (s_ident s)
		| _ -> print ctx "%s::%s$%s" (s_path ctx en.e_path en.e_extern e.epos) (escphp ctx.quotes) (s_ident s))
	| TArray (e1,e2) ->
		(match e1.eexpr with
		| TCall _ ->
			spr ctx "_hx_array_get(";
			gen_value ctx e1;
			spr ctx ", ";
			gen_value ctx e2;
			spr ctx ")";
		| _ ->
			gen_value ctx e1;
			spr ctx "[";
			gen_value ctx e2;
			spr ctx "]");
	| TBinop (op,e1,e2) ->
		let leftside e =
			(match e.eexpr with
			| TArray(te1, te2) ->
				gen_value ctx te1;
				spr ctx "->�a[";
				gen_value ctx te2;
				spr ctx "]";
			| _ ->
				gen_field_op ctx e1;) in
		let leftsidec e =
			(match e.eexpr with
			| TArray(te1, te2) ->
				gen_value ctx te1;
				spr ctx "->�a[";
				gen_value ctx te2;
				spr ctx "]";
			| TField (e1,s) ->
				gen_field_access ctx true e1 s
			| _ ->
				gen_field_op ctx e1;) in
		let leftsidef e =
			(match e.eexpr with
			| TField (e1,s) ->
				gen_field_access ctx true e1 s;
			| _ ->
				gen_field_op ctx e1;
				) in
		(match op with
		| Ast.OpAssign ->
			(match e1.eexpr with
			| TArray(te1, te2) when (match te1.eexpr with TCall _ -> true | _ -> false) ->
				spr ctx "_hx_array_assign(";
				gen_value ctx te1;
				spr ctx ", ";
				gen_value ctx te2;
				spr ctx ", ";
				gen_value_op ctx e2;
				spr ctx ")";
			| _ ->
				leftsidef e1;
				spr ctx " = ";
				gen_value_op ctx e2;)
		| Ast.OpAssignOp(Ast.OpAdd) when (is_uncertain_expr e1 && is_uncertain_expr e2) ->
			leftside e1;
			spr ctx " = ";
			spr ctx "_hx_add(";
			gen_value_op ctx e1;
			spr ctx ", ";
			gen_value_op ctx e2;
			spr ctx ")";
		| Ast.OpAssignOp(Ast.OpAdd) when (is_string_expr e1 || is_string_expr e2) ->
			leftside e1;
			spr ctx " .= ";
			gen_value_op ctx e2;
		| Ast.OpAssignOp(Ast.OpShl) ->
			leftside e1;
			spr ctx " <<= ";
			gen_value_op ctx e2;
		| Ast.OpAssignOp(Ast.OpUShr) ->
			leftside e1;
			spr ctx " = ";
			spr ctx "_hx_shift_right(";
			gen_value_op ctx e1;
			spr ctx ", ";
			gen_value_op ctx e2;
			spr ctx ")";
		| Ast.OpAssignOp(_) ->
			leftsidec e1;
			print ctx " %s " (Ast.s_binop op);
			gen_value_op ctx e2;
		| Ast.OpAdd when (is_uncertain_expr e1 && is_uncertain_expr e2) ->
			spr ctx "_hx_add(";
			gen_value_op ctx e1;
			spr ctx ", ";
			gen_value_op ctx e2;
			spr ctx ")";
		| Ast.OpAdd when (is_string_expr e1 || is_string_expr e2) ->
			gen_value_op ctx e1;
			spr ctx " . ";
			gen_value_op ctx e2;
		| Ast.OpShl ->
			gen_value_op ctx e1;
			spr ctx " << ";
			gen_value_op ctx e2;
		| Ast.OpUShr ->
			spr ctx "_hx_shift_right(";
			gen_value_op ctx e1;
			spr ctx ", ";
			gen_value_op ctx e2;
			spr ctx ")";
		| Ast.OpNotEq
		| Ast.OpEq ->
			let s_op = if op = Ast.OpNotEq then " != " else " == " in
			let s_phop = if op = Ast.OpNotEq then " !== " else " === " in
			let se1 = s_expr_name e1 in
			let se2 = s_expr_name e2 in
			let p = escphp ctx.quotes in
			if
				e1.eexpr = TConst (TNull)
				|| e2.eexpr = TConst (TNull)
			then begin
				(match e1.eexpr with
				| TField (f, s) when is_anonym_expr e1 || is_unknown_expr e1 ->
					spr ctx "_hx_field(";
					gen_value ctx f;
					print ctx ", %s\"%s%s\")" p s p;
				| _ ->
					gen_field_op ctx e1);

				spr ctx s_phop;

				(match e2.eexpr with
				| TField (f, s) when is_anonym_expr e2 || is_unknown_expr e2 ->
					spr ctx "_hx_field(";
					gen_value ctx f;
					print ctx ", %s\"%s%s\")" p s p;
				| _ ->
					gen_field_op ctx e2);
			end else if
					((se1 = "Int" || se1 = "Null<Int>") && (se2 = "Int" || se2 = "Null<Int>"))
					|| ((se1 = "Float" || se1 = "Null<Float>") && (se2 = "Float" || se2 = "Null<Float>"))
			then begin
				gen_field_op ctx e1;
				spr ctx s_phop;
				gen_field_op ctx e2;
			end else if
				   ((se1 = "Int" || se1 = "Float" || se1 = "Null<Int>" || se1 = "Null<Float>")
				   && (se1 = "Int" || se1 = "Float" || se1 = "Null<Int>" || se1 = "Null<Float>"))
				|| (is_unknown_expr e1 && is_unknown_expr e2)
				|| is_anonym_expr e1
				|| is_anonym_expr e2
			then begin
				if op = Ast.OpNotEq then spr ctx "!";
				spr ctx "_hx_equal(";
				gen_field_op ctx e1;
				spr ctx ", ";
				gen_field_op ctx e2;
				spr ctx ")";
			end else if
				   is_string_expr e1
				&& is_string_expr e2
			then begin
				gen_field_op ctx e1;
				spr ctx s_op;
				gen_field_op ctx e2;
			end else if
				   se1 == se2
				|| (match e1.eexpr with | TConst _ | TLocal _ | TArray _  | TNew _ -> true | _ -> false)
				|| (match e2.eexpr with | TConst _ | TLocal _ | TArray _  | TNew _ -> true | _ -> false)
				|| is_string_expr e1
				|| is_string_expr e2
				|| is_anonym_expr e1
				|| is_anonym_expr e2
				|| is_unknown_expr e1
				|| is_unknown_expr e2
			then begin
				gen_field_op ctx e1;
				spr ctx s_phop;
				gen_field_op ctx e2;
			end else begin
				gen_field_op ctx e1;
				spr ctx s_op;
				gen_field_op ctx e2;
			end
		| _ ->
			leftside e1;
			print ctx " %s " (Ast.s_binop op);
			gen_value_op ctx e2;
		);
	| TField (e1,s) | TClosure (e1,s) ->
		(match follow e.etype with
		| TFun (args, _) ->
			let p = escphp ctx.quotes in
			(if ctx.is_call then begin
				gen_field_access ctx false e1 s
	  		end else if is_in_dynamic_methods ctx e1 s then begin
	  			gen_field_access ctx true e1 s;
	  		end else begin
				let ob ex = 
					(match ex with
					| TTypeExpr t ->
						print ctx "%s\"" p;
						spr ctx (s_path ctx (t_path t) false e1.epos);
						print ctx "%s\"" p
					| _ -> 
						gen_expr ctx e1) in
				
				spr ctx "isset(";
				gen_field_access ctx true e1 s;
				spr ctx ") ? ";
				gen_field_access ctx true e1 s;
				spr ctx ": array(";
				ob e1.eexpr;
				print ctx ", %s\"%s%s\")" p s p;
				
			end)
		| TMono _ ->
			if ctx.is_call then
				gen_field_access ctx false e1 s
			else
				gen_uncertain_string_var ctx s e1
		| _ ->
			if is_string_expr e1 then
				gen_string_var ctx s e1
			else if is_uncertain_expr e1 then
				gen_uncertain_string_var ctx s e1
			else
				gen_field_access ctx true e1 s
		)

	| TTypeExpr t ->
		let p = escphp ctx.quotes in
		print ctx "_hx_qtype(%s\"%s%s\")" p (s_path_haxe (t_path t)) p
	| TParenthesis e ->
		spr ctx "(";
		gen_value ctx e;
		spr ctx ")";
	| TReturn eo ->
		(match eo with
		| None ->
			spr ctx "return"
		| Some e when (match follow e.etype with TEnum({ e_path = [],"Void" },[]) -> true | _ -> false) ->
			gen_value ctx e;
			newline ctx;
			spr ctx "return"
		| Some e ->
			spr ctx "return ";
			gen_value ctx e;
			);
	| TBreak ->
		if not ctx.in_loop then unsupported e.epos;
		if ctx.handle_break then spr ctx "throw new _hx_break_exception()" else spr ctx "break"
	| TContinue ->
		if not ctx.in_loop then unsupported e.epos;
		spr ctx "continue"
	| TBlock [] ->
		spr ctx ""
	| TBlock el ->
		let b = save_locals ctx in
		print ctx "{";
		let bend = open_block ctx in
		let cb = (
			if not ctx.constructor_block then
				(fun () -> ())
			else begin
				ctx.constructor_block <- false;
				if List.length ctx.dynamic_methods > 0 then newline ctx else spr ctx " ";
				List.iter (fun (f) ->
					let name = f.cf_name in
					match f.cf_expr with
					| Some { eexpr = TFunction fd } ->
						print ctx "if(!isset($this->%s)) $this->%s = array(new _hx_lambda(array(), $this, array(" name name;
						let cargs = ref 0 in
						concat ctx "," (fun (arg,o,t) ->
							let arg = define_local ctx arg in
							print ctx "'%s'" arg;
							incr cargs;
						) fd.tf_args;
						print ctx "), \"";
						let old = ctx.in_value in
						ctx.in_value <- Some name;
						ctx.quotes <- ctx.quotes + 1;
						gen_expr ctx (fun_block ctx fd e.epos);
						ctx.quotes <- ctx.quotes - 1;
						ctx.in_value <- old;
						print ctx "\"), 'execute%d')" !cargs;
						newline ctx;
					| _ -> ()
				) ctx.dynamic_methods;
				if Codegen.constructor_side_effects e then begin
					print ctx "if( !%s::$skip_constructor ) {" (s_path ctx (["php"],"Boot") false e.epos);
					(fun() -> print ctx "}";
					
					
					)
				end else
					(fun() -> ());
			end) in
		List.iter (fun e -> newline ctx; gen_expr ctx e) el;
		bend();
		newline ctx;
		cb();
		print ctx "}";
		b();
	| TFunction f ->
		let old = ctx.in_value, ctx.in_loop in
		let old_meth = ctx.curmethod in
		ctx.in_value <- None;
		ctx.in_loop <- false;
		ctx.curmethod <- ctx.curmethod ^ "@" ^ string_of_int (Lexer.find_line_index ctx.com.lines e.epos);
		gen_inline_function ctx f [] e.epos;
		ctx.curmethod <- old_meth;
		ctx.in_value <- fst old;
		ctx.in_loop <- snd old;
	| TCall (ec,el) ->
		(match ec.eexpr with
		| TArray _ ->
			spr ctx "call_user_func_array(";
			gen_value ctx ec;
			spr ctx ", array(";
			concat ctx ", " (gen_value ctx) el;
			spr ctx "))";
		| TField (ef,s) when is_static ef.etype && is_string_expr ef ->
			gen_string_static_call ctx s ef el
		| TField (ef,s) when is_string_expr ef ->
			gen_string_call ctx s ef el
		| TField (ef,s) when is_anonym_expr ef && could_be_string_call s ->
			gen_uncertain_string_call ctx s ef el
		| _ ->
			gen_call ctx ec el);
	| TArrayDecl el ->
		spr ctx "new _hx_array(array(";
		concat ctx ", " (gen_value ctx) el;
		spr ctx "))";
	| TThrow e ->
		spr ctx "throw new HException(";
		gen_value ctx e;
		spr ctx ")";
	| TVars [] ->
		()
	| TVars vl ->
		spr ctx ((escphp ctx.quotes) ^ "$");
		concat ctx ("; " ^ (escphp ctx.quotes) ^ "$") (fun (n,t,v) ->
			let n = define_local ctx n in
			match v with
			| None -> 
				print ctx "%s = null" (s_ident_local n)
			| Some e ->
				print ctx "%s = " (s_ident_local n);
				gen_value ctx e
		) vl;
	| TNew (c,_,el) ->
		(match c.cl_path, el with
		| ([], "String"), _ ->
			concat ctx "" (gen_value ctx) el
		| ([], "Array"), el ->
			spr ctx "new _hx_array(array(";
			concat ctx ", " (gen_value ctx) el;
			spr ctx "))"
		| (_, _), _ ->
			print ctx "new %s(" (s_path ctx c.cl_path c.cl_extern e.epos);
			let count = ref (-1) in
			concat ctx ", " (fun e ->
				incr count;
				match c.cl_constructor with
				| Some f ->
					gen_value ctx e;
				| _ -> ();
			) el;
			spr ctx ")")
	| TIf (cond,e,eelse) ->
		spr ctx "if";
		gen_value ctx (parent cond);
		spr ctx " ";
		gen_expr ctx (mk_block e);
		(match eelse with
		| None -> ()
		| Some e when e.eexpr = TConst(TNull) -> ()
		| Some e ->
			newline ctx;
			spr ctx "else ";
			gen_expr ctx (mk_block e));
	| TUnop (op,Ast.Prefix,e) ->
		spr ctx (Ast.s_unop op);
		(match e.eexpr with
		| TArray(te1, te2) ->
			gen_value ctx te1;
			spr ctx "->�a[";
			gen_value ctx te2;
			spr ctx "]";
		| TField (e1,s) ->
			gen_field_access ctx true e1 s
		| _ ->
			gen_value ctx e)
	| TUnop (op,Ast.Postfix,e) ->
		(match e.eexpr with
		| TArray(te1, te2) ->
			gen_value ctx te1;
			spr ctx "->�a[";
			gen_value ctx te2;
			spr ctx "]";
		| TField (e1,s) ->
			gen_field_access ctx true e1 s
		| _ ->
			gen_value ctx e);
		spr ctx (Ast.s_unop op)
	| TWhile (cond,e,Ast.NormalWhile) ->
		let handle_break = handle_break ctx e in
		spr ctx "while";
		gen_value ctx (parent cond);
		spr ctx " ";
		gen_while_expr ctx e;
		handle_break();
	| TWhile (cond,e,Ast.DoWhile) ->
		let handle_break = handle_break ctx e in
		spr ctx "do ";
		gen_while_expr ctx e;
		spr ctx " while";
		gen_value ctx (parent cond);
		handle_break();
	| TObjectDecl fields ->
		spr ctx "_hx_anonymous(array(";
		let p = escphp ctx.quotes in
		concat ctx ", " (fun (f,e) -> print ctx "%s\"%s%s\" => " p f p; gen_value ctx e) fields;
		spr ctx "))"
	| TFor (v,t,it,e) ->
		let handle_break = handle_break ctx e in
		let b = save_locals ctx in
		let tmp = define_local ctx "�it" in
		let v = define_local ctx v in
		let p = escphp ctx.quotes in
		print ctx "%s$%s = " p tmp;
		gen_value ctx it;
		newline ctx;
		print ctx "while(%s$%s->hasNext()) {" p tmp;
		newline ctx;
		print ctx "%s$%s = %s$%s->next()" p v p tmp;
		newline ctx;
		gen_while_expr ctx e;
		newline ctx;
		spr ctx "}";
		b();
		handle_break();
	| TTry (e,catchs) ->
		spr ctx "try ";
		gen_expr ctx (mk_block e);
		let ex = define_local ctx "�e" in
		print ctx "catch(Exception %s$%s) {" (escphp ctx.quotes) ex;
		let p = escphp ctx.quotes in
		let first = ref true in
		let catchall = ref false in
		let evar = define_local ctx "_ex_" in
		newline ctx;
		print ctx "%s$%s = (%s$%s instanceof HException) ? %s$%s->e : %s$%s" p evar p ex p ex p ex;
		newline ctx;
		List.iter (fun (v,t,e) ->
			let ev = define_local ctx v in
			newline ctx;

			let b = save_locals ctx in
			if not !first then spr ctx "else ";
			(match follow t with
			| TEnum (te,_) -> (match snd te.e_path with
				| "Bool"   -> print ctx "if(is_bool(%s$%s = %s$%s))" p ev p evar
				| _ -> print ctx "if((%s$%s = %s$%s) instanceof %s)" p ev p evar (s_path ctx te.e_path te.e_extern e.epos));
				gen_expr ctx (mk_block e);
			| TInst (tc,_) -> (match snd tc.cl_path with
				| "Int"	-> print ctx "if(is_int(%s$%s = %s$%s))"		p ev p evar
				| "Float"  -> print ctx "if(is_numeric(%s$%s = %s$%s))"	p ev p evar
				| "String" -> print ctx "if(is_string(%s$%s = %s$%s))"	p ev p evar
				| "Array"  -> print ctx "if((%s$%s = %s$%s) instanceof _hx_array)"	p ev p evar
				| _ -> print ctx "if((%s$%s = %s$%s) instanceof %s)"    p ev p evar (s_path ctx tc.cl_path tc.cl_extern e.epos));
				gen_expr ctx (mk_block e);
			| TFun _
			| TLazy _
			| TType _
			| TAnon _ ->
				assert false
			| TMono _
			| TDynamic _ ->
				catchall := true;
				print ctx "{ %s$%s = %s$%s" p ev p evar;
				newline ctx;
				gen_expr ctx (mk_block e);
				spr ctx "}");
			b();
			first := false;
		) catchs;
		if !catchall then
			spr ctx "}"
		else
			print ctx " else throw %s$%s; }" (escphp ctx.quotes) ex;
	| TMatch (e,_,cases,def) ->
		let b = save_locals ctx in
		let tmp = define_local ctx "�t" in
		print ctx "%s$%s = " (escphp ctx.quotes) tmp;
		gen_value ctx e;
		newline ctx;
		print ctx "switch(%s$%s->index) {" (escphp ctx.quotes) tmp;
		newline ctx;
		List.iter (fun (cl,params,e) ->
			List.iter (fun c ->
				print ctx "case %d:" c;
				newline ctx;
			) cl;
			let b = save_locals ctx in
			(match params with
			| None | Some [] -> ()
			| Some l ->
				let n = ref (-1) in
				let l = List.fold_left (fun acc (v,t) -> incr n; match v with None -> acc | Some v -> (v,t,!n) :: acc) [] l in
				match l with
				| [] -> ()
				| l ->
					concat ctx "; " (fun (v,t,n) ->
						let v = define_local ctx v in
						print ctx "%s$%s = %s$%s->params[%d]" (escphp ctx.quotes) v (escphp ctx.quotes) tmp n;
					) l;
					newline ctx);
			gen_expr ctx (mk_block e);
			print ctx "break";
			newline ctx;
			b()
		) cases;
		(match def with
		| None -> ()
		| Some e ->
			spr ctx "default:";
			gen_expr ctx (mk_block e);
			print ctx "break";
			newline ctx;
		);
		spr ctx "}";
		b()
	| TSwitch (e,cases,def) ->
		spr ctx "switch";
		gen_value ctx (parent e);
		spr ctx " {";
		newline ctx;
		List.iter (fun (el,e2) ->
			List.iter (fun e ->
				spr ctx "case ";
				gen_value ctx e;
				spr ctx ":";
			) el;
			gen_expr ctx (mk_block e2);
			print ctx "break";
			newline ctx;
		) cases;
		(match def with
		| None -> ()
		| Some e ->
			spr ctx "default:";
			gen_expr ctx (mk_block e);
			print ctx "break";
			newline ctx;
		);
		spr ctx "}"

and gen_value ctx e =
	let assign e =
		mk (TBinop (Ast.OpAssign,
			mk (TLocal (match ctx.in_value with None -> assert false | Some v -> "�r")) t_dynamic e.epos,
			e
		)) e.etype e.epos
	in
	let value bl =
		let old = ctx.in_value, ctx.in_loop in
		let locs = save_locals ctx in
		let tmp = define_local ctx "�r" in
		ctx.in_value <- Some tmp;
		ctx.in_loop <- false;
		let b =
		if bl then begin
			print ctx "eval(%s\"" (escphp ctx.quotes);
			ctx.quotes <- (ctx.quotes + 1);
			let p = (escphp ctx.quotes) in
			print ctx "if(isset(%s$this)) %s$�this =& %s$this;" p p p;
			let b = open_block ctx in
			b
		end else
			(fun() -> ())
		in
		(fun() ->
			if bl then begin
				newline ctx;
				print ctx "return %s$%s" (escphp ctx.quotes) tmp;
				b();
				newline ctx;
				ctx.quotes <- (ctx.quotes - 1);
				print ctx "%s\")" (escphp ctx.quotes);
			end;
			ctx.in_value <- fst old;
			ctx.in_loop <- snd old;
			locs();
		)
	in
	match e.eexpr with
	| TTypeExpr _
	| TConst _
	| TLocal _
	| TEnumField _
	| TArray _
	| TBinop _
	| TField _
	| TClosure _
	| TParenthesis _
	| TObjectDecl _
	| TArrayDecl _
	| TCall _
	| TUnop _
	| TNew _
	| TFunction _ ->
		gen_expr ctx e
	| TReturn _
	| TBreak
	| TContinue ->
		unsupported e.epos
	| TVars _
	| TFor _
	| TWhile _
	| TThrow _ ->
		let v = value true in
		gen_expr ctx e;
		v()
	| TBlock [e] ->
		gen_value ctx e
	| TBlock el ->
		let v = value true in
		let rec loop = function
		| [] ->
			spr ctx "return null";
		| [e] ->
			gen_expr ctx (assign e);
		| e :: l ->
			gen_expr ctx e;
			newline ctx;
			loop l
		in
		loop el;
		v();
	| TIf (cond,e,eo) ->
		spr ctx "(";
		gen_value ctx cond;
		spr ctx " ? ";
		gen_value ctx e;
		spr ctx " : ";
		(match eo with
		| None -> spr ctx "null"
		| Some e -> gen_value ctx e);
		spr ctx ")"
	| TSwitch (cond,cases,def) ->
		let v = value true in
		gen_expr ctx (mk (TSwitch (cond,
			List.map (fun (e1,e2) -> (e1,assign e2)) cases,
			match def with None -> None | Some e -> Some (assign e)
		)) e.etype e.epos);
		v()
	| TMatch (cond,enum,cases,def) ->
		let v = value true in
		gen_expr ctx (mk (TMatch (cond,enum,
		List.map (fun (constr,params,e) -> (constr,params,assign e)) cases,
			match def with None -> None | Some e -> Some (assign e)
		)) e.etype e.epos);
		v()
	| TTry (b,catchs) ->
		let v = value true in
		gen_expr ctx (mk (TTry (assign b,
			List.map (fun (v,t,e) -> v, t , assign e) catchs
		)) e.etype e.epos);
		v()

let is_method_defined ctx m static =
	if static then
		PMap.exists m ctx.curclass.cl_statics
	else
		PMap.exists m ctx.curclass.cl_fields

let generate_self_method ctx rights m static setter =
	if setter then (
		if static then
			print ctx "%s function %s($v) { return call_user_func(self::$%s, $v); }" rights (s_ident m) (s_ident m)
		else
			print ctx "%s function %s($v) { return call_user_func($this->%s, $v); }" rights (s_ident m) (s_ident m)
	) else (
		if static then
			print ctx "%s function %s() { return call_user_func(self::$%s); }" rights (s_ident m) (s_ident m)
		else
			print ctx "%s function %s() { return call_user_func($this->%s); }" rights (s_ident m) (s_ident m)
	);
	newline ctx
	
let generate_field ctx static f =
	newline ctx;
	ctx.locals <- PMap.empty;
	ctx.inv_locals <- PMap.empty;
	let rights = if static then "static" else "public" in
	let p = ctx.curclass.cl_pos in
	match f.cf_expr with
	| Some { eexpr = TFunction fd } ->
		if f.cf_name = "__construct" then
			ctx.curmethod <- "new"
		else
			ctx.curmethod <- f.cf_name;
		spr ctx (rights ^ " ");
		(match f.cf_set with
		| NormalAccess
		| MethodAccess true ->
			gen_dynamic_function ctx static (s_ident f.cf_name) fd f.cf_params p
		| _ ->
			gen_function ctx (s_ident f.cf_name) fd f.cf_params p
		);
	| _ ->
		if ctx.curclass.cl_interface then
			match follow f.cf_type with
			| TFun (args,r) ->
				print ctx "function %s(" f.cf_name;
				concat ctx ", " (fun (arg,o,t) ->
					s_funarg ctx arg t p o;
				) args;
				print ctx ")";
			| _ -> spr ctx "//"; ()
		else if
			(match f.cf_get, f.cf_set with
			| CallAccess m1, CallAccess m2 ->
				if not (is_method_defined ctx m1 static) then (
					generate_self_method ctx rights m1 static false;
					print ctx "%s $%s" rights (s_ident m1);
					if not (is_method_defined ctx m2 static) then
						newline ctx);
				if not (is_method_defined ctx m2 static) then (
					generate_self_method ctx rights m2 static true;
					print ctx "%s $%s" rights (s_ident m2));
				if (is_method_defined ctx m1 static) && (is_method_defined ctx m2 static) then
					spr ctx "//";
				true
			| CallAccess m, _ ->
				if not (is_method_defined ctx m static) then generate_self_method ctx rights m static false;
				print ctx "%s $%s" rights (s_ident f.cf_name);
				true
			| _, CallAccess m ->
				if not (is_method_defined ctx m static) then generate_self_method ctx rights m static true;
				print ctx "%s $%s" rights (s_ident f.cf_name);
				true
			| _ ->
				false) then
				()
		else begin
			let name = s_ident f.cf_name in
			if static then
				(match f.cf_set with
				| NormalAccess -> 
					(match follow f.cf_type with
					| TFun _
					| TDynamic _ ->
						print ctx "static function %s() { $�args = func_get_args(); return call_user_func_array(self::$%s, $�args); }" name name;
						newline ctx;
					| _ ->
						()
					)
				| _ ->
					()
				);
			print ctx "%s $%s" rights name;
			match f.cf_expr with
			| None -> ()
			| Some e ->
				match e.eexpr with
				| TConst _ ->
					print ctx " = ";
					gen_value ctx e
				| _ -> ()
		end

let generate_static_field_assign ctx path f =
	let p = ctx.curclass.cl_pos in
	if not ctx.curclass.cl_interface then
		(match f.cf_expr with
		| None -> ()
		| Some e ->
			match e.eexpr with
			| TConst _ -> ()
			| TFunction fd ->
				(match f.cf_set with
				| NormalAccess when 
						(match follow f.cf_type with
						| TFun _
						| TDynamic _ ->
							true;
						| _ ->
							false) -> 
					newline ctx;
					print ctx "%s::$%s = " (s_path ctx path false p) (s_ident f.cf_name);
					gen_value ctx e
				| MethodAccess true ->
					newline ctx;
					print ctx "%s::$%s = " (s_path ctx path false p) (s_ident f.cf_name);
					gen_value ctx e
				| _ -> ())
			| _ ->
				newline ctx;
				print ctx "%s::$%s = " (s_path ctx path false p) (s_ident f.cf_name);
				gen_value ctx e)

let rec super_has_dynamic c =
	match c.cl_super with
	| None -> false
	| Some (csup, _) -> (match csup.cl_dynamic with
		| Some _ -> true
		| _ -> super_has_dynamic csup)
		
let generate_class ctx c =
	let requires_constructor = ref true in
	ctx.curclass <- c;
(*	ctx.curmethod <- ("new",true); *)
	ctx.local_types <- List.map snd c.cl_types;

	print ctx "%s %s " (if c.cl_interface then "interface" else "class") (s_path ctx c.cl_path c.cl_extern c.cl_pos);
	(match c.cl_super with
	| None -> ()
	| Some (csup,_) ->
		requires_constructor := false;
		print ctx "extends %s " (s_path ctx csup.cl_path csup.cl_extern c.cl_pos));
	(match c.cl_implements with
	| [] -> ()
	| l ->
		spr ctx (if c.cl_interface then "extends " else "implements ");
		concat ctx ", " (fun (i,_) ->
		print ctx "%s" (s_path ctx i.cl_path i.cl_extern c.cl_pos)) l);
	spr ctx "{";
	
	let get_dynamic_methods = List.filter is_dynamic_method c.cl_ordered_fields in

	if not ctx.curclass.cl_interface then ctx.dynamic_methods <- get_dynamic_methods;

	let cl = open_block ctx in
	(match c.cl_constructor with
	| None ->
		if !requires_constructor && not c.cl_interface then begin
			newline ctx;
			spr ctx "public function __construct(){}"
		end;
	| Some f ->
		let f = { f with
			cf_name = "__construct";
			cf_public = true;
		} in
		ctx.constructor_block <- true;
		generate_field ctx false f;
	);

	List.iter (generate_field ctx false) c.cl_ordered_fields;

	(match c.cl_dynamic with
		| Some _ when not c.cl_interface && not (super_has_dynamic c) ->
			newline ctx;
			spr ctx "private $�dynamics = array();\n\tpublic function &__get($n) {\n\t\tif(isset($this->�dynamics[$n]))\n\t\t\treturn $this->�dynamics[$n];\n\t}\n\tpublic function __set($n, $v) {\n\t\t$this->�dynamics[$n] = $v;\n\t}\n\tpublic function __call($n, $a) {\n\t\tif(is_callable($this->�dynamics[$n]))\n\t\t\treturn call_user_func_array($this->�dynamics[$n], $a);\n\t\tthrow new HException(\"Unable to call �\".$n.\"�\");\n\t}"
		| Some _
		| _ ->
			if List.length ctx.dynamic_methods > 0 then begin
				newline ctx;
				spr ctx "public function __call($m, $a) {\n\t\tif(isset($this->$m) && is_callable($this->$m))\n\t\t\treturn call_user_func_array($this->$m, $a);\n\t\telse if(isset($this->�dynamics[$m]) && is_callable($this->�dynamics[$m]))\n\t\t\treturn call_user_func_array($this->�dynamics[$m], $a);\n\t\telse\n\t\t\tthrow new HException('Unable to call �'.$m.'�');\n\t}";
			end;
	);

	List.iter (generate_field ctx true) c.cl_ordered_statics;

	cl();
	newline ctx;
		
	if PMap.exists "__toString" c.cl_fields then
		()
	else if PMap.exists "toString" c.cl_fields && (not c.cl_interface) && (not c.cl_extern) then begin
		print ctx "\tfunction __toString() { return $this->toString(); }";
		newline ctx
	end else if (not c.cl_interface) && (not c.cl_extern) then begin
		print ctx "\tfunction __toString() { return '%s'; }" ((s_path_haxe c.cl_path)) ;
		newline ctx
	end;
	
	print ctx "}"
	
let createmain com c =
	let filename = match com.php_front with None -> "index.php" | Some n -> n in
	let ctx = {
		com = com;
		stack = stack_init com false;
		tabs = "";
		ch = open_out (com.file ^ "/" ^ filename);
		path = ([], "");
		buf = Buffer.create (1 lsl 14);
		in_value = None;
		in_loop = false;
		handle_break = false;
		imports = Hashtbl.create 0;
		extern_required_paths = [];
		extern_classes_with_init = [];
		curclass = null_class;
		curmethod = "";
		locals = PMap.empty;
		inv_locals = PMap.empty;
		local_types = [];
		inits = [];
		constructor_block = false;
		quotes = 0;
		dynamic_methods = [];
		all_dynamic_methods = [];
		is_call = false;
		cwd = "";
	} in

	spr ctx "if(version_compare(PHP_VERSION, '5.1.0', '<')) {
    exit('Your current PHP version is: ' . PHP_VERSION . '. haXe/PHP generates code for version 5.1.0 or later');
}";
	newline ctx;
	newline ctx;
	spr ctx "require_once dirname(__FILE__).'/lib/php/Boot.class.php';\n\n";
	(match c.cl_ordered_statics with
	| [{ cf_expr = Some e }] ->
		gen_value ctx e;
	| _ -> assert false);
	newline ctx;
	spr ctx "\n?>";
	close ctx

let generate_main ctx c =
	(match c.cl_ordered_statics with
	| [{ cf_expr = Some e }] ->
		gen_value ctx e;
	| _ -> assert false);
		newline ctx

let generate_enum ctx e =
	ctx.local_types <- List.map snd e.e_types;
	let pack = open_block ctx in
	let ename = s_path ctx e.e_path e.e_extern e.e_pos in

	print ctx "class %s extends Enum {" ename;
	let cl = open_block ctx in
	PMap.iter (fun _ c ->
		newline ctx;
		match c.ef_type with
		| TFun (args,_) ->
			print ctx "public static function %s($" c.ef_name;
			concat ctx ", $" (fun (a,o,t) ->
				spr ctx a;
				if o then spr ctx " = null";
			) args;
			spr ctx ") {";
			print ctx " return new %s(\"%s\", %d, array($" ename c.ef_name c.ef_index;
			concat ctx ", $" (fun (a,_,_) -> spr ctx a) args;
			print ctx ")); }";
		| _ ->
			print ctx "public static $%s" c.ef_name;
	) e.e_constrs;
	cl();
	newline ctx;
	print ctx "}";

	PMap.iter (fun _ c ->
		match c.ef_type with
		| TFun (args,_) ->
			();
		| _ ->
			newline ctx;
			print ctx "%s::$%s = new %s(\"%s\", %d)" ename c.ef_name ename c.ef_name  c.ef_index;
	) e.e_constrs;

	pack();
	newline ctx

let generate com =
	let all_dynamic_methods = ref [] in
	let extern_classes_with_init = ref [] in
	List.iter (fun t ->
		(match t with
		| TClassDecl c ->
			let dynamic_methods_names lst =
				List.map (fun fd -> {
					mpath = c.cl_path;
					mname = fd.cf_name;
				}) (List.filter is_dynamic_method lst)
			in
			all_dynamic_methods := dynamic_methods_names c.cl_ordered_fields @ !all_dynamic_methods;
			
			if c.cl_extern then
				(match c.cl_init with
				| Some _ ->
					extern_classes_with_init := c.cl_path :: !extern_classes_with_init;
				| _ -> 
					())
			else
				all_dynamic_methods := dynamic_methods_names c.cl_ordered_statics @ !all_dynamic_methods;
		| _ -> ())
	) com.types;
	List.iter (fun t ->
		(match t with
		| TClassDecl c ->
			let c = (match c.cl_path with
				| ["php"],"PhpXml__"	-> { c with cl_path = [],"Xml" }
				| ["php"],"PhpDate__"   -> { c with cl_path = [],"Date" }
				| ["php"],"PhpMath__"   -> { c with cl_path = [],"Math" }
				| _ -> c
			) in
			if c.cl_extern then begin
				(match c.cl_init with
				| None -> ()
				| Some e ->
					let ctx = init com "lib" c.cl_path 3 in
					gen_expr ctx e;
					close ctx;
					);
			end else (match c.cl_path with
			| [], "@Main" ->
				createmain com c;
			| _ ->
				let ctx = init com "lib" c.cl_path (if c.cl_interface then 2 else 0) in
				ctx.extern_classes_with_init <- !extern_classes_with_init;
				ctx.all_dynamic_methods <- !all_dynamic_methods;
				generate_class ctx c;
				(match c.cl_init with
				| None -> ()
				| Some e ->
					newline ctx;
					gen_expr ctx e);
				List.iter (generate_static_field_assign ctx c.cl_path) c.cl_ordered_statics;
				newline ctx;
				if c.cl_path = (["php"], "Boot") & com.debug then begin
					print ctx "$%s = new _hx_array(array())" ctx.stack.Codegen.stack_var;
					newline ctx;
					print ctx "$%s = new _hx_array(array())" ctx.stack.Codegen.stack_exc_var;
					newline ctx;
				end;
				close ctx);
		| TEnumDecl e ->
			if e.e_extern then
				()
			else
				let ctx = init com "lib" e.e_path 1 in
			generate_enum ctx e;
			close ctx
		| TTypeDecl t ->
			());
	) com.types;
	Hashtbl.iter (fun name data ->
		write_resource com.file name data
	) com.resources;
