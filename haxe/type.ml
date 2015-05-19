(*
 *  Haxe Compiler
 *  Copyright (c)2005 Nicolas Cannasse
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warraTFnty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program; if not, write to the Free Software
 *  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 *)
open Ast

type path = string list * string

type field_kind =
	| Var of var_kind
	| Method of method_kind

and var_kind = {
	v_read : var_access;
	v_write : var_access;
}

and var_access =
	| AccNormal
	| AccNo				(* can't be accessed outside of the class itself and its subclasses *)
	| AccNever			(* can't be accessed, even in subclasses *)
	| AccResolve		(* call resolve("field") when accessed *)
	| AccCall of string (* perform a method call when accessed *)
	| AccInline			(* similar to Normal but inline when accessed *)
	| AccRequire of string (* set when @:require(cond) fails *)

and method_kind =
	| MethNormal
	| MethInline
	| MethDynamic
	| MethMacro

type t =
	| TMono of t option ref
	| TEnum of tenum * tparams
	| TInst of tclass * tparams
	| TType of tdef * tparams
	| TFun of (string * bool * t) list * t
	| TAnon of tanon
	| TDynamic of t
	| TLazy of (unit -> t) ref

and tparams = t list

and tconstant =
	| TInt of int32
	| TFloat of string
	| TString of string
	| TBool of bool
	| TNull
	| TThis
	| TSuper

and tfunc = {
	tf_args : (string * tconstant option * t) list;
	tf_type : t;
	tf_expr : texpr;
}

and anon_status =
	| Closed
	| Opened
	| Const
	| Statics of tclass
	| EnumStatics of tenum

and tanon = {
	mutable a_fields : (string, tclass_field) PMap.t;
	a_status : anon_status ref;
}

and texpr_expr =
	| TConst of tconstant
	| TLocal of string
	| TEnumField of tenum * string
	| TArray of texpr * texpr
	| TBinop of Ast.binop * texpr * texpr
	| TField of texpr * string
	| TClosure of texpr * string
	| TTypeExpr of module_type
	| TParenthesis of texpr
	| TObjectDecl of (string * texpr) list
	| TArrayDecl of texpr list
	| TCall of texpr * texpr list
	| TNew of tclass * tparams * texpr list
	| TUnop of Ast.unop * Ast.unop_flag * texpr
	| TFunction of tfunc
	| TVars of (string * t * texpr option) list
	| TBlock of texpr list
	| TFor of string * t * texpr * texpr
	| TIf of texpr * texpr * texpr option
	| TWhile of texpr * texpr * Ast.while_flag
	| TSwitch of texpr * (texpr list * texpr) list * texpr option
	| TMatch of texpr * (tenum * tparams) * (int list * (string option * t) list option * texpr) list * texpr option
	| TTry of texpr * (string * t * texpr) list
	| TReturn of texpr option
	| TBreak
	| TContinue
	| TThrow of texpr
	| TCast of texpr * module_type option

and texpr = {
	eexpr : texpr_expr;
	etype : t;
	epos : Ast.pos;
}

and tclass_field = {
	cf_name : string;
	mutable cf_type : t;
	cf_public : bool;
	mutable cf_doc : Ast.documentation;
	mutable cf_meta : metadata;
	mutable cf_kind : field_kind;
	cf_params : (string * t) list;
	mutable cf_expr : texpr option;
}

and tclass_kind =
	| KNormal
	| KTypeParameter
	| KExtension of tclass * tparams
	| KConstant of tconstant
	| KGeneric
	| KGenericInstance of tclass * tparams

and metadata = Ast.metadata

and tclass = {
	mutable cl_path : path;
	mutable cl_pos : Ast.pos;
	mutable cl_private : bool;
	mutable cl_doc : Ast.documentation;
	mutable cl_meta : metadata;
	mutable cl_kind : tclass_kind;
	mutable cl_extern : bool;
	mutable cl_interface : bool;
	mutable cl_types : (string * t) list;
	mutable cl_super : (tclass * tparams) option;
	mutable cl_implements : (tclass * tparams) list;
	mutable cl_fields : (string , tclass_field) PMap.t;
	mutable cl_statics : (string, tclass_field) PMap.t;
	mutable cl_ordered_statics : tclass_field list;
	mutable cl_ordered_fields : tclass_field list;
	mutable cl_dynamic : t option;
	mutable cl_array_access : t option;
	mutable cl_constructor : tclass_field option;
	mutable cl_init : texpr option;
	mutable cl_overrides : string list;
}

and tenum_field = {
	ef_name : string;
	ef_type : t;
	ef_pos : Ast.pos;
	ef_doc : Ast.documentation;
	ef_index : int;
	mutable ef_meta : metadata;
}

and tenum = {
	e_path : path;
	e_pos : Ast.pos;
	e_doc : Ast.documentation;
	e_private : bool;
	mutable e_meta : metadata;
	mutable e_extern : bool;
	mutable e_types : (string * t) list;
	mutable e_constrs : (string , tenum_field) PMap.t;
	mutable e_names : string list;
}

and tdef = {
	t_path : path;
	t_pos : Ast.pos;
	t_doc : Ast.documentation;
	t_private : bool;
	mutable t_meta : metadata;
	mutable t_types : (string * t) list;
	mutable t_type : t;
}

and module_type =
	| TClassDecl of tclass
	| TEnumDecl of tenum
	| TTypeDecl of tdef

type module_def = {
	mpath : path;
	mtypes : module_type list;
}

let mk e t p = { eexpr = e; etype = t; epos = p }

let mk_block e =
	match e.eexpr with
	| TBlock (_ :: _) -> e
	| _ -> mk (TBlock [e]) e.etype e.epos

let null t p = mk (TConst TNull) t p

let mk_mono() = TMono (ref None)

let rec t_dynamic = TDynamic t_dynamic

let tfun pl r = TFun (List.map (fun t -> "",false,t) pl,r)

let fun_args l = List.map (fun (a,c,t) -> a, c <> None, t) l

let mk_class path pos =
	{
		cl_path = path;
		cl_pos = pos;
		cl_doc = None;
		cl_meta = [];
		cl_private = false;
		cl_kind = KNormal;
		cl_extern = false;
		cl_interface = false;
		cl_types = [];
		cl_super = None;
		cl_implements = [];
		cl_fields = PMap.empty;
		cl_ordered_statics = [];
		cl_ordered_fields = [];
		cl_statics = PMap.empty;
		cl_dynamic = None;
		cl_array_access = None;
		cl_constructor = None;
		cl_init = None;
		cl_overrides = [];
	}

let null_class =
	let c = mk_class ([],"") Ast.null_pos in
	c.cl_private <- true;
	c

let arg_name (name,_,_) = name

let t_private = function
	| TClassDecl c -> c.cl_private
	| TEnumDecl e -> e.e_private
	| TTypeDecl t -> t.t_private

let t_path = function
	| TClassDecl c -> c.cl_path
	| TEnumDecl e -> e.e_path
	| TTypeDecl t -> t.t_path

let t_pos = function
	| TClassDecl c -> c.cl_pos
	| TEnumDecl e -> e.e_pos
	| TTypeDecl t -> t.t_pos

let print_context() = ref []

let is_closed a = !(a.a_status) <> Opened

let rec s_type ctx t =
	match t with
	| TMono r ->
		(match !r with
		| None -> Printf.sprintf "Unknown<%d>" (try List.assq t (!ctx) with Not_found -> let n = List.length !ctx in ctx := (t,n) :: !ctx; n)
		| Some t -> s_type ctx t)
	| TEnum (e,tl) ->
		Ast.s_type_path e.e_path ^ s_type_params ctx tl
	| TInst (c,tl) ->
		Ast.s_type_path c.cl_path ^ s_type_params ctx tl
	| TType (t,tl) ->
		Ast.s_type_path t.t_path ^ s_type_params ctx tl
	| TFun ([],t) ->
		"Void -> " ^ s_fun ctx t false
	| TFun (l,t) ->
		String.concat " -> " (List.map (fun (s,b,t) ->
			(if b then "?" else "") ^ (if s = "" then "" else s ^ " : ") ^ s_fun ctx t true
		) l) ^ " -> " ^ s_fun ctx t false
	| TAnon a ->
		let fl = PMap.fold (fun f acc -> (" " ^ f.cf_name ^ " : " ^ s_type ctx f.cf_type) :: acc) a.a_fields [] in
		"{" ^ (if not (is_closed a) then "+" else "") ^  String.concat "," fl ^ " }"
	| TDynamic t2 ->
		"Dynamic" ^ s_type_params ctx (if t == t2 then [] else [t2])
	| TLazy f ->
		s_type ctx (!f())

and s_fun ctx t void =
	match t with
	| TFun _ ->
		"(" ^ s_type ctx t ^ ")"
	| TEnum ({ e_path = ([],"Void") },[]) when void ->
		"(" ^ s_type ctx t ^ ")"
	| TMono r ->
		(match !r with
		| None -> s_type ctx t
		| Some t -> s_fun ctx t void)
	| TLazy f ->
		s_fun ctx (!f()) void
	| _ ->
		s_type ctx t

and s_type_params ctx = function
	| [] -> ""
	| l -> "<" ^ String.concat ", " (List.map (s_type ctx) l) ^ ">"

let s_access = function
	| AccNormal -> "default"
	| AccNo -> "null"
	| AccNever -> "never"
	| AccResolve -> "resolve"
	| AccCall m -> m
	| AccInline	-> "inline"
	| AccRequire n -> "require " ^ n

let s_kind = function
	| Var { v_read = AccNormal; v_write = AccNormal } -> "var"
	| Var v -> "(" ^ s_access v.v_read ^ "," ^ s_access v.v_write ^ ")"
	| Method m ->
		match m with
		| MethNormal -> "method"
		| MethDynamic -> "dynamic method"
		| MethInline -> "inline method"
		| MethMacro -> "macro method"

let rec is_parent csup c =
	if c == csup then
		true
	else match c.cl_super with
		| None -> false
		| Some (c,_) -> is_parent csup c

let map loop t =
	match t with
	| TMono r ->
		(match !r with
		| None -> t
		| Some t -> loop t) (* erase*)
	| TEnum (_,[]) | TInst (_,[]) | TType (_,[]) ->
		t
	| TEnum (e,tl) ->
		TEnum (e, List.map loop tl)
	| TInst (c,tl) ->
		TInst (c, List.map loop tl)
	| TType (t2,tl) ->
		TType (t2,List.map loop tl)
	| TFun (tl,r) ->
		TFun (List.map (fun (s,o,t) -> s, o, loop t) tl,loop r)
	| TAnon a ->
		TAnon {
			a_fields = PMap.map (fun f -> { f with cf_type = loop f.cf_type }) a.a_fields;
			a_status = a.a_status;
		}
	| TLazy f ->
		let ft = !f() in
		let ft2 = loop ft in
		if ft == ft2 then t else ft2
	| TDynamic t2 ->
		if t == t2 then	t else TDynamic (loop t2)

(* substitute parameters with other types *)
let apply_params cparams params t =
	match cparams with
	| [] -> t
	| _ ->
	let rec loop l1 l2 =
		match l1, l2 with
		| [] , [] -> []
		| (x,TLazy f) :: l1, _ -> loop ((x,(!f)()) :: l1) l2
		| (_,t1) :: l1 , t2 :: l2 -> (t1,t2) :: loop l1 l2
		| _ -> assert false
	in
	let subst = loop cparams params in
	let rec loop t =
		try
			List.assq t subst
		with Not_found ->
		match t with
		| TMono r ->
			(match !r with
			| None -> t
			| Some t -> loop t)
		| TEnum (e,tl) ->
			(match tl with
			| [] -> t
			| _ -> TEnum (e,List.map loop tl))
		| TType (t2,tl) ->
			(match tl with
			| [] -> t
			| _ -> TType (t2,List.map loop tl))
		| TInst (c,tl) ->
			(match tl with
			| [] ->
				t
			| [TMono r] ->
				(match !r with
				| Some tt when t == tt ->
					(* for dynamic *)
					let pt = mk_mono() in
					let t = TInst (c,[pt]) in
					(match pt with TMono r -> r := Some t | _ -> assert false);
					t
				| _ -> TInst (c,List.map loop tl))
			| _ ->
				TInst (c,List.map loop tl))
		| TFun (tl,r) ->
			TFun (List.map (fun (s,o,t) -> s, o, loop t) tl,loop r)
		| TAnon a ->
			TAnon {
				a_fields = PMap.map (fun f -> { f with cf_type = loop f.cf_type }) a.a_fields;
				a_status = a.a_status;
			}
		| TLazy f ->
			let ft = !f() in
			let ft2 = loop ft in
			if ft == ft2 then
				t
			else
				ft2
		| TDynamic t2 ->
			if t == t2 then
				t
			else
				TDynamic (loop t2)
	in
	loop t

let rec follow t =
	match t with
	| TMono r ->
		(match !r with
		| Some t -> follow t
		| _ -> t)
	| TLazy f ->
		follow (!f())
	| TType (t,tl) ->
		follow (apply_params t.t_types tl t.t_type)
	| _ -> t

let rec link e a b =
	(* tell if setting a == b will create a type-loop *)
	let rec loop t =
		if t == a then
			true
		else match t with
		| TMono t -> (match !t with None -> false | Some t -> loop t)
		| TEnum (_,tl) -> List.exists loop tl
		| TInst (_,tl) | TType (_,tl) -> List.exists loop tl
		| TFun (tl,t) -> List.exists (fun (_,_,t) -> loop t) tl || loop t
		| TDynamic t2 ->
			if t == t2 then
				false
			else
				loop t2
		| TLazy f ->
			loop (!f())
		| TAnon a ->
			try
				PMap.iter (fun _ f -> if loop f.cf_type then raise Exit) a.a_fields;
				false
			with
				Exit -> true
	in
	(* tell is already a ~= b *)
	if loop b then
		(follow b) == a
	else
		match b with
		| TDynamic _ -> true
		| _ -> e := Some b; true

let monomorphs eparams t =
	apply_params eparams (List.map (fun _ -> mk_mono()) eparams) t

let rec fast_eq a b =
	if a == b then
		true
	else match a , b with
	| TFun (l1,r1) , TFun (l2,r2) ->
		List.for_all2 (fun (_,_,t1) (_,_,t2) -> fast_eq t1 t2) l1 l2 && fast_eq r1 r2
	| TType (t1,l1), TType (t2,l2) ->
		t1 == t2 && List.for_all2 fast_eq l1 l2
	| TEnum (e1,l1), TEnum (e2,l2) ->
		e1 == e2 && List.for_all2 fast_eq l1 l2
	| TInst (c1,l1), TInst (c2,l2) ->
		c1 == c2 && List.for_all2 fast_eq l1 l2
	| _ , _ ->
		false

(* perform unification with subtyping.
   the first type is always the most down in the class hierarchy
   it's also the one that is pointed by the position.
   It's actually a typecheck of  A :> B where some mutations can happen *)

type unify_error =
	| Cannot_unify of t * t
	| Invalid_field_type of string
	| Has_no_field of t * string
	| Has_extra_field of t * string
	| Invalid_kind of string * field_kind * field_kind
	| Invalid_visibility of string
	| Not_matching_optional of string
	| Cant_force_optional

exception Unify_error of unify_error list

let cannot_unify a b = Cannot_unify (a,b)
let invalid_field n = Invalid_field_type n
let invalid_kind n a b = Invalid_kind (n,a,b)
let invalid_visibility n = Invalid_visibility n
let has_no_field t n = Has_no_field (t,n)
let has_extra_field t n = Has_extra_field (t,n)
let error l = raise (Unify_error l)
let has_meta m ml = List.exists (fun (m2,_,_) -> m = m2) ml
let no_meta = []

(*
	we can restrict access as soon as both are runtime-compatible
*)
let unify_access a1 a2 =
	a1 = a2 || match a1, a2 with
	| _, AccNo | _, AccNever -> true
	| AccInline, AccNormal -> true
	| _ -> false

let direct_access = function
	| AccNo | AccNever | AccNormal | AccInline | AccRequire _ -> true
	| AccResolve | AccCall _ -> false

let unify_kind k1 k2 =
	k1 = k2 || match k1, k2 with
		| Var v1, Var v2 -> unify_access v1.v_read v2.v_read && unify_access v1.v_write v2.v_write
		| Var v, Method m ->
			(match v.v_read, v.v_write, m with
			| AccNormal, _, MethNormal -> true
			| AccNormal, AccNormal, MethDynamic -> true
			| _ -> false)
		| Method m, Var v ->
			(match m with
			| MethDynamic -> direct_access v.v_read && direct_access v.v_write
			| MethMacro -> false
			| MethNormal | MethInline ->
				match v.v_write with
				| AccNo | AccNever -> true
				| _ -> false)
		| Method m1, Method m2 ->
			match m1,m2 with
			| MethInline, MethNormal
			| MethDynamic, MethNormal -> true
			| _ -> false

let eq_stack = ref []

type eq_kind =
	| EqStrict
	| EqCoreType
	| EqRightDynamic
	| EqBothDynamic

let rec type_eq param a b =
	if a == b then
		()
	else match a , b with
	| TLazy f , _ -> type_eq param (!f()) b
	| _ , TLazy f -> type_eq param a (!f())
	| TMono t , _ ->
		(match !t with
		| None -> if param = EqCoreType || not (link t a b) then error [cannot_unify a b]
		| Some t -> type_eq param t b)
	| _ , TMono t ->
		(match !t with
		| None -> if param = EqCoreType || not (link t b a) then error [cannot_unify a b]
		| Some t -> type_eq param a t)
	| TType (t1,tl1), TType (t2,tl2) when (t1 == t2 || (param = EqCoreType && t1.t_path = t2.t_path)) && List.length tl1 = List.length tl2 ->
		List.iter2 (type_eq param) tl1 tl2
	| TType (t,tl) , _ when param <> EqCoreType ->
		type_eq param (apply_params t.t_types tl t.t_type) b
	| _ , TType (t,tl) when param <> EqCoreType ->
		if List.exists (fun (a2,b2) -> fast_eq a a2 && fast_eq b b2) (!eq_stack) then
			()
		else begin
			eq_stack := (a,b) :: !eq_stack;
			try
				type_eq param a (apply_params t.t_types tl t.t_type);
				eq_stack := List.tl !eq_stack;
			with
				Unify_error l ->
					eq_stack := List.tl !eq_stack;
					error (cannot_unify a b :: l)
		end
	| TEnum (e1,tl1) , TEnum (e2,tl2) ->
		if e1 != e2 && not (param = EqCoreType && e1.e_path = e2.e_path) then error [cannot_unify a b];
		List.iter2 (type_eq param) tl1 tl2
	| TInst (c1,tl1) , TInst (c2,tl2) ->
		if c1 != c2 && not (param = EqCoreType && c1.cl_path = c2.cl_path) then error [cannot_unify a b];
		List.iter2 (type_eq param) tl1 tl2
	| TFun (l1,r1) , TFun (l2,r2) when List.length l1 = List.length l2 ->
		(try
			type_eq param r1 r2;
			List.iter2 (fun (n,o1,t1) (_,o2,t2) ->
				if o1 <> o2 then error [Not_matching_optional n];
				type_eq param t1 t2
			) l1 l2
		with
			Unify_error l -> error (cannot_unify a b :: l))
	| TDynamic a , TDynamic b ->
		type_eq param a b
	| TAnon a1, TAnon a2 ->
		(try
			PMap.iter (fun n f1 ->
				try
					let f2 = PMap.find n a2.a_fields in
					if f1.cf_kind <> f2.cf_kind && (param = EqStrict || param = EqCoreType || not (unify_kind f1.cf_kind f2.cf_kind)) then error [invalid_kind n f1.cf_kind f2.cf_kind];
					try
						type_eq param f1.cf_type f2.cf_type
					with
						Unify_error l -> error (invalid_field n :: l)
				with
					Not_found ->
						if is_closed a2 then error [has_no_field b n];
						if not (link (ref None) b f1.cf_type) then error [cannot_unify a b];
						a2.a_fields <- PMap.add n f1 a2.a_fields
			) a1.a_fields;
			PMap.iter (fun n f2 ->
				if not (PMap.mem n a1.a_fields) then begin
					if is_closed a1 then error [has_no_field a n];
					if not (link (ref None) a f2.cf_type) then error [cannot_unify a b];
					a1.a_fields <- PMap.add n f2 a1.a_fields
				end;
			) a2.a_fields;
		with
			Unify_error l -> error (cannot_unify a b :: l))
	| _ , _ ->
		if b == t_dynamic && (param = EqRightDynamic || param = EqBothDynamic) then
			()
		else if a == t_dynamic && param = EqBothDynamic then
			()
		else
			error [cannot_unify a b]

let type_iseq a b =
	try
		type_eq EqStrict a b;
		true
	with
		Unify_error _ -> false

let unify_stack = ref []

let field_type f =
	match f.cf_params with
	| [] -> f.cf_type
	| l -> monomorphs l f.cf_type

let rec raw_class_field build_type c i =
	try
		let f = PMap.find i c.cl_fields in
		build_type f , f
	with Not_found -> try
		match c.cl_super with
		| None ->
			raise Not_found
		| Some (c,tl) ->
			let t , f = raw_class_field build_type c i in
			apply_params c.cl_types tl t , f
	with Not_found ->
		let rec loop = function
			| [] ->
				raise Not_found
			| (c,tl) :: l ->
				try
					let t , f = raw_class_field build_type c i in
					apply_params c.cl_types tl t, f
				with
					Not_found -> loop l
		in
		loop c.cl_implements

let class_field = raw_class_field field_type

let rec unify a b =
	if a == b then
		()
	else match a, b with
	| TLazy f , _ -> unify (!f()) b
	| _ , TLazy f -> unify a (!f())
	| TMono t , _ ->
		(match !t with
		| None -> if not (link t a b) then error [cannot_unify a b]
		| Some t -> unify t b)
	| _ , TMono t ->
		(match !t with
		| None -> if not (link t b a) then error [cannot_unify a b]
		| Some t -> unify a t)
	| TType (t,tl) , _ ->
		if not (List.exists (fun (a2,b2) -> fast_eq a a2 && fast_eq b b2) (!unify_stack)) then begin
			try
				unify_stack := (a,b) :: !unify_stack;
				unify (apply_params t.t_types tl t.t_type) b;
				unify_stack := List.tl !unify_stack;
			with
				Unify_error l ->
					unify_stack := List.tl !unify_stack;
					error (cannot_unify a b :: l)
		end
	| _ , TType (t,tl) ->
		if not (List.exists (fun (a2,b2) -> fast_eq a a2 && fast_eq b b2) (!unify_stack)) then begin
			try
				unify_stack := (a,b) :: !unify_stack;
				unify a (apply_params t.t_types tl t.t_type);
				unify_stack := List.tl !unify_stack;
			with
				Unify_error l ->
					unify_stack := List.tl !unify_stack;
					error (cannot_unify a b :: l)
		end
	| TEnum (ea,tl1) , TEnum (eb,tl2) ->
		if ea != eb then error [cannot_unify a b];
		unify_types a b tl1 tl2
	| TInst (c1,tl1) , TInst (c2,tl2) ->
		let rec loop c tl =
			if c == c2 then begin
				unify_types a b tl tl2;
				true
			end else (match c.cl_super with
				| None -> false
				| Some (cs,tls) ->
					loop cs (List.map (apply_params c.cl_types tl) tls)
			) || List.exists (fun (cs,tls) ->
				loop cs (List.map (apply_params c.cl_types tl) tls)
			) c.cl_implements
		in
		if not (loop c1 tl1) then error [cannot_unify a b]
	| TFun (l1,r1) , TFun (l2,r2) when List.length l1 = List.length l2 ->
		(try
			unify r1 r2;
			List.iter2 (fun (_,o1,t1) (_,o2,t2) ->
				if o1 && not o2 then error [Cant_force_optional];
				unify t1 t2
			) l2 l1 (* contravariance *)
		with
			Unify_error l -> error (cannot_unify a b :: l))
	| TInst (c,tl) , TAnon an ->
		(try
			PMap.iter (fun n f2 ->
				let ft, f1 = (try class_field c n with Not_found -> error [has_no_field a n]) in
				if not (unify_kind f1.cf_kind f2.cf_kind) then error [invalid_kind n f1.cf_kind f2.cf_kind];
				if f2.cf_public && not f1.cf_public then error [invalid_visibility n];
				try
					unify_with_access (apply_params c.cl_types tl ft) f2
				with
					Unify_error l -> error (invalid_field n :: l)
			) an.a_fields;
			if !(an.a_status) = Opened then an.a_status := Closed;
		with
			Unify_error l -> error (cannot_unify a b :: l))
	| TAnon a1, TAnon a2 ->
		(try
			PMap.iter (fun n f2 ->
			try
				let f1 = PMap.find n a1.a_fields in
				if not (unify_kind f1.cf_kind f2.cf_kind) then error [invalid_kind n f1.cf_kind f2.cf_kind];
				if f2.cf_public && not f1.cf_public then error [invalid_visibility n];
				try
					unify_with_access f1.cf_type f2;
				with
					Unify_error l -> error (invalid_field n :: l)
			with
				Not_found ->
					if is_closed a1 then error [has_no_field a n];
					if not (link (ref None) a f2.cf_type) then error [];
					a1.a_fields <- PMap.add n f2 a1.a_fields
			) a2.a_fields;
			(match !(a1.a_status) with
			| Const when not (PMap.is_empty a2.a_fields) ->
				PMap.iter (fun n _ -> if not (PMap.mem n a2.a_fields) then error [has_extra_field a n]) a1.a_fields;
			| Opened ->
				a1.a_status := Closed
			| _ -> ());
			(match !(a2.a_status) with
			| Statics _ | EnumStatics _ -> error []
			| Opened -> a2.a_status := Closed
			| _ -> ())
		with
			Unify_error l -> error (cannot_unify a b :: l))
	| TAnon an, TInst ({ cl_path = [],"Class" },[pt]) ->
		(match !(an.a_status) with
		| Statics cl -> unify (TInst (cl,List.map snd cl.cl_types)) pt
		| _ -> error [cannot_unify a b])
	| TAnon an, TInst ({ cl_path = [],"Enum" },[pt]) ->
		(match !(an.a_status) with
		| EnumStatics e -> unify (TEnum (e,List.map snd e.e_types)) pt
		| _ -> error [cannot_unify a b])
	| TDynamic t , _ ->
		if t == a then
			()
		else (match b with
		| TDynamic t2 ->
			if t2 != b then
				(try
					type_eq EqRightDynamic t t2
				with
					Unify_error l -> error (cannot_unify a b :: l));
		| _ ->
			error [cannot_unify a b])
	| _ , TDynamic t ->
		if t == b then
			()
		else (match a with
		| TDynamic t2 ->
			if t2 != a then
				(try
					type_eq EqRightDynamic t t2
				with
					Unify_error l -> error (cannot_unify a b :: l));
		| TAnon an ->
			(try
				(match !(an.a_status) with
				| Statics _ | EnumStatics _ -> error []
				| Opened -> an.a_status := Closed
				| _ -> ());
				PMap.iter (fun _ f ->
					try
						type_eq EqStrict (field_type f) t
					with Unify_error l ->
						error (invalid_field f.cf_name :: l)
				) an.a_fields
			with Unify_error l ->
				error (cannot_unify a b :: l))
		| _ ->
			error [cannot_unify a b])
	| _ , _ ->
		error [cannot_unify a b]

and unify_types a b tl1 tl2 =
	try
		List.iter2 (type_eq EqRightDynamic) tl1 tl2
	with
		Unify_error l -> error ((cannot_unify a b) :: l)

and unify_with_access t1 f2 =
	match f2.cf_kind with
	(* write only *)
	| Var { v_read = AccNo } | Var { v_read = AccNever } -> unify f2.cf_type t1
	(* read only *)
	| Method MethNormal | Method MethInline | Var { v_write = AccNo } | Var { v_write = AccNever } -> unify t1 f2.cf_type
	(* read/write *)
	| _ -> type_eq EqBothDynamic t1 f2.cf_type

let iter f e =
	match e.eexpr with
	| TConst _
	| TLocal _
	| TEnumField _
	| TBreak
	| TContinue
	| TTypeExpr _ ->
		()
	| TArray (e1,e2)
	| TBinop (_,e1,e2)
	| TFor (_,_,e1,e2)
	| TWhile (e1,e2,_) ->
		f e1;
		f e2;
	| TThrow e
	| TField (e,_)
	| TClosure (e,_)
	| TParenthesis e
	| TCast (e,_)
	| TUnop (_,_,e) ->
		f e
	| TArrayDecl el
	| TNew (_,_,el)
	| TBlock el ->
		List.iter f el
	| TObjectDecl fl ->
		List.iter (fun (_,e) -> f e) fl
	| TCall (e,el) ->
		f e;
		List.iter f el
	| TVars vl ->
		List.iter (fun (_,_,e) -> match e with None -> () | Some e -> f e) vl
	| TFunction fu ->
		f fu.tf_expr
	| TIf (e,e1,e2) ->
		f e;
		f e1;
		(match e2 with None -> () | Some e -> f e)
	| TSwitch (e,cases,def) ->
		f e;
		List.iter (fun (el,e2) -> List.iter f el; f e2) cases;
		(match def with None -> () | Some e -> f e)
	| TMatch (e,_,cases,def) ->
		f e;
		List.iter (fun (_,_,e) -> f e) cases;
		(match def with None -> () | Some e -> f e)
	| TTry (e,catches) ->
		f e;
		List.iter (fun (_,_,e) -> f e) catches
	| TReturn eo ->
		(match eo with None -> () | Some e -> f e)

let map_expr f e =
	match e.eexpr with
	| TConst _
	| TLocal _
	| TEnumField _
	| TBreak
	| TContinue
	| TTypeExpr _ ->
		e
	| TArray (e1,e2) ->
		{ e with eexpr = TArray (f e1,f e2) }
	| TBinop (op,e1,e2) ->
		{ e with eexpr = TBinop (op,f e1,f e2) }
	| TFor (v,t,e1,e2) ->
		{ e with eexpr = TFor (v,t,f e1,f e2) }
	| TWhile (e1,e2,flag) ->
		{ e with eexpr = TWhile (f e1,f e2,flag) }
	| TThrow e1 ->
		{ e with eexpr = TThrow (f e1) }
	| TField (e1,v) ->
		{ e with eexpr = TField (f e1,v) }
	| TClosure (e1,v) ->
		{ e with eexpr = TClosure (f e1,v) }
	| TParenthesis e1 ->
		{ e with eexpr = TParenthesis (f e1) }
	| TUnop (op,pre,e1) ->
		{ e with eexpr = TUnop (op,pre,f e1) }
	| TArrayDecl el ->
		{ e with eexpr = TArrayDecl (List.map f el) }
	| TNew (t,pl,el) ->
		{ e with eexpr = TNew (t,pl,List.map f el) }
	| TBlock el ->
		{ e with eexpr = TBlock (List.map f el) }
	| TObjectDecl el ->
		{ e with eexpr = TObjectDecl (List.map (fun (v,e) -> v, f e) el) }
	| TCall (e1,el) ->
		{ e with eexpr = TCall (f e1, List.map f el) }
	| TVars vl ->
		{ e with eexpr = TVars (List.map (fun (v,t,e) -> v , t , match e with None -> None | Some e -> Some (f e)) vl) }
	| TFunction fu ->
		{ e with eexpr = TFunction { fu with tf_expr = f fu.tf_expr } }
	| TIf (ec,e1,e2) ->
		{ e with eexpr = TIf (f ec,f e1,match e2 with None -> None | Some e -> Some (f e)) }
	| TSwitch (e1,cases,def) ->
		{ e with eexpr = TSwitch (f e1, List.map (fun (el,e2) -> List.map f el, f e2) cases, match def with None -> None | Some e -> Some (f e)) }
	| TMatch (e1,t,cases,def) ->
		{ e with eexpr = TMatch (f e1, t, List.map (fun (cl,params,e) -> cl, params, f e) cases, match def with None -> None | Some e -> Some (f e)) }
	| TTry (e1,catches) ->
		{ e with eexpr = TTry (f e1, List.map (fun (v,t,e) -> v, t, f e) catches) }
	| TReturn eo ->
		{ e with eexpr = TReturn (match eo with None -> None | Some e -> Some (f e)) }
	| TCast (e1,t) ->
		{ e with eexpr = TCast (f e1,t) }

let map_expr_type f ft e =
	match e.eexpr with
	| TConst _
	| TLocal _
	| TEnumField _
	| TBreak
	| TContinue
	| TTypeExpr _ ->
		{ e with etype = ft e.etype }
	| TArray (e1,e2) ->
		{ e with eexpr = TArray (f e1,f e2); etype = ft e.etype }
	| TBinop (op,e1,e2) ->
		{ e with eexpr = TBinop (op,f e1,f e2); etype = ft e.etype }
	| TFor (v,t,e1,e2) ->
		{ e with eexpr = TFor (v,ft t,f e1,f e2); etype = ft e.etype }
	| TWhile (e1,e2,flag) ->
		{ e with eexpr = TWhile (f e1,f e2,flag); etype = ft e.etype }
	| TThrow e1 ->
		{ e with eexpr = TThrow (f e1); etype = ft e.etype }
	| TField (e1,v) ->
		{ e with eexpr = TField (f e1,v); etype = ft e.etype }
	| TClosure (e1,v) ->
		{ e with eexpr = TClosure (f e1,v); etype = ft e.etype }
	| TParenthesis e1 ->
		{ e with eexpr = TParenthesis (f e1); etype = ft e.etype }
	| TUnop (op,pre,e1) ->
		{ e with eexpr = TUnop (op,pre,f e1); etype = ft e.etype }
	| TArrayDecl el ->
		{ e with eexpr = TArrayDecl (List.map f el); etype = ft e.etype }
	| TNew (_,_,el) ->
		let et = ft e.etype in
		(* make sure that we use the class corresponding to the replaced type *)
		let c, pl = (match follow et with TInst (c,pl) -> (c,pl) | _ -> assert false) in
		{ e with eexpr = TNew (c,pl,List.map f el); etype = et }
	| TBlock el ->
		{ e with eexpr = TBlock (List.map f el); etype = ft e.etype }
	| TObjectDecl el ->
		{ e with eexpr = TObjectDecl (List.map (fun (v,e) -> v, f e) el); etype = ft e.etype }
	| TCall (e1,el) ->
		{ e with eexpr = TCall (f e1, List.map f el); etype = ft e.etype }
	| TVars vl ->
		{ e with eexpr = TVars (List.map (fun (v,t,e) -> v , ft t , match e with None -> None | Some e -> Some (f e)) vl); etype = ft e.etype }
	| TFunction fu ->
		let fu = {
			tf_expr = f fu.tf_expr;
			tf_args = List.map (fun (n,o,t) -> n, o, ft t) fu.tf_args;
			tf_type = ft fu.tf_type;
		} in
		{ e with eexpr = TFunction fu; etype = ft e.etype }
	| TIf (ec,e1,e2) ->
		{ e with eexpr = TIf (f ec,f e1,match e2 with None -> None | Some e -> Some (f e)); etype = ft e.etype }
	| TSwitch (e1,cases,def) ->
		{ e with eexpr = TSwitch (f e1, List.map (fun (el,e2) -> List.map f el, f e2) cases, match def with None -> None | Some e -> Some (f e)); etype = ft e.etype }
	| TMatch (e1,(en,pl),cases,def) ->
		{ e with eexpr = TMatch (f e1, (en,List.map ft pl), List.map (fun (cl,params,e) -> cl, params, f e) cases, match def with None -> None | Some e -> Some (f e)); etype = ft e.etype }
	| TTry (e1,catches) ->
		{ e with eexpr = TTry (f e1, List.map (fun (v,t,e) -> v, ft t, f e) catches); etype = ft e.etype }
	| TReturn eo ->
		{ e with eexpr = TReturn (match eo with None -> None | Some e -> Some (f e)); etype = ft e.etype }
	| TCast (e1,t) ->
		{ e with eexpr = TCast (f e1,t); etype = ft e.etype }

let s_expr_kind e =
	match e.eexpr with
	| TConst _ -> "Const"
	| TLocal _ -> "Local"
	| TEnumField _ -> "EnumField"
	| TArray (_,_) -> "Array"
	| TBinop (_,_,_) -> "Binop"
	| TField (_,_) -> "Field"
	| TClosure _ -> "Closure"
	| TTypeExpr _ -> "TypeExpr"
	| TParenthesis _ -> "Parenthesis"
	| TObjectDecl _ -> "ObjectDecl"
	| TArrayDecl _ -> "ArrayDecl"
	| TCall (_,_) -> "Call"
	| TNew (_,_,_) -> "New"
	| TUnop (_,_,_) -> "Unop"
	| TFunction _ -> "Function"
	| TVars _ -> "Vars"
	| TBlock _ -> "Block"
	| TFor (_,_,_,_) -> "For"
	| TIf (_,_,_) -> "If"
	| TWhile (_,_,_) -> "While"
	| TSwitch (_,_,_) -> "Switch"
	| TMatch (_,_,_,_) -> "Match"
	| TTry (_,_) -> "Try"
	| TReturn _ -> "Return"
	| TBreak -> "Break"
	| TContinue -> "Continue"
	| TThrow _ -> "Throw"
	| TCast _ -> "Cast"

let rec s_expr s_type e =
	let sprintf = Printf.sprintf in
	let slist f l = String.concat "," (List.map f l) in
	let loop = s_expr s_type in
	let s_const = function
		| TInt i -> Int32.to_string i
		| TFloat s -> s ^ "f"
		| TString s -> sprintf "\"%s\"" (Ast.s_escape s)
		| TBool b -> if b then "true" else "false"
		| TNull -> "null"
		| TThis -> "this"
		| TSuper -> "super"
	in
	let str = (match e.eexpr with
	| TConst c ->
		"Const " ^ s_const c
	| TLocal s ->
		"Local " ^ s
	| TEnumField (e,f) ->
		sprintf "EnumField %s.%s" (s_type_path e.e_path) f
	| TArray (e1,e2) ->
		sprintf "%s[%s]" (loop e1) (loop e2)
	| TBinop (op,e1,e2) ->
		sprintf "(%s %s %s)" (loop e1) (s_binop op) (loop e2)
	| TField (e,f) ->
		sprintf "%s.%s" (loop e) f
	| TClosure (e,s) ->
		sprintf "Closure (%s,%s)" (loop e) s
	| TTypeExpr m ->
		sprintf "TypeExpr %s" (s_type_path (t_path m))
	| TParenthesis e ->
		sprintf "Parenthesis %s" (loop e)
	| TObjectDecl fl ->
		sprintf "ObjectDecl {%s)" (slist (fun (f,e) -> sprintf "%s : %s" f (loop e)) fl)
	| TArrayDecl el ->
		sprintf "ArrayDecl [%s]" (slist loop el)
	| TCall (e,el) ->
		sprintf "Call %s(%s)" (loop e) (slist loop el)
	| TNew (c,pl,el) ->
		sprintf "New %s%s(%s)" (s_type_path c.cl_path) (match pl with [] -> "" | l -> sprintf "<%s>" (slist s_type l)) (slist loop el)
	| TUnop (op,f,e) ->
		(match f with
		| Prefix -> sprintf "(%s %s)" (s_unop op) (loop e)
		| Postfix -> sprintf "(%s %s)" (loop e) (s_unop op))
	| TFunction f ->
		let args = slist (fun (n,o,t) -> sprintf "%s : %s%s" n (s_type t) (match o with None -> "" | Some c -> " = " ^ s_const c)) f.tf_args in
		sprintf "Function(%s) : %s = %s" args (s_type f.tf_type) (loop f.tf_expr)
	| TVars vl ->
		sprintf "Vars %s" (slist (fun (v,t,eo) -> sprintf "%s : %s%s" v (s_type t) (match eo with None -> "" | Some e -> " = " ^ loop e)) vl)
	| TBlock el ->
		sprintf "Block {\n%s}" (String.concat "" (List.map (fun e -> sprintf "%s;\n" (loop e)) el))
	| TFor (v,t,econd,e) ->
		sprintf "For (%s : %s in %s,%s)" v (s_type t) (loop econd) (loop e)
	| TIf (e,e1,e2) ->
		sprintf "If (%s,%s%s)" (loop e) (loop e1) (match e2 with None -> "" | Some e -> "," ^ loop e)
	| TWhile (econd,e,flag) ->
		(match flag with
		| NormalWhile -> sprintf "While (%s,%s)" (loop econd) (loop e)
		| DoWhile -> sprintf "DoWhile (%s,%s)" (loop e) (loop econd))
	| TSwitch (e,cases,def) ->
		sprintf "Switch (%s,(%s)%s)" (loop e) (slist (fun (cl,e) -> sprintf "case %s: %s" (slist loop cl) (loop e)) cases) (match def with None -> "" | Some e -> "," ^ loop e)
	| TMatch (e,(en,tparams),cases,def) ->
		let args vl = slist (fun (so,t) -> sprintf "%s : %s" (match so with None -> "_" | Some s -> s) (s_type t)) vl in
		let cases = slist (fun (il,vl,e) -> sprintf "case %s%s : %s" (slist string_of_int il) (match vl with None -> "" | Some vl -> sprintf "(%s)" (args vl)) (loop e)) cases in
		sprintf "Match %s (%s,(%s)%s)" (s_type (TEnum (en,tparams))) (loop e) cases (match def with None -> "" | Some e -> "," ^ loop e)
	| TTry (e,cl) ->
		sprintf "Try %s(%s) " (loop e) (slist (fun (v,t,e) -> sprintf "catch( %s : %s ) %s" v (s_type t) (loop e)) cl)
	| TReturn None ->
		"Return"
	| TReturn (Some e) ->
		sprintf "Return %s" (loop e)
	| TBreak ->
		"Break"
	| TContinue ->
		"Continue"
	| TThrow e ->
		"Throw " ^ (loop e)
	| TCast (e,t) ->
		sprintf "Cast %s%s" (match t with None -> "" | Some t -> s_type_path (t_path t) ^ ": ") (loop e)
	) in
	sprintf "(%s : %s)" str (s_type e.etype)
