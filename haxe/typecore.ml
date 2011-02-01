(*
 *  Haxe Compiler
 *  Copyright (c)2005-2008 Nicolas Cannasse
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
open Common
open Type

type type_patch = {
	mutable tp_type : Ast.complex_type option;
	mutable tp_remove : bool;
	mutable tp_meta : Ast.metadata;
}

type typer_globals = {
	types_module : (path, path) Hashtbl.t;
	modules : (path , module_def) Hashtbl.t;
	mutable delayed : (unit -> unit) list;
	constructs : (path , Ast.access list * Ast.type_param list * Ast.func) Hashtbl.t;
	doinline : bool;
	mutable core_api : typer option;
	mutable macros : ((unit -> unit) * typer) option;
	mutable std : module_def;
	mutable hook_generate : (unit -> unit) list;
	type_patches : (path, (string * bool, type_patch) Hashtbl.t * type_patch) Hashtbl.t;
	(* api *)
	do_inherit : typer -> Type.tclass -> Ast.pos -> Ast.class_flag -> bool;
	do_create : Common.context -> typer;
	do_macro : typer -> path -> string -> Ast.expr list -> Ast.pos -> Ast.expr option;
	do_load_module : typer -> path -> pos -> module_def;
	do_optimize : typer -> texpr -> texpr;
	do_build_instance : typer -> module_type -> pos -> ((string * t) list * path * (t list -> t));
}

and typer = {
	(* shared *)
	com : context;
	mutable t : basic_types;
	g : typer_globals;
	mutable in_macro : bool;
	(* per-module *)
	current : module_def;
	mutable local_types : module_type list;
	mutable local_using : module_type list;
	(* per-class *)
	mutable curclass : tclass;
	mutable tthis : t;
	mutable type_params : (string * t) list;
	(* per-function *)
	mutable curmethod : string;
	mutable untyped : bool;
	mutable in_super_call : bool;
	mutable in_constructor : bool;
	mutable in_static : bool;
	mutable in_loop : bool;
	mutable in_display : bool;
	mutable ret : t;
	mutable locals : (string, t) PMap.t;
	mutable locals_map : (string, string) PMap.t;
	mutable locals_map_inv : (string, string) PMap.t;
	mutable opened : anon_status ref list;
	mutable param_type : t option;
}

type error_msg =
	| Module_not_found of path
	| Type_not_found of path * string
	| Unify of unify_error list
	| Custom of string
	| Protect of error_msg
	| Unknown_ident of string
	| Stack of error_msg * error_msg
	| Forbid_package of string * path

exception Error of error_msg * pos

let type_expr_ref : (typer -> Ast.expr -> bool -> texpr) ref = ref (fun _ _ _ -> assert false)

let unify_error_msg ctx = function
	| Cannot_unify (t1,t2) ->
		s_type ctx t1 ^ " should be " ^ s_type ctx t2
	| Invalid_field_type s ->
		"Invalid type for field " ^ s ^ " :"
	| Has_no_field (t,n) ->
		s_type ctx t ^ " has no field " ^ n
	| Has_extra_field (t,n) ->
		s_type ctx t ^ " has extra field " ^ n
	| Invalid_kind (f,a,b) ->
		(match a, b with
		| Var va, Var vb ->
			let name, stra, strb = if va.v_read = vb.v_read then
				"setter", s_access va.v_write, s_access vb.v_write
			else if va.v_write = vb.v_write then
				"getter", s_access va.v_read, s_access vb.v_read
			else
				"access", "(" ^ s_access va.v_read ^ "," ^ s_access va.v_write ^ ")", "(" ^ s_access vb.v_read ^ "," ^ s_access vb.v_write ^ ")"
			in
			"Inconsistent " ^ name ^ " for field " ^ f ^ " : " ^ stra ^ " should be " ^ strb
		| _ ->
			"Field " ^ f ^ " is " ^ s_kind a ^ " but should be " ^ s_kind b)
	| Invalid_visibility n ->
		"The field " ^ n ^ " is not public"
	| Not_matching_optional n ->
		"Optional attribute of parameter " ^ n ^ " differs"
	| Cant_force_optional ->
		"Optional parameters can't be forced"

let rec error_msg = function
	| Module_not_found m -> "Class not found : " ^ Ast.s_type_path m
	| Type_not_found (m,t) -> "Module " ^ Ast.s_type_path m ^ " does not define type " ^ t
	| Unify l ->
		let ctx = print_context() in
		String.concat "\n" (List.map (unify_error_msg ctx) l)
	| Unknown_ident s -> "Unknown identifier : " ^ s
	| Custom s -> s
	| Stack (m1,m2) -> error_msg m1 ^ "\n" ^ error_msg m2
	| Protect m -> error_msg m
	| Forbid_package (p,m) ->
		"You can't access the " ^ p ^ " package with current compilation flags (for " ^ Ast.s_type_path m ^ ")"

let display_error ctx msg p = ctx.com.error msg p

let error msg p = raise (Error (Custom msg,p))

let type_expr ctx e need_val = (!type_expr_ref) ctx e need_val

let unify ctx t1 t2 p =
	try
		Type.unify t1 t2
	with
		Unify_error l ->
			if not ctx.untyped then display_error ctx (error_msg (Unify l)) p

let unify_raise ctx t1 t2 p =
	try
		Type.unify t1 t2
	with
		Unify_error l ->
			(* no untyped check *)
			raise (Error (Unify l,p))

let exc_protect f =
	let rec r = ref (fun() ->
		try
			f r
		with
			| Error (Protect _,_) as e -> raise e
			| Error (m,p) -> raise (Error (Protect m,p))
	) in
	r

let save_locals ctx =
	let locals = ctx.locals in
	let map = ctx.locals_map in
	let inv = ctx.locals_map_inv in
	(fun() ->
		ctx.locals <- locals;
		ctx.locals_map <- map;
		ctx.locals_map_inv <- inv;
	)

let add_local ctx v t =
	let rec loop n =
		let nv = (if n = 0 then v else v ^ string_of_int n) in
		if PMap.mem nv ctx.locals || PMap.mem nv ctx.locals_map_inv then
			loop (n+1)
		else begin
			ctx.locals <- PMap.add v t ctx.locals;
			if n <> 0 then begin
				ctx.locals_map <- PMap.add v nv ctx.locals_map;
				ctx.locals_map_inv <- PMap.add nv v ctx.locals_map_inv;
			end;
			nv
		end
	in
	loop 0

let gen_local ctx t =
	let rec loop n =
		let nv = (if n = 0 then "_g" else "_g" ^ string_of_int n) in
		if PMap.mem nv ctx.locals || PMap.mem nv ctx.locals_map_inv then
			loop (n+1)
		else
			nv
	in
	add_local ctx (loop 0) t

let rec is_nullable = function
	| TMono r ->
		(match !r with None -> true | Some t -> is_nullable t)
	| TType ({ t_path = ([],"Null") },[_]) ->
		false
	| TLazy f ->
		is_nullable (!f())
	| TType (t,tl) ->
		is_nullable (apply_params t.t_types tl t.t_type)
	| TFun _ ->
		true
	| TInst ({ cl_path = (["haxe"],"Int32") },[])
	| TInst ({ cl_path = ([],"Int") },[])
	| TInst ({ cl_path = ([],"Float") },[])
	| TEnum ({ e_path = ([],"Bool") },[]) -> true
	| _ ->
		false

let rec is_null = function
	| TMono r ->
		(match !r with None -> false | Some t -> is_null t)
	| TType ({ t_path = ([],"Null") },[t]) ->
		is_nullable t
	| TLazy f ->
		is_null (!f())
	| TType (t,tl) ->
		is_null (apply_params t.t_types tl t.t_type)
	| _ ->
		false

let not_opened = ref Closed
let mk_anon fl = TAnon { a_fields = fl; a_status = not_opened; }

let delay ctx f =
	ctx.g.delayed <- f :: ctx.g.delayed

let mk_field name t = {
	cf_name = name;
	cf_type = t;
	cf_doc = None;
	cf_meta = no_meta;
	cf_public = true;
	cf_kind = Var { v_read = AccNormal; v_write = AccNormal };
	cf_expr = None;
	cf_params = [];
}
