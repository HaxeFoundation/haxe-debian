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
open Ast
open Type
open Common
open Typecore

(* ---------------------------------------------------------------------- *)
(* TOOLS *)

type switch_mode =
	| CMatch of (tenum_field * (string option * t) list option)
	| CExpr of texpr

type access_mode =
	| MGet
	| MSet
	| MCall

exception Display of t

type access_kind =
	| AccNo of string
	| AccExpr of texpr
	| AccSet of texpr * string * t * string
	| AccInline of texpr * tclass_field * t
	| AccUsing of texpr * texpr

let mk_infos ctx p params =
	(EObjectDecl (
		("fileName" , (EConst (String (Filename.basename p.pfile)) , p)) ::
		("lineNumber" , (EConst (Int (string_of_int (Lexer.get_error_line p))),p)) ::
		("className" , (EConst (String (s_type_path ctx.curclass.cl_path)),p)) ::
		if ctx.curmethod = "" then
			params
		else
			("methodName", (EConst (String ctx.curmethod),p)) :: params
	) ,p)

let check_locals_masking ctx e =
	let path = (match e.eexpr with
		| TEnumField (e,_)
		| TTypeExpr (TEnumDecl e) ->
			Some e.e_path
		| TTypeExpr (TClassDecl c) ->
			Some c.cl_path
		| _ -> None
	) in
	match path with
	| Some ([],name) | Some (name::_,_) when PMap.mem name ctx.locals ->
		error ("Local variable " ^ name ^ " is preventing usage of this type here") e.epos;
	| _ -> ()

let check_assign ctx e =
	match e.eexpr with
	| TLocal _ | TArray _ | TField _ ->
		()
	| TTypeExpr _ when ctx.untyped ->
		()
	| _ ->
		error "Invalid assign" e.epos

type type_class =
	| KInt
	| KFloat
	| KString
	| KUnk
	| KDyn
	| KOther
	| KParam of t

let classify t =
	match follow t with
	| TInst ({ cl_path = ([],"Int") },[]) -> KInt
	| TInst ({ cl_path = ([],"Float") },[]) -> KFloat
	| TInst ({ cl_path = ([],"String") },[]) -> KString
	| TInst ({ cl_kind = KTypeParameter; cl_implements = [{ cl_path = ([],"Float")},[]] },[]) -> KParam t
	| TInst ({ cl_kind = KTypeParameter; cl_implements = [{ cl_path = ([],"Int")},[]] },[]) -> KParam t
	| TMono r when !r = None -> KUnk
	| TDynamic _ -> KDyn
	| _ -> KOther

let type_field_rec = ref (fun _ _ _ _ _ -> assert false)

(* ---------------------------------------------------------------------- *)
(* PASS 3 : type expression & check structure *)

let type_expr_with_type ctx e t =
	match e with
	| (EFunction _,_) ->
		let old = ctx.param_type in
		(try
			ctx.param_type <- t;
			let e = type_expr ctx e true in
			ctx.param_type <- old;
			e
		with
			exc ->
				ctx.param_type <- old;
				raise exc)
	| _ ->
		type_expr ctx e true

let unify_call_params ctx name el args p inline =
	let error txt =
		let format_arg = (fun (name,opt,_) -> (if opt then "?" else "") ^ name) in
		let argstr = "Function " ^ (match name with None -> "" | Some n -> "'" ^ n ^ "' ") ^ "requires " ^ (if args = [] then "no arguments" else "arguments : " ^ String.concat ", " (List.map format_arg args)) in
		display_error ctx (txt ^ " arguments\n" ^ argstr) p
	in
	let arg_error ul name opt p =
		raise (Error (Stack (Unify ul,Custom ("For " ^ (if opt then "optional " else "") ^ "function argument '" ^ name ^ "'")), p))
	in
	let rec no_opt = function
		| [] -> []
		| ({ eexpr = TConst TNull },true) :: l -> no_opt l
		| l -> List.map fst l
	in
	let rec default_value t =
		let rec is_pos_infos = function
			| TMono r ->
				(match !r with
				| Some t -> is_pos_infos t
				| _ -> false)
			| TLazy f ->
				is_pos_infos (!f())
			| TType ({ t_path = ["haxe"] , "PosInfos" },[]) ->
				true
			| TType (t,tl) ->
				is_pos_infos (apply_params t.t_types tl t.t_type)
			| _ ->
				false
		in
		if is_pos_infos t then
			let infos = mk_infos ctx p [] in
			let e = type_expr ctx infos true in
			(e, true)
		else
			(null t p, true)
	in
	let rec loop acc l l2 skip =
		match l , l2 with
		| [] , [] ->
			if not (inline && ctx.doinline) && (Common.defined ctx.com "flash" || Common.defined ctx.com "js") then
				List.rev (no_opt acc)
			else
				List.rev (List.map fst acc)
		| [] , (_,false,_) :: _ ->
			error "Not enough";
			[]
		| [] , (name,true,t) :: l ->
			loop (default_value t :: acc) [] l skip
		| _ , [] ->
			(match List.rev skip with
			| [] -> error "Too many"
			| [name,ul] -> arg_error ul name true p
			| _ -> error "Invalid");
			[]
		| ee :: l, (name,opt,t) :: l2 ->
			let e = type_expr_with_type ctx ee (Some t) in
			try
				unify_raise ctx e.etype t e.epos;
				loop ((e,false) :: acc) l l2 skip
			with
				Error (Unify ul,_) ->
					if opt then
						loop (default_value t :: acc) (ee :: l) l2 ((name,ul) :: skip)
					else						
						arg_error ul name false e.epos
	in
	loop [] el args []

let type_local ctx i p =
	(* local lookup *)
	let t = PMap.find i ctx.locals in
	let i = (try PMap.find i ctx.locals_map with Not_found -> i) in
	mk (TLocal i) t p

let rec type_module_type ctx t tparams p =
	match t with
	| TClassDecl c ->
		let t_tmp = {
			t_path = fst c.cl_path, "#" ^ snd c.cl_path;
			t_doc = None;
			t_pos = c.cl_pos;
			t_type = TAnon {
				a_fields = c.cl_statics;
				a_status = ref (Statics c);
			};
			t_private = true;
			t_types = [];
			t_meta = no_meta;
		} in
		let e = mk (TTypeExpr (TClassDecl c)) (TType (t_tmp,[])) p in
		check_locals_masking ctx e;
		e
	| TEnumDecl e ->
		let types = (match tparams with None -> List.map (fun _ -> mk_mono()) e.e_types | Some l -> l) in
		let fl = PMap.fold (fun f acc ->
			PMap.add f.ef_name {
				cf_name = f.ef_name;
				cf_public = true;
				cf_type = f.ef_type;
				cf_get = NormalAccess;
				cf_set = (match follow f.ef_type with TFun _ -> MethodAccess false | _ -> NoAccess);
				cf_doc = None;
				cf_meta = no_meta;
				cf_expr = None;
				cf_params = [];
			} acc
		) e.e_constrs PMap.empty in
		let t_tmp = {
			t_path = fst e.e_path, "#" ^ snd e.e_path;
			t_doc = None;
			t_pos = e.e_pos;
			t_type = TAnon {
				a_fields = fl;
				a_status = ref (EnumStatics e);
			};
			t_private = true;
			t_types = e.e_types;
			t_meta = no_meta;
		} in
		let e = mk (TTypeExpr (TEnumDecl e)) (TType (t_tmp,types)) p in
		check_locals_masking ctx e;
		e
	| TTypeDecl s ->
		let t = apply_params s.t_types (List.map (fun _ -> mk_mono()) s.t_types) s.t_type in
		match follow t with
		| TEnum (e,params) ->
			type_module_type ctx (TEnumDecl e) (Some params) p
		| TInst (c,params) ->
			type_module_type ctx (TClassDecl c) (Some params) p
		| _ ->
			error (s_type_path s.t_path ^ " is not a value") p

let type_type ctx tpath p =
	type_module_type ctx (Typeload.load_type_def ctx p { tpackage = fst tpath; tname = snd tpath; tparams = []; tsub = None }) None p

let get_constructor c p =
	let rec loop c = 
		match c.cl_constructor with 
		| Some f -> f 
		| None ->
			if not c.cl_extern then raise Not_found;
			match c.cl_super with
			| None -> raise Not_found
			| Some (csup,[]) -> loop csup
			| Some (_,_) -> error (s_type_path c.cl_path ^ " must define its own constructor") p
	in
	try
		loop c
	with Not_found ->
		error (s_type_path c.cl_path ^ " does not have a constructor") p

let make_call ctx e params t p =
	try
		if not ctx.doinline then raise Exit;
		let ethis, fname = (match e.eexpr with TField (ethis,fname) -> ethis, fname | _ -> raise Exit) in
		let f = (match follow ethis.etype with
			| TInst (c,params) -> snd (try class_field c fname with Not_found -> raise Exit)
			| TAnon a -> (try PMap.find fname a.a_fields with Not_found -> raise Exit)
			| _ -> raise Exit
		) in
		if f.cf_get <> InlineAccess then raise Exit;
		ignore(follow f.cf_type); (* force evaluation *)
		(match f.cf_expr with
		| Some { eexpr = TFunction fd } ->
			(match Optimizer.type_inline ctx f fd ethis params t p with
			| None -> raise Exit
			| Some e -> e)
		| _ -> 
			error "Recursive inline is not supported" p)
	with Exit ->
		mk (TCall (e,params)) t p
		
let rec acc_get ctx g p =
	match g with
	| AccNo f -> error ("Field " ^ f ^ " cannot be accessed for reading") p
	| AccExpr e -> e
	| AccSet _ -> assert false
	| AccUsing (et,e) ->
		(* build a closure with first parameter applied *)
		(match follow et.etype with
		| TFun (_ :: args,ret) ->
			let tcallb = TFun (args,ret) in	
			let twrap = TFun ([("_e",false,e.etype)],tcallb) in
			let ecall = make_call ctx et (List.map (fun (n,_,t) -> mk (TLocal n) t p) (("_e",false,e.etype) :: args)) ret p in
			let ecallb = mk (TFunction {
				tf_args = List.map (fun (n,_,t) -> n,None,t) args;
				tf_type = ret;
				tf_expr = mk (TReturn (Some ecall)) t_dynamic p;
			}) tcallb p in
			let ewrap = mk (TFunction {
				tf_args = [("_e",None,e.etype)];
				tf_type = tcallb;
				tf_expr = mk (TReturn (Some ecallb)) t_dynamic p; 
			}) twrap p in
			make_call ctx ewrap [e] tcallb p
		| _ -> assert false)
	| AccInline (e,f,t) ->
		ignore(follow f.cf_type); (* force computing *)
		match f.cf_expr with
		| None -> error "Recursive inline is not supported" p
		| Some { eexpr = TFunction _ } ->  mk (TClosure (e,f.cf_name)) t p
		| Some e -> 
			let rec loop e = Type.map_expr loop { e with epos = p } in
			loop e

let field_access ctx mode f t e p =
	let normal() = AccExpr (mk (TField (e,f.cf_name)) t p) in
	match (match mode with MGet | MCall -> f.cf_get | MSet -> f.cf_set) with
	| NoAccess ->
		(match follow e.etype with
		| TInst (c,_) when is_parent c ctx.curclass -> normal()
		| TAnon a ->
			(match !(a.a_status) with
			| Statics c2 when ctx.curclass == c2 -> normal()
			| _ -> if ctx.untyped then normal() else AccNo f.cf_name)
		| _ ->
			if ctx.untyped then normal() else AccNo f.cf_name)
	| MethodAccess false when not ctx.untyped ->
		error "Cannot rebind this method : please use 'dynamic' before method declaration" p
	| NormalAccess | MethodAccess _ ->
		(* 
			creates a closure if we're reading a normal method
			or a read-only variable (which could be a method)
		*)
		(match mode, f.cf_set with
		| MGet, MethodAccess _ -> AccExpr (mk (TClosure (e,f.cf_name)) t p)
		| MGet, NoAccess | MGet, NeverAccess when (match follow t with TFun _ -> true | _ -> false) -> AccExpr (mk (TClosure (e,f.cf_name)) t p)
		| _ ->
			match follow e.etype with
			| TAnon a -> (match !(a.a_status) with EnumStatics e -> AccExpr (mk (TEnumField (e,f.cf_name)) t p) | _ -> normal())
			| _ -> normal())
	| CallAccess m ->
		if m = ctx.curmethod && (match e.eexpr with TConst TThis -> true | TTypeExpr (TClassDecl c) when c == ctx.curclass -> true | _ -> false) then
			let prefix = if Common.defined ctx.com "as3" then "$" else "" in
			AccExpr (mk (TField (e,prefix ^ f.cf_name)) t p)
		else if mode = MSet then
			AccSet (e,m,t,f.cf_name)
		else
			AccExpr (make_call ctx (mk (TField (e,m)) (tfun [] t) p) [] t p)
	| ResolveAccess ->
		let fstring = mk (TConst (TString f.cf_name)) ctx.api.tstring p in
		let tresolve = tfun [ctx.api.tstring] t in
		AccExpr (make_call ctx (mk (TField (e,"resolve")) tresolve p) [fstring] t p)
	| NeverAccess ->
		AccNo f.cf_name
	| InlineAccess ->
		AccInline (e,f,t)

let using_field ctx mode e i p =
	if mode = MSet then raise Not_found;
	let rec loop = function
		| [] ->
			raise Not_found
		| TEnumDecl _ :: l | TTypeDecl _ :: l ->
			loop l
		| TClassDecl c :: l ->
			try
				let f = PMap.find i c.cl_statics in
				let t = field_type f in
				(match follow t with
				| TFun ((_,_,t0) :: args,r) ->
					(try unify_raise ctx e.etype t0 p with Error (Unify _,_) -> raise Not_found);
					if follow e.etype == t_dynamic && follow t0 != t_dynamic then raise Not_found;
					let et = type_module_type ctx (TClassDecl c) None p in						
					AccUsing (mk (TField (et,i)) t p,e)
				| _ -> raise Not_found)
			with Not_found ->
				loop l
	in
	loop ctx.local_using

let type_ident ctx i is_type p mode =
	match i with
	| "true" ->
		if mode = MGet then
			AccExpr (mk (TConst (TBool true)) ctx.api.tbool p)
		else
			AccNo i
	| "false" ->
		if mode = MGet then
			AccExpr (mk (TConst (TBool false)) ctx.api.tbool p)
		else
			AccNo i
	| "this" ->
		if not ctx.untyped && ctx.in_static then error "Cannot access this from a static function" p;
		if mode = MGet then
			AccExpr (mk (TConst TThis) ctx.tthis p)
		else
			AccNo i
	| "super" ->
		let t = (match ctx.curclass.cl_super with
			| None -> error "Current class does not have a superclass" p
			| Some (c,params) -> TInst(c,params)
		) in
		if ctx.in_static then error "Cannot access super from a static function" p;
		if mode = MSet || not ctx.super_call then
			AccNo i
		else begin
			ctx.super_call <- false;
			AccExpr (mk (TConst TSuper) t p)
		end
	| "null" ->
		if mode = MGet then
			AccExpr (null (mk_mono()) p)
		else
			AccNo i
	| "here" ->
		let infos = mk_infos ctx p [] in
		let e = type_expr ctx infos true in
		if mode = MGet then
			AccExpr { e with etype = Typeload.load_instance ctx { tpackage = ["haxe"]; tname = "PosInfos"; tparams = []; tsub = None } p false }
		else
			AccNo i
	| _ ->
	try
		let e = type_local ctx i p in
		AccExpr e
	with Not_found -> try
		(* member variable lookup *)
		if ctx.in_static then raise Not_found;
		let t , f = class_field ctx.curclass i in
		field_access ctx mode f t (mk (TConst TThis) ctx.tthis p) p
	with Not_found -> try
		using_field ctx mode (mk (TConst TThis) ctx.tthis p) i p
	with Not_found -> try
		(* static variable lookup *)
		let f = PMap.find i ctx.curclass.cl_statics in
		let e = type_type ctx ctx.curclass.cl_path p in
		field_access ctx mode f (field_type f) e p
	with Not_found -> try
		(* lookup imported *)
		let rec loop l =
			match l with
			| [] -> raise Not_found
			| t :: l ->
				match t with
				| TClassDecl _ | TTypeDecl _ ->
					loop l
				| TEnumDecl e ->
					try
						let ef = PMap.find i e.e_constrs in
						mk (TEnumField (e,i)) (monomorphs e.e_types ef.ef_type) p
					with
						Not_found -> loop l
		in
		let e = loop ctx.local_types in
		check_locals_masking ctx e;
		if mode = MSet then
			AccNo i
		else
			AccExpr e
	with Not_found -> try
		(* lookup type *)
		if not is_type then raise Not_found;
		let e = (try type_type ctx ([],i) p with Error (Module_not_found ([],name),_) when name = i -> raise Not_found) in
		AccExpr e
	with Not_found ->
		if ctx.untyped then
			AccExpr (mk (TLocal i) (mk_mono()) p)
		else begin
			if ctx.in_static && PMap.mem i ctx.curclass.cl_fields then error ("Cannot access " ^ i ^ " in static function") p;
			raise (Error (Unknown_ident i,p))
		end

let type_matching ctx (enum,params) (e,p) ecases first_case =
	let invalid() = raise (Error (Invalid_enum_matching,p)) in
	let needs n = error ("This constructor needs " ^ string_of_int n ^ " parameters") p in
	let constr name =
		if PMap.mem name (!ecases) then error "This constructor has already been used" p;
		ecases := PMap.add name () (!ecases);
		try
			PMap.find name enum.e_constrs
		with
			Not_found -> error ("This constructor is not part of the enum " ^ s_type_path enum.e_path) p
	in
	match e with
	| EConst (Ident name) | EConst (Type name) ->
		let c = constr name in
		(match c.ef_type with
			| TFun (l,_) -> needs (List.length l)
			| TEnum _ -> ()
			| _ -> assert false
		);
		(c,None)
	| ECall ((EConst (Ident name),_),el)
	| ECall ((EConst (Type name),_),el) ->
		let c = constr name in
		let args = (match c.ef_type with
			| TFun (l,_) ->
				if List.length l <> List.length el then needs (List.length l);
				List.map (fun (_,_,t) -> apply_params enum.e_types params t) l
			| TEnum _ -> error "This constructor does not take any parameter" p
			| _ -> assert false
		) in
		let idents = List.map2 (fun (e,_) t ->
			match e with
			| EConst (Ident "_") ->
				None , t
			| EConst (Ident name) | EConst (Type name) ->
				let name = (if first_case then add_local ctx name t else try PMap.find name ctx.locals_map with Not_found -> name) in
				Some name , t
			| _ -> invalid()
		) el args in
		(c,Some idents)
	| _ ->
		invalid()

let rec type_field ctx e i p mode =
	let no_field() =
		if not ctx.untyped then display_error ctx (s_type (print_context()) e.etype ^ " has no field " ^ i) p;
		AccExpr (mk (TField (e,i)) (mk_mono()) p)
	in
	match follow e.etype with
	| TInst (c,params) ->
		let rec loop_dyn c params =
			match c.cl_dynamic with
			| Some t ->
				let t = apply_params c.cl_types params t in
				if mode = MGet && PMap.mem "resolve" c.cl_fields then
					AccExpr (make_call ctx (mk (TField (e,"resolve")) (tfun [ctx.api.tstring] t) p) [Typeload.type_constant ctx (String i) p] t p)
				else
					AccExpr (mk (TField (e,i)) t p)
			| None ->
				match c.cl_super with
				| None -> raise Not_found
				| Some (c,params) -> loop_dyn c params
		in
		(try
			let t , f = class_field c i in
			if e.eexpr = TConst TSuper && f.cf_set = NormalAccess && Common.platform ctx.com Flash9 then error "Cannot access superclass variable for calling : needs to be a proper method" p;
			if not f.cf_public && not (is_parent c ctx.curclass) && not ctx.untyped then display_error ctx ("Cannot access to private field " ^ i) p;
			field_access ctx mode f (apply_params c.cl_types params t) e p
		with Not_found -> try
			using_field ctx mode e i p
		with Not_found -> try
			loop_dyn c params
		with Not_found ->
			if PMap.mem i c.cl_statics then error ("Cannot access static field " ^ i ^ " from a class instance") p;
			no_field())
	| TDynamic t ->
		AccExpr (mk (TField (e,i)) t p)
	| TAnon a ->
		(try
			let f = PMap.find i a.a_fields in
			if not f.cf_public && not ctx.untyped then begin
				match !(a.a_status) with
				| Closed -> () (* always allow anon private fields access *)
				| Statics c when is_parent c ctx.curclass -> ()
				| _ -> display_error ctx ("Cannot access to private field " ^ i) p
			end;
			field_access ctx mode f (field_type f) e p
		with Not_found ->
			if is_closed a then try
				using_field ctx mode e i p
			with Not_found ->
				no_field()
			else
			let f = {
				cf_name = i;
				cf_type = mk_mono();
				cf_doc = None;
				cf_meta = no_meta;
				cf_public = true;
				cf_get = NormalAccess;
				cf_set = (match mode with MSet -> NormalAccess | MGet | MCall -> NoAccess);
				cf_expr = None;
				cf_params = [];
			} in
			a.a_fields <- PMap.add i f a.a_fields;
			field_access ctx mode f (field_type f) e p
		)
	| TMono r ->
		if ctx.untyped && Common.defined ctx.com "swf-mark" && Common.defined ctx.com "flash" then ctx.com.warning "Mark" p;
		let f = {
			cf_name = i;
			cf_type = mk_mono();
			cf_doc = None;
			cf_meta = no_meta;
			cf_public = true;
			cf_get = NormalAccess;
			cf_set = (match mode with MSet -> NormalAccess | MGet | MCall -> NoAccess);
			cf_expr = None;
			cf_params = [];
		} in
		let x = ref Opened in
		let t = TAnon { a_fields = PMap.add i f PMap.empty; a_status = x } in
		ctx.opened <- x :: ctx.opened;
		r := Some t;
		field_access ctx mode f (field_type f) e p
	| _ ->
		try using_field ctx mode e i p with Not_found -> no_field()

(*
	We want to try unifying as an integer and apply side effects.
	However, in case the value is not a normal Monomorph but one issued
	from a Dynamic relaxation, we will instead unify with float since
	we don't want to accidentaly truncate the value
*)
let unify_int ctx e k =
	let is_dynamic t = 
		match follow t with
		| TDynamic _ -> true
		| _ -> false
	in
	let is_dynamic_array t =
		match follow t with 
		| TInst (_,[p]) -> is_dynamic p
		| _ -> true
	in
	let is_dynamic_field t f =
		match follow t with
		| TAnon a ->
			(try is_dynamic (PMap.find f a.a_fields).cf_type with Not_found -> true)
		| _ -> true
	in
	let is_dynamic_return t =
		match follow t with
		| TFun (_,r) -> is_dynamic r
		| _ -> true
	in
	let maybe_dynamic_mono() =
		match e.eexpr with		
		| TLocal _ when not (is_dynamic e.etype)  -> false
		| TArray({ etype = t },_) when not (is_dynamic_array t) -> false
		| TField({ etype = t },f) when not (is_dynamic_field t f) -> false
		| TCall({ etype = t },_) when not (is_dynamic_return t) -> false
		| _ -> true
	in
	match k with
	| KUnk | KDyn when maybe_dynamic_mono() ->
		unify ctx e.etype ctx.api.tfloat e.epos;
		false
	| _ ->
		unify ctx e.etype ctx.api.tint e.epos;
		true		

let rec type_binop ctx op e1 e2 p =
	match op with
	| OpAssign ->
		let e1 = type_access ctx (fst e1) (snd e1) MSet in
		let e2 = type_expr_with_type ctx e2 (match e1 with AccNo _ | AccInline _ | AccUsing _ -> None | AccExpr e | AccSet(e,_,_,_) -> Some e.etype) in
		(match e1 with
		| AccNo s -> error ("Cannot access field or identifier " ^ s ^ " for writing") p
		| AccExpr e1 ->
			unify ctx e2.etype e1.etype p;
			check_assign ctx e1;
			(match e1.eexpr , e2.eexpr with
			| TLocal i1 , TLocal i2
			| TField ({ eexpr = TConst TThis },i1) , TField ({ eexpr = TConst TThis },i2) when i1 = i2 ->
				error "Assigning a value to itself" p
			| _ , _ -> ());
			mk (TBinop (op,e1,e2)) e1.etype p
		| AccSet (e,m,t,_) ->
			unify ctx e2.etype t p;
			make_call ctx (mk (TField (e,m)) (tfun [t] t) p) [e2] t p
		| AccInline _ | AccUsing _ ->
			assert false)
	| OpAssignOp op ->
		(match type_access ctx (fst e1) (snd e1) MSet with
		| AccNo s -> error ("Cannot access field or identifier " ^ s ^ " for writing") p
		| AccExpr e ->
			let eop = type_binop ctx op e1 e2 p in
			(match eop.eexpr with
			| TBinop (_,_,e2) ->
				unify ctx eop.etype e.etype p;
				check_assign ctx e;
				mk (TBinop (OpAssignOp op,e,e2)) e.etype p;
			| _ ->
				assert false)
		| AccSet (e,m,t,f) ->
			let l = save_locals ctx in
			let v = gen_local ctx e.etype in
			let ev = mk (TLocal v) e.etype p in
			let get = type_binop ctx op (EField ((EConst (Ident v),p),f),p) e2 p in
			unify ctx get.etype t p;
			l();
			mk (TBlock [
				mk (TVars [v,e.etype,Some e]) ctx.api.tvoid p;
				make_call ctx (mk (TField (ev,m)) (tfun [t] t) p) [get] t p
			]) t p
		| AccInline _ | AccUsing _ ->
			assert false)
	| _ ->
	let e1 = type_expr ctx e1 in
	let e2 = type_expr ctx e2 in
	let mk_op t = mk (TBinop (op,e1,e2)) t p in
	match op with
	| OpAdd ->
		mk_op (match classify e1.etype, classify e2.etype with
		| KInt , KInt ->
			ctx.api.tint
		| KFloat , KInt
		| KInt, KFloat
		| KFloat, KFloat ->
			ctx.api.tfloat
		| KUnk , KInt ->
			if unify_int ctx e1 KUnk then ctx.api.tint else ctx.api.tfloat
		| KUnk , KFloat
		| KUnk , KString  ->
			unify ctx e1.etype e2.etype e1.epos;
			e1.etype
		| KInt , KUnk ->
			if unify_int ctx e2 KUnk then ctx.api.tint else ctx.api.tfloat
		| KFloat , KUnk
		| KString , KUnk ->
			unify ctx e2.etype e1.etype e2.epos;
			e2.etype
		| _ , KString
		| _ , KDyn ->
			e2.etype
		| KString , _
		| KDyn , _ ->
			e1.etype
		| KUnk , KUnk ->
			let ok1 = unify_int ctx e1 KUnk in
			let ok2 = unify_int ctx e2 KUnk in
			if ok1 && ok2 then ctx.api.tint else ctx.api.tfloat
		| KParam t1, KParam t2 when t1 == t2 ->
			t1
		| KParam t, KInt | KInt, KParam t ->
			t
		| KParam _, KFloat | KFloat, KParam _ | KParam _, KParam _ ->
			ctx.api.tfloat
		| KParam _, _
		| _, KParam _
		| KOther, _
		| _ , KOther ->
			let pr = print_context() in
			error ("Cannot add " ^ s_type pr e1.etype ^ " and " ^ s_type pr e2.etype) p
		)
	| OpAnd
	| OpOr
	| OpXor
	| OpShl
	| OpShr
	| OpUShr ->
		let i = ctx.api.tint in
		unify ctx e1.etype i e1.epos;
		unify ctx e2.etype i e2.epos;
		mk_op i
	| OpMod
	| OpMult
	| OpDiv
	| OpSub ->
		let result = ref (if op = OpDiv then ctx.api.tfloat else ctx.api.tint) in
		(match classify e1.etype, classify e2.etype with
		| KFloat, KFloat ->
			result := ctx.api.tfloat
		| KParam t1, KParam t2 when t1 == t2 ->
			if op <> OpDiv then result := t1
		| KParam _, KParam _ ->
			result := ctx.api.tfloat
		| KParam t, KInt | KInt, KParam t ->
			if op <> OpDiv then result := t
		| KParam _, KFloat | KFloat, KParam _ ->
			result := ctx.api.tfloat
		| KFloat, k ->
			ignore(unify_int ctx e2 k);
			result := ctx.api.tfloat
		| k, KFloat ->
			ignore(unify_int ctx e1 k);
			result := ctx.api.tfloat
		| k1 , k2 ->
			let ok1 = unify_int ctx e1 k1 in
			let ok2 = unify_int ctx e2 k2 in
			if not ok1 || not ok2  then result := ctx.api.tfloat;
		);
		mk_op !result
	| OpEq
	| OpNotEq ->
		(try
			unify_raise ctx e1.etype e2.etype p
		with
			Error (Unify _,_) -> unify ctx e2.etype e1.etype p);
		mk_op ctx.api.tbool
	| OpGt
	| OpGte
	| OpLt
	| OpLte ->
		(match classify e1.etype, classify e2.etype with
		| KInt , KInt | KInt , KFloat | KFloat , KInt | KFloat , KFloat | KString , KString -> ()
		| KInt , KUnk -> ignore(unify_int ctx e2 KUnk)
		| KFloat , KUnk | KString , KUnk -> unify ctx e2.etype e1.etype e2.epos
		| KUnk , KInt -> ignore(unify_int ctx e1 KUnk)
		| KUnk , KFloat | KUnk , KString -> unify ctx e1.etype e2.etype e1.epos
		| KUnk , KUnk ->
			ignore(unify_int ctx e1 KUnk);
			ignore(unify_int ctx e2 KUnk);
		| KDyn , KInt | KDyn , KFloat | KDyn , KString -> ()
		| KInt , KDyn | KFloat , KDyn | KString , KDyn -> ()
		| KDyn , KDyn -> ()
		| KParam _ , x | x , KParam _ when x <> KString && x <> KOther -> ()
		| KDyn , KUnk
		| KUnk , KDyn
		| KString , KInt
		| KString , KFloat
		| KInt , KString
		| KFloat , KString
		| KParam _ , _
		| _ , KParam _
		| KOther , _
		| _ , KOther ->
			let pr = print_context() in
			error ("Cannot compare " ^ s_type pr e1.etype ^ " and " ^ s_type pr e2.etype) p
		);
		mk_op ctx.api.tbool
	| OpBoolAnd
	| OpBoolOr ->
		let b = ctx.api.tbool in
		unify ctx e1.etype b p;
		unify ctx e2.etype b p;
		mk_op b
	| OpInterval ->
		let i = ctx.api.tint in
		let t = Typeload.load_core_type ctx "IntIter" in
		unify ctx e1.etype i e1.epos;
		unify ctx e2.etype i e2.epos;
		mk (TNew ((match t with TInst (c,[]) -> c | _ -> assert false),[],[e1;e2])) t p
	| OpAssign
	| OpAssignOp _ ->
		assert false

and type_unop ctx op flag e p =
	let set = (op = Increment || op = Decrement) in
	let acc = type_access ctx (fst e) (snd e) (if set then MSet else MGet) in
	let access e =
		let t = (match op with
		| Not ->
			unify ctx e.etype ctx.api.tbool e.epos;
			ctx.api.tbool
		| Increment
		| Decrement
		| Neg
		| NegBits ->
			if set then check_assign ctx e;
			(match classify e.etype with
			| KFloat -> ctx.api.tfloat
			| KParam t ->
				unify ctx e.etype ctx.api.tfloat e.epos;
				t
			| k ->
				if unify_int ctx e k then ctx.api.tint else ctx.api.tfloat)
		) in
		match op, e.eexpr with
		| Neg , TConst (TInt i) -> mk (TConst (TInt (Int32.neg i))) t p
		| Neg , TConst (TFloat f) when f.[0] != '-' -> mk (TConst (TFloat ("-" ^ f))) t p
		| _ -> mk (TUnop (op,flag,e)) t p
	in
	match acc with
	| AccExpr e -> access e
	| AccInline _ | AccUsing _ when not set -> access (acc_get ctx acc p)
	| AccNo s ->
		error ("The field or identifier " ^ s ^ " is not accessible for " ^ (if set then "writing" else "reading")) p
	| AccInline _ | AccUsing _ ->
		error "This kind of operation is not supported" p
	| AccSet (e,m,t,f) ->
		let l = save_locals ctx in
		let v = gen_local ctx e.etype in
		let ev = mk (TLocal v) e.etype p in
		let op = (match op with Increment -> OpAdd | Decrement -> OpSub | _ -> assert false) in
		let one = (EConst (Int "1"),p) in
		let eget = (EField ((EConst (Ident v),p),f),p) in
		match flag with
		| Prefix ->
			let get = type_binop ctx op eget one p in
			unify ctx get.etype t p;
			l();
			mk (TBlock [
				mk (TVars [v,e.etype,Some e]) ctx.api.tvoid p;
				make_call ctx (mk (TField (ev,m)) (tfun [t] t) p) [get] t p
			]) t p
		| Postfix ->
			let v2 = gen_local ctx t in
			let ev2 = mk (TLocal v2) t p in
			let get = type_expr ctx eget in
			let plusone = type_binop ctx op (EConst (Ident v2),p) one p in
			unify ctx get.etype t p;
			l();
			mk (TBlock [
				mk (TVars [v,e.etype,Some e; v2,t,Some get]) ctx.api.tvoid p;
				make_call ctx (mk (TField (ev,m)) (tfun [plusone.etype] t) p) [plusone] t p;
				ev2
			]) t p

and type_switch ctx e cases def need_val p =
	let e = type_expr ctx e in
	let t = ref (if need_val then mk_mono() else ctx.api.tvoid) in
	let rec lookup_enum l =
		match l with
		| [] -> None
		| (ECall ((EConst (Type name),p),_),_) :: l
		| (ECall ((EConst (Ident name),p),_),_) :: l
		| (EConst (Ident name),p) :: l
		| (EConst (Type name),p) :: l ->
			(try
				let e = acc_get ctx (type_ident ctx name false p MGet) p in
				(match e.eexpr with
				| TEnumField (e,_) -> Some (e, List.map (fun _ -> mk_mono()) e.e_types)
				| _ -> None)
			with
				Error (Unknown_ident _,_) -> lookup_enum l)
		| _ ->
			None
	in
	let enum = ref (match follow e.etype with
		| TEnum ({ e_path = [],"Bool" },_)
		| TEnum ({ e_path = ["flash"],_ ; e_extern = true },_) ->
			None
		| TEnum (e,params) -> Some (e,params)
		| TMono r ->
			(match lookup_enum (List.concat (List.map fst cases)) with
			| None -> None
			| Some (en,params) as k ->
				r := Some (TEnum (en,params));
				k)
		| _ -> None
	) in
	let unify_val e =
		if need_val then begin
			try
				(match e.eexpr with
				| TBlock [{ eexpr = TConst TNull }] -> t := ctx.api.tnull !t;
				| _ -> ());
				unify_raise ctx e.etype (!t) e.epos;
				if is_null e.etype then t := ctx.api.tnull !t;
			with Error (Unify _,_) -> try
				unify_raise ctx (!t) e.etype e.epos;
				t := if is_null !t then ctx.api.tnull e.etype else e.etype;
			with Error (Unify _,_) ->
				(* will display the error *)
				unify ctx e.etype (!t) e.epos;
		end;
	in
	let first = ref true in
	let ecases = ref PMap.empty in
	let type_case e e1 =
		let e1 = type_expr ctx e1 in
		(* this inversion is needed *)
		unify ctx e.etype e1.etype e1.epos;
		CExpr e1
	in
	let cases = List.map (fun (el,e2) ->
		let locals = save_locals ctx in
		let first_case = ref true in
		let el = List.map (fun e1 ->
			let v = (match !enum with
			| Some en ->
				(try
					CMatch (type_matching ctx en e1 ecases !first_case)
				with
					Error (Invalid_enum_matching,_) when !first ->
						enum := None;
						type_case e e1)
			| None ->
				type_case e e1
			) in
			first_case := false;
			first := false;
			v
		) el in
		if el = [] then error "Case must match at least one expression" (pos e2);
		let e2 = (match fst e2 with 
			| EBlock [] -> mk (TConst TNull) ctx.api.tvoid (pos e2)
			| _ -> type_expr ctx ~need_val e2
		) in
		locals();
		unify_val e2;
		(el,e2)
	) cases in
	let def = (match def with
		| None ->
		(match !enum with
			| None -> ()
			| Some (e,_) ->
				let l = PMap.fold (fun c acc ->
					if PMap.mem c.ef_name (!ecases) then acc else c.ef_name :: acc
				) e.e_constrs [] in
				match l with
				| [] -> ()
				| _ -> display_error ctx ("Some constructors are not matched : " ^ String.concat "," l) p
			);
			if need_val then Some (null (mk_mono()) p) else None
		| Some e ->
			let e = type_expr ctx ~need_val e in
			unify_val e;
			Some e
	) in
	let same_params p1 p2 =
		let l1 = (match p1 with None -> [] | Some l -> l) in
		let l2 = (match p2 with None -> [] | Some l -> l) in
		let rec loop = function
			| [] , [] -> true
			| (n,_) :: l , [] | [] , (n,_) :: l -> n = None && loop (l,[])
			| (n1,t1) :: l1, (n2,t2) :: l2 ->
				n1 = n2 && (n1 = None || type_iseq t1 t2) && loop (l1,l2)
		in
		loop (l1,l2)
	in
	let t = !t in
	match !enum with
	| None ->
		let consts = Hashtbl.create 0 in
		let exprs (el,e) =
			List.map (fun c ->
				match c with
				| CExpr (({ eexpr = TConst c }) as e) ->
					if Hashtbl.mem consts c then error "Duplicate constant in switch" e.epos;
					Hashtbl.add consts c true;
					e
				| CExpr c -> c
				| _ -> assert false
			) el , e
		in
		mk (TSwitch (e,List.map exprs cases,def)) t p
	| Some (en,enparams) ->
		let matchs (el,e) =
			match el with
			| CMatch (c,params) :: l ->
				let params = ref params in
				let cl = List.map (fun c ->
					match c with
					| CMatch (c,p) ->
						if not (same_params p !params) then display_error ctx "Constructors parameters differs : should be same name, same type, and same position" e.epos;
						if p <> None then params := p;
						c
					| _ -> assert false
				) l in
				(c :: cl) , !params, e
			| _ ->
				assert false
		in
		let indexes (el,vars,e) =
			List.map (fun c -> c.ef_index) el, vars, e
		in
		let cases = List.map matchs cases in
		mk (TMatch (e,(en,enparams),List.map indexes cases,def)) t p

and type_access ctx e p mode =
	match e with
	| EConst (Ident s) ->
		type_ident ctx s false p mode
	| EConst (Type s) ->
		type_ident ctx s true p mode
	| EField _
	| EType _ ->
		let fields path e =
			List.fold_left (fun e (f,_,p) ->
				let e = acc_get ctx (e MGet) p in
				type_field ctx e f p
			) e path
		in
		let type_path path =
			let rec loop acc path =
				match path with
				| [] ->
					(match List.rev acc with
					| [] -> assert false
					| (name,flag,p) :: path ->
						try
							fields path (type_access ctx (EConst (if flag then Type name else Ident name)) p)
						with
							Error (Unknown_ident _,p2) as e when p = p2 ->
								try
									let path = ref [] in
									let name , _ , _ = List.find (fun (name,flag,p) ->
										if flag then
											true
										else begin
											path := name :: !path;
											false
										end
									) (List.rev acc) in
									raise (Error (Module_not_found (List.rev !path,name),p))
								with
									Not_found ->
										if ctx.in_display then raise (Parser.TypePath (List.map (fun (n,_,_) -> n) (List.rev acc),None));
										raise e)
				| (_,false,_) as x :: path ->
					loop (x :: acc) path
				| (name,true,p) as x :: path ->
					let pack = List.rev_map (fun (x,_,_) -> x) acc in
					try
						let e = type_type ctx (pack,name) p in
						fields path (fun _ -> AccExpr e)
					with
						Error (Module_not_found m,_) when m = (pack,name) ->
							loop ((List.rev path) @ x :: acc) []
			in
			match path with
			| [] -> assert false
			| (name,_,p) :: pnext ->
				try
					fields pnext (fun _ -> AccExpr (type_local ctx name p))
				with
					Not_found -> loop [] path
		in
		let rec loop acc e =
			match fst e with
			| EField (e,s) ->
				loop ((s,false,p) :: acc) e
			| EType (e,s) ->
				loop ((s,true,p) :: acc) e
			| EConst (Ident i) ->
				type_path ((i,false,p) :: acc)
			| _ ->
				fields acc (type_access ctx (fst e) (snd e))
		in
		loop [] (e,p) mode
	| EArray (e1,e2) ->
		let e1 = type_expr ctx e1 in
		let e2 = type_expr ctx e2 in
		unify ctx e2.etype ctx.api.tint e2.epos;
		let rec loop et =
			match follow et with
			| TInst ({ cl_array_access = Some t; cl_types = pl },tl) ->
				apply_params pl tl t
			| TInst ({ cl_super = Some (c,stl); cl_types = pl },tl) ->
				apply_params pl tl (loop (TInst (c,stl)))
			| TInst ({ cl_path = [],"ArrayAccess" },[t]) ->
				t
			| _ -> 
				let pt = mk_mono() in
				let t = ctx.api.tarray pt in
				unify ctx e1.etype t e1.epos;
				pt
		in
		let pt = loop e1.etype in
		AccExpr (mk (TArray (e1,e2)) pt p)
	| _ ->
		AccExpr (type_expr ctx (e,p))

and type_expr ctx ?(need_val=true) (e,p) =
	match e with
	| EField ((EConst (String s),p),"code") ->
		if UTF8.length s <> 1 then error "String must be a single UTF8 char" p;
		mk (TConst (TInt (Int32.of_int (UChar.code (UTF8.get s 0))))) ctx.api.tint p
	| EField _
	| EType _
	| EArray _
	| EConst (Ident _)
	| EConst (Type _) ->
		acc_get ctx (type_access ctx e p MGet) p
	| EConst (Regexp (r,opt)) ->
		let str = mk (TConst (TString r)) ctx.api.tstring p in
		let opt = mk (TConst (TString opt)) ctx.api.tstring p in
		let t = Typeload.load_core_type ctx "EReg" in
		mk (TNew ((match t with TInst (c,[]) -> c | _ -> assert false),[],[str;opt])) t p
	| EConst c ->
		Typeload.type_constant ctx c p
    | EBinop (op,e1,e2) ->
		type_binop ctx op e1 e2 p
	| EBlock [] when need_val ->
		type_expr ctx (EObjectDecl [],p)
	| EBlock l ->
		let locals = save_locals ctx in
		let rec loop = function
			| [] -> []
			| [e] ->
				(try
					[type_expr ctx ~need_val e]
				with
					Error (e,p) -> display_error ctx (error_msg e) p; [])
			| e :: l ->
				try
					let e = type_expr ctx ~need_val:false e in
					e :: loop l
				with
					Error (e,p) -> display_error ctx (error_msg e) p; loop l
		in
		let l = loop l in
		locals();
		let rec loop = function
			| [] -> ctx.api.tvoid
			| [e] -> e.etype
			| _ :: l -> loop l
		in
		mk (TBlock l) (loop l) p
	| EParenthesis e ->
		let e = type_expr ctx ~need_val e in
		mk (TParenthesis e) e.etype p
	| EObjectDecl fl ->
		let rec loop (l,acc) (f,e) =
			if PMap.mem f acc then error ("Duplicate field in object declaration : " ^ f) p;
			let e = type_expr ctx e in
			let cf = mk_field f e.etype in
			((f,e) :: l, PMap.add f cf acc)
		in
		let fields , types = List.fold_left loop ([],PMap.empty) fl in
		let x = ref Const in
		ctx.opened <- x :: ctx.opened;
		mk (TObjectDecl (List.rev fields)) (TAnon { a_fields = types; a_status = x }) p
	| EArrayDecl el ->
		let t = ref (mk_mono()) in
		let is_null = ref false in
		let el = List.map (fun e ->
			let e = type_expr ctx e in
			(match e.eexpr with
			| TConst TNull when not !is_null ->
				is_null := true;
				t := ctx.api.tnull !t;
			| _ -> ());
			(try
				unify_raise ctx e.etype (!t) e.epos;
			with Error (Unify _,_) -> try
				unify_raise ctx (!t) e.etype e.epos;
				t := e.etype;
			with Error (Unify _,_) ->
				t := t_dynamic);
			e
		) el in
		mk (TArrayDecl el) (ctx.api.tarray !t) p
	| EVars vl ->
		let vl = List.map (fun (v,t,e) ->
			try
				let t = Typeload.load_type_opt ctx p t in
				let e = (match e with
					| None -> None
					| Some e ->
						let e = type_expr_with_type ctx e (Some t) in
						unify ctx e.etype t p;
						Some e
				) in
				let v = add_local ctx v t in
				v , t , e
			with
				Error (e,p) ->
					display_error ctx (error_msg e) p;
					let t = t_dynamic in
					let v = add_local ctx v t in
					v , t, None
		) vl in
		mk (TVars vl) ctx.api.tvoid p
	| EFor (i,e1,e2) ->
		let e1 = type_expr ctx e1 in
		let old_loop = ctx.in_loop in
		let old_locals = save_locals ctx in
		ctx.in_loop <- true;
		let e = (match Optimizer.optimize_for_loop ctx i e1 e2 p with
			| Some e -> e
			| None ->
				let t, pt = Typeload.t_iterator ctx in
				let i = add_local ctx i pt in
				let e1 = (match follow e1.etype with
				| TMono _
				| TDynamic _ ->
					error "You can't iterate on a Dynamic value, please specify Iterator or Iterable" e1.epos;
				| TLazy _ ->
					assert false
				| _ ->
					(try
						unify_raise ctx e1.etype t e1.epos;
						e1
					with Error (Unify _,_) ->
						let acc = acc_get ctx (type_field ctx e1 "iterator" e1.epos MCall) e1.epos in
						match follow acc.etype with
						| TFun ([],it) ->
							unify ctx it t e1.epos;
							make_call ctx acc [] t e1.epos
						| _ ->
							error "The field iterator is not a method" e1.epos
					)
				) in
				let e2 = type_expr ~need_val:false ctx e2 in
				mk (TFor (i,pt,e1,e2)) ctx.api.tvoid p
		) in
		ctx.in_loop <- old_loop;
		old_locals();
		e
	| ETernary (e1,e2,e3) ->
		type_expr ctx ~need_val (EIf (e1,e2,Some e3),p)
	| EIf (e,e1,e2) ->
		let e = type_expr ctx e in
		unify ctx e.etype ctx.api.tbool e.epos;
		let e1 = type_expr ctx ~need_val e1 in
		(match e2 with
		| None ->
			if need_val then begin
				let t = ctx.api.tnull e1.etype in
				mk (TIf (e,e1,Some (null t p))) t p
			end else
				mk (TIf (e,e1,None)) ctx.api.tvoid p
		| Some e2 ->
			let e2 = type_expr ctx ~need_val e2 in
			let t = if not need_val then ctx.api.tvoid else (try
				(match e1.eexpr, e2.eexpr with
				| _ , TConst TNull -> ctx.api.tnull e1.etype
				| TConst TNull, _ -> ctx.api.tnull e2.etype
				| _  ->
					unify_raise ctx e1.etype e2.etype p;
					if is_null e1.etype then ctx.api.tnull e2.etype else e2.etype)
			with
				Error (Unify _,_) ->
					unify ctx e2.etype e1.etype p;
					if is_null e2.etype then ctx.api.tnull e1.etype else e1.etype
			) in
			mk (TIf (e,e1,Some e2)) t p)
	| EWhile (cond,e,NormalWhile) ->
		let old_loop = ctx.in_loop in
		let cond = type_expr ctx cond in
		unify ctx cond.etype ctx.api.tbool cond.epos;
		ctx.in_loop <- true;
		let e = type_expr ~need_val:false ctx e in
		ctx.in_loop <- old_loop;
		mk (TWhile (cond,e,NormalWhile)) ctx.api.tvoid p
	| EWhile (cond,e,DoWhile) ->
		let old_loop = ctx.in_loop in
		ctx.in_loop <- true;
		let e = type_expr ~need_val:false ctx e in
		ctx.in_loop <- old_loop;
		let cond = type_expr ctx cond in
		unify ctx cond.etype ctx.api.tbool cond.epos;
		mk (TWhile (cond,e,DoWhile)) ctx.api.tvoid p
	| ESwitch (e,cases,def) ->
		type_switch ctx e cases def need_val p
	| EReturn e ->
		let e , t = (match e with
			| None ->
				let v = ctx.api.tvoid in
				unify ctx v ctx.ret p;
				None , v
			| Some e ->
				let e = type_expr ctx e in
				unify ctx e.etype ctx.ret e.epos;
				Some e , e.etype
		) in
		mk (TReturn e) t_dynamic p
	| EBreak ->
		if not ctx.in_loop then error "Break outside loop" p;
		mk TBreak t_dynamic p
	| EContinue ->
		if not ctx.in_loop then error "Continue outside loop" p;
		mk TContinue t_dynamic p
	| ETry (e1,catches) ->
		let e1 = type_expr ctx ~need_val e1 in
		let catches = List.map (fun (v,t,e) ->
			let t = Typeload.load_complex_type ctx (pos e) t in
			let name = (match follow t with
				| TInst ({ cl_path = path },params) | TEnum ({ e_path = path },params) ->
					List.iter (fun pt ->
						if pt != t_dynamic then error "Catch class parameter must be Dynamic" p;
					) params;
					(match path with
					| x :: _ , _ -> x
					| [] , name -> name)
				| TDynamic _ -> ""
				| _ -> error "Catch type must be a class" p
			) in
			let locals = save_locals ctx in
			let v = add_local ctx v t in
			let e = type_expr ctx ~need_val e in
			locals();
			if need_val then unify ctx e.etype e1.etype e.epos;
			if PMap.mem name ctx.locals then error ("Local variable " ^ name ^ " is preventing usage of this type here") e.epos;
			v , t , e
		) catches in
		mk (TTry (e1,catches)) (if not need_val then ctx.api.tvoid else e1.etype) p
	| EThrow e ->
		let e = type_expr ctx e in
		mk (TThrow e) (mk_mono()) p
	| ECall (e,el) ->
		type_call ctx e el p
	| ENew (t,el) ->
		let t = Typeload.load_instance ctx t p true in
		let el, c , params = (match follow t with
		| TInst (c,params) ->
			let name = (match c.cl_path with [], name -> name | x :: _ , _ -> x) in
			if PMap.mem name ctx.locals then error ("Local variable " ^ name ^ " is preventing usage of this class here") p;					
			let f = get_constructor c p in
			if not f.cf_public && not (is_parent c ctx.curclass) && not ctx.untyped then error "Cannot access private constructor" p;
			let el = (match follow (apply_params c.cl_types params (field_type f)) with
			| TFun (args,r) ->
				unify_call_params ctx (Some "new") el args p false
			| _ ->
				error "Constructor is not a function" p
			) in
			el , c , params
		| _ ->
			error (s_type (print_context()) t ^ " cannot be constructed") p
		) in
		mk (TNew (c,params,el)) t p
	| EUnop (op,flag,e) ->
		type_unop ctx op flag e p
	| EFunction f ->
		let rt = Typeload.load_type_opt ctx p f.f_type in
		let args = List.map (fun (s,opt,t,c) -> 
			let t = Typeload.load_type_opt ctx p t in
			let t, c = Typeload.type_function_param ctx t c opt p in
			s , c, t
		) f.f_args in
		(match ctx.param_type with
		| None -> ()
		| Some t ->
			ctx.param_type <- None;
			match follow t with
			| TFun (args2,_) when List.length args2 = List.length args ->
				List.iter2 (fun (_,_,t1) (_,_,t2) ->
					match follow t1 with
					| TMono _ -> unify ctx t2 t1 p
					| _ -> ()
				) args args2;
			| _ -> ());
		let ft = TFun (fun_args args,rt) in
		let e , fargs = Typeload.type_function ctx args rt true false f p in
		let f = {
			tf_args = fargs;
			tf_type = rt;
			tf_expr = e;
		} in
		mk (TFunction f) ft p
	| EUntyped e ->
		let old = ctx.untyped in
		ctx.untyped <- true;
		let e = type_expr ctx e in
		ctx.untyped <- old;
		{
			eexpr = e.eexpr;
			etype = mk_mono();
			epos = e.epos;
		}
	| ECast (e,None) ->
		let e = type_expr ctx e in
		mk (TCast (e,None)) (mk_mono()) p
	| ECast (e, Some t) ->
		(* force compilation of class "Std" since we might need it *)
		ignore(Typeload.load_type_def ctx p { tpackage = []; tparams = []; tname = "Std"; tsub = None });
		let t = Typeload.load_complex_type ctx (pos e) t in
		let texpr = (match follow t with
		| TInst (_,params) | TEnum (_,params) ->
			List.iter (fun pt ->
				if follow pt != t_dynamic then error "Cast type parameters must be Dynamic" p;
			) params;
			(match follow t with
			| TInst (c,_) -> TClassDecl c
			| TEnum (e,_) -> TEnumDecl e
			| _ -> assert false);
		| _ ->
			error "Cast type must be a class or an enum" p
		) in
		mk (TCast (type_expr ctx e,Some texpr)) t p
	| EDisplay (e,iscall) ->
		let old = ctx.in_display in
		ctx.in_display <- true;
		let e = (try type_expr ctx e with Error (Unknown_ident n,_) -> raise (Parser.TypePath ([n],None))) in
		ctx.in_display <- old;
		let t = (match follow e.etype with
			| TInst (c,params) ->
				let priv = is_parent c ctx.curclass in
				let merge ?(cond=(fun _ -> true)) a b =
					PMap.foldi (fun k f m -> if cond f then PMap.add k f m else m) a b
				in
				let rec loop c params =
					let m = List.fold_left (fun m (i,params) ->
						merge m (loop i params)
					) PMap.empty c.cl_implements in
					let m = (match c.cl_super with
						| None -> m
						| Some (csup,cparams) -> merge m (loop csup cparams)
					) in
					let m = merge ~cond:(fun f -> priv || f.cf_public) c.cl_fields m in
					PMap.map (fun f -> { f with cf_type = apply_params c.cl_types params f.cf_type; cf_public = true; }) m
				in
				let fields = loop c params in
				TAnon { a_fields = fields; a_status = ref Closed; }
			| TAnon a as t ->
				(match !(a.a_status) with
				| Statics c when is_parent c ctx.curclass ->
					TAnon { a_fields = PMap.map (fun f -> { f with cf_public = true }) a.a_fields; a_status = ref Closed }
				| _ -> t)
			| t -> t
		) in
		(*
			add 'using' methods compatible with this type
		*)
		let rec loop acc = function
			| [] -> acc
			| x :: l -> 
				let acc = ref (loop acc l) in
				(match x with
				| TClassDecl c ->
					let rec dup t = Type.map dup t in
					List.iter (fun f ->
						match follow (field_type f) with
						| TFun ((_,_,t) :: args, ret) when (try unify_raise ctx (dup e.etype) t e.epos; true with _ -> false) ->
							let f = { f with cf_type = TFun (args,ret); cf_params = [] } in
							if follow e.etype == t_dynamic && follow t != t_dynamic then
								()
							else
								acc := PMap.add f.cf_name f (!acc)
						| _ -> ()
					) c.cl_ordered_statics
				| _ -> ());
				!acc
		in	
		let use_methods = loop PMap.empty ctx.local_using in
		let t = (if iscall then
			match follow t with
			| TFun _ -> t
			| _ -> t_dynamic
		else if PMap.is_empty use_methods then
			t
		else match follow t with
			| TAnon a -> TAnon { a_fields = PMap.fold (fun f acc -> PMap.add f.cf_name f acc) a.a_fields use_methods; a_status = ref Closed; }
			| _ -> TAnon { a_fields = use_methods; a_status = ref Closed }
		) in
		raise (Display t)
	| EDisplayNew t ->
		let t = Typeload.load_instance ctx t p true in
		(match follow t with
		| TInst (c,params) ->
			let f = get_constructor c p in
			let t = apply_params c.cl_types params (field_type f) in
			raise (Display t)
		| _ ->
			error "Not a class" p)

and type_call ctx e el p =
	match e, el with
	| (EConst (Ident "trace"),p) , e :: el ->
		if Common.defined ctx.com "no_traces" then
			null ctx.api.tvoid p
		else
		let params = (match el with [] -> [] | _ -> ["customParams",(EArrayDecl el , p)]) in
		let infos = mk_infos ctx p params in
		type_expr ctx (ECall ((EField ((EType ((EConst (Ident "haxe"),p),"Log"),p),"trace"),p),[e;EUntyped infos,p]),p)
	| (EConst (Ident "callback"),p) , e :: params ->
		let e = type_expr ctx e in
		let eparams = List.map (type_expr ctx) params in
		(match follow e.etype with
		| TFun (args,ret) ->
			let rec loop args params eargs =
				match args, params with
				| _ , [] ->
					let k = ref 0 in
					let fun_arg = ("f",None,e.etype) in
					let first_args = List.map (fun t -> incr k; "a" ^ string_of_int !k, None, t) (List.rev eargs) in
					let missing_args = List.map (fun (_,opt,t) -> incr k; "a" ^ string_of_int !k, (if opt then Some TNull else None), t) args in
					let vexpr (v,_,t) = mk (TLocal v) t p in
					let func = mk (TFunction {
						tf_args = missing_args;
						tf_type = ret;
						tf_expr = mk (TReturn (Some (
							make_call ctx (vexpr fun_arg) (List.map vexpr (first_args @ missing_args)) ret p
						))) ret p;
					}) (TFun (fun_args missing_args,ret)) p in
					let func = mk (TFunction {
						tf_args = fun_arg :: first_args;
						tf_type = func.etype;
						tf_expr = mk (TReturn (Some func)) e.etype p;
					}) (TFun (fun_args first_args,func.etype)) p in
					mk (TCall (func,e :: eparams)) (TFun (fun_args missing_args,ret)) p
				| [], _ -> error "Too many callback arguments" p
				| (_,_,t) :: args , e :: params ->
					unify ctx e.etype t p;
					loop args params (t :: eargs)
			in
			loop args eparams []
		| _ -> error "First parameter of callback is not a function" p);
	| (EConst (Ident "type"),_) , [e] ->
		let e = type_expr ctx e in
		ctx.com.warning (s_type (print_context()) e.etype) e.epos;
		e
	| (EConst (Ident "__unprotect__"),_) , [(EConst (String _),_) as e] ->
		let e = type_expr ctx e in
		if Common.defined ctx.com "flash" then
			mk (TCall (mk (TLocal "__unprotect__") (tfun [e.etype] e.etype) p,[e])) e.etype e.epos
		else
			e
	| (EConst (Ident "super"),sp) , el ->
		if ctx.in_static || not ctx.in_constructor then error "Cannot call superconstructor outside class constructor" p;
		let el, t = (match ctx.curclass.cl_super with
		| None -> error "Current class does not have a super" p
		| Some (c,params) ->					
			let f = get_constructor c p in
			let el = (match follow (apply_params c.cl_types params (field_type f)) with
			| TFun (args,_) ->
				unify_call_params ctx (Some "new") el args p false
			| _ ->
				error "Constructor is not a function" p
			) in
			el , TInst (c,params)
		) in
		mk (TCall (mk (TConst TSuper) t sp,el)) ctx.api.tvoid p
	| _ ->
		(match e with
		| EField ((EConst (Ident "super"),_),_) , _ | EType ((EConst (Ident "super"),_),_) , _ -> ctx.super_call <- true
		| _ -> ());		
		match type_access ctx (fst e) (snd e) MCall with
		| AccInline (ethis,f,t) ->
			let params, tret = (match follow t with
				| TFun (args,r) -> unify_call_params ctx (Some f.cf_name) el args p true, r
				| _ -> error (s_type (print_context()) t ^ " cannot be called") p
			) in
			make_call ctx (mk (TField (ethis,f.cf_name)) t p) params tret p
		| AccUsing (et,eparam) ->
			let fname = (match et.eexpr with TField (_,f) -> f | _ -> assert false) in
			let params, tret = (match follow et.etype with
				| TFun ( _ :: args,r) -> unify_call_params ctx (Some fname) el args p false, r
				| _ -> assert false
			) in
			make_call ctx et (eparam::params) tret p
		| acc ->
			let e = acc_get ctx acc p in
			let el , t = (match follow e.etype with
			| TFun (args,r) ->
				let el = unify_call_params ctx (match e.eexpr with TField (_,f) -> Some f | _ -> None) el args p false in
				el , r
			| TMono _ ->
				let t = mk_mono() in
				let el = List.map (type_expr ctx) el in
				unify ctx (tfun (List.map (fun e -> e.etype) el) t) e.etype e.epos;
				el, t
			| t ->
				let el = List.map (type_expr ctx) el in
				el, if t == t_dynamic then
					t_dynamic
				else if ctx.untyped then
					mk_mono()
				else
					error (s_type (print_context()) e.etype ^ " cannot be called") e.epos
			) in
			mk (TCall (e,el)) t p

(* ---------------------------------------------------------------------- *)
(* FINALIZATION *)

let rec finalize ctx =
	let delays = List.concat !(ctx.delays) in
	ctx.delays := [];
	match delays with
	| [] -> () (* at last done *)
	| l ->
		List.iter (fun f -> f()) l;
		finalize ctx

let get_type_module ctx t =
	let mfound = ref ctx.current in
	try
		Hashtbl.iter (fun _ m ->
			if List.mem t m.mtypes then begin
				mfound := m;
				raise Exit;
			end;
		) ctx.modules;
		(* @Main, other generated classes ? *)
		{
			mtypes = [t];
			mpath = t_path t;			
		}
	with
		Exit -> !mfound

type state =
	| Generating
	| Done
	| NotYet

let types ctx main excludes =
	let types = ref [] in
	let states = Hashtbl.create 0 in
	let state p = try Hashtbl.find states p with Not_found -> NotYet in
	let statics = ref PMap.empty in

	let rec loop t =
		let p = t_path t in
		match state p with
		| Done -> ()
		| Generating ->
			prerr_endline ("Warning : maybe loop in static generation of " ^ s_type_path p);
		| NotYet ->
			Hashtbl.add states p Generating;
			ctx.api.on_generate t;
			let t = (match t with
			| TClassDecl c ->
				walk_class p c;
				if List.mem c.cl_path excludes then begin
					c.cl_extern <- true;
					c.cl_init <- None;
				end;
				t
			| TEnumDecl _ | TTypeDecl _ ->
				t
			) in
			Hashtbl.replace states p Done;
			types := t :: !types

    and loop_class p c =
		if c.cl_path <> p then loop (TClassDecl c)

	and loop_enum p e =
		if e.e_path <> p then loop (TEnumDecl e)

	and walk_static_call p c name =
		try
			let f = PMap.find name c.cl_statics in
			match f.cf_expr with
			| None -> ()
			| Some e ->
				if PMap.mem (c.cl_path,name) (!statics) then
					()
				else begin
					statics := PMap.add (c.cl_path,name) () (!statics);
					walk_expr p e;
				end
		with
			Not_found -> ()

	and walk_expr p e =
		match e.eexpr with
		| TTypeExpr t ->
			(match t with
			| TClassDecl c -> loop_class p c
			| TEnumDecl e -> loop_enum p e
			| TTypeDecl _ -> assert false)
		| TEnumField (e,_) ->
			loop_enum p e
		| TNew (c,_,_) ->
			iter (walk_expr p) e;
			loop_class p c
		| TMatch (_,(enum,_),_,_) ->
			loop_enum p enum;
			iter (walk_expr p) e
		| TCall (f,_) ->
			iter (walk_expr p) e;
			(* static call for initializing a variable *)
			let rec loop f =
				match f.eexpr with
				| TField ({ eexpr = TTypeExpr t },name) ->
					(match t with
					| TEnumDecl _ -> ()
					| TTypeDecl _ -> assert false
					| TClassDecl c -> walk_static_call p c name)
				| _ -> ()
			in
			loop f
		| _ ->
			iter (walk_expr p) e

    and walk_class p c =
		(match c.cl_super with None -> () | Some (c,_) -> loop_class p c);
		List.iter (fun (c,_) -> loop_class p c) c.cl_implements;
		(match c.cl_init with
		| None -> ()
		| Some e -> walk_expr p e);
		PMap.iter (fun _ f ->
			match f.cf_expr with
			| None -> ()
			| Some e ->
				match e.eexpr with
				| TFunction _ -> ()
				| _ -> walk_expr p e
		) c.cl_statics

	in
	Hashtbl.iter (fun _ m -> List.iter loop m.mtypes) ctx.modules;
	(match main with
	| None -> ()
	| Some cl ->
		let t = Typeload.load_type_def ctx null_pos { tpackage = fst cl; tname = snd cl; tparams = []; tsub = None } in
		let ft, r = (match t with
		| TEnumDecl _ | TTypeDecl _ ->
			error ("Invalid -main : " ^ s_type_path cl ^ " is not a class") null_pos
		| TClassDecl c ->
			try
				let f = PMap.find "main" c.cl_statics in
				let t = field_type f in
				(match follow t with
				| TFun ([],r) -> t, r
				| _ -> error ("Invalid -main : " ^ s_type_path cl ^ " has invalid main function") null_pos);
			with
				Not_found -> error ("Invalid -main : " ^ s_type_path cl ^ " does not have static function main") null_pos
		) in
		let path = ([],"@Main") in
		let emain = type_type ctx cl null_pos in
		let c = mk_class path null_pos in
		let f = {
			cf_name = "init";
			cf_type = r;
			cf_public = false;
			cf_get = NormalAccess;
			cf_set = NormalAccess;
			cf_doc = None;
			cf_meta = no_meta;
			cf_params = [];
			cf_expr = Some (mk (TCall (mk (TField (emain,"main")) ft null_pos,[])) r null_pos);
		} in
		c.cl_statics <- PMap.add "init" f c.cl_statics;
		c.cl_ordered_statics <- f :: c.cl_ordered_statics;
		types := TClassDecl c :: !types
	);
	List.rev !types

(* ---------------------------------------------------------------------- *)
(* TYPER INITIALIZATION *)

let create com =
	let empty =	{
		mpath = [] , "";
		mtypes = [];		
	} in
	let ctx = {
		com = com;
		api = com.type_api;
		core_api = ref None;
		modules = Hashtbl.create 0;
		types_module = Hashtbl.create 0;
		constructs = Hashtbl.create 0;
		delays = ref [];
		doinline = not (Common.defined com "no_inline");
		in_constructor = false;
		in_static = false;
		in_loop = false;
		untyped = false;
		super_call = false;
		in_display = false;
		ret = mk_mono();
		locals = PMap.empty;
		locals_map = PMap.empty;
		locals_map_inv = PMap.empty;
		local_types = [];
		local_using = [];
		type_params = [];
		curmethod = "";
		curclass = null_class;
		tthis = mk_mono();
		current = empty;
		std = empty;
		opened = [];
		param_type = None;
	} in
	ctx.api.load_module <- Typeload.load_module ctx;
	ctx.api.build_instance <- Codegen.build_instance ctx;
	ctx.api.on_generate <- Codegen.on_generate ctx;
	ctx.api.get_type_module <- get_type_module ctx;
	ctx.api.optimize <- Optimizer.reduce_expression ctx;
	ctx.std <- (try
		Typeload.load_module ctx ([],"StdTypes") null_pos
	with
		Error (Module_not_found ([],"StdTypes"),_) -> error "Standard library not found" null_pos
	);
	List.iter (fun t ->
		match t with
		| TEnumDecl e ->
			(match snd e.e_path with
			| "Void" -> ctx.api.tvoid <- TEnum (e,[])
			| "Bool" -> ctx.api.tbool <- TEnum (e,[])
			| _ -> ())
		| TClassDecl c ->
			(match snd c.cl_path with
			| "Float" -> ctx.api.tfloat <- TInst (c,[])
			| "Int" -> ctx.api.tint <- TInst (c,[])
			| _ -> ())
		| TTypeDecl td ->
			(match snd td.t_path with
			| "Null" ->
				let f9 = platform com Flash9 in
				let cpp = platform com Cpp in
				ctx.api.tnull <- if not (f9 || cpp) then (fun t -> t) else (fun t -> if is_nullable t then TType (td,[t]) else t);
			| _ -> ());
	) ctx.std.mtypes;
	let m = Typeload.load_module ctx ([],"String") null_pos in
	(match m.mtypes with
	| [TClassDecl c] -> ctx.api.tstring <- TInst (c,[])
	| _ -> assert false);
	let m = Typeload.load_module ctx ([],"Array") null_pos in
	(match m.mtypes with
	| [TClassDecl c] -> ctx.api.tarray <- (fun t -> TInst (c,[t]))
	| _ -> assert false);
	ctx

;;
Typeload.do_create := create;
type_field_rec := type_field