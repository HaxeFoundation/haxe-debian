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

let parse_file com file p =
	let ch = (try open_in_bin file with _ -> error ("Could not open " ^ file) p) in
	let t = Common.timer "parsing" in
	Lexer.init file;
	incr stats.s_files_parsed;
	let data = (try Parser.parse com (Lexing.from_channel ch) with e -> close_in ch; t(); raise e) in
	close_in ch;
	t();
	Common.log com ("Parsed " ^ file);
	data

let parse_hook = ref parse_file
let type_module_hook = ref (fun _ _ _ -> None)
let return_partial_type = ref false

let type_function_param ctx t e opt p =
	match e with
	| None ->
		if opt then ctx.t.tnull t, Some (EConst (Ident "null"),p) else t, None
	| Some e ->
		t, Some e

let type_static_var ctx t e p =
	ctx.curfun <- FStatic;
	let e = type_expr ctx e true in
	unify ctx e.etype t p;
	(* specific case for UInt statics *)
	match t with
	| TType ({ t_path = ([],"UInt") },[]) -> { e with etype = t }
	| _ -> e

let apply_macro ctx mode path el p =
	let cpath, meth = (match List.rev (ExtString.String.nsplit path ".") with
		| meth :: name :: pack -> (List.rev pack,name), meth
		| _ -> error "Invalid macro path" p
	) in
	ctx.g.do_macro ctx mode cpath meth el p

(** since load_type_def and load_instance are used in PASS2, they should not access the structure of a type **)

(*
	load a type or a subtype definition
*)
let rec load_type_def ctx p t =
	let no_pack = t.tpackage = [] in
	let tname = (match t.tsub with None -> t.tname | Some n -> n) in
	try
		if t.tsub <> None then raise Not_found;
		List.find (fun t2 ->
			let tp = t_path t2 in
			tp = (t.tpackage,tname) || (no_pack && snd tp = tname)
		) ctx.local_types
	with
		Not_found ->
			let next() =
				let t, m = (try
					t, ctx.g.do_load_module ctx (t.tpackage,t.tname) p
				with Error (Module_not_found _,p2) as e when p == p2 -> 
					match t.tpackage with
					| "std" :: l ->
						let t = { t with tpackage = l } in
						t, ctx.g.do_load_module ctx (t.tpackage,t.tname) p
					| _ -> raise e
				) in
				let tpath = (t.tpackage,tname) in
				try
					List.find (fun t -> not (t_infos t).mt_private && t_path t = tpath) m.m_types
				with
					Not_found -> raise (Error (Type_not_found (m.m_path,tname),p))
			in
			let rec loop = function
				| [] -> raise Exit
				| (_ :: lnext) as l ->
					try
						load_type_def ctx p { t with tpackage = List.rev l }
					with
						| Error (Module_not_found _,p2)
						| Error (Type_not_found _,p2) when p == p2 -> loop lnext
			in
			try
				if not no_pack then raise Exit;
				(match fst ctx.current.m_path with
				| [] -> raise Exit
				| x :: _ ->
					(* this can occur due to haxe remoting : a module can be
						already defined in the "js" package and is not allowed
						to access the js classes *)
					try
						(match PMap.find x ctx.com.package_rules with
						| Forbidden -> raise Exit
						| _ -> ())
					with Not_found -> ());
				loop (List.rev (fst ctx.current.m_path));
			with
				Exit -> next()

let check_param_constraints ctx types t pl c p =
	List.iter (fun (i,tl) ->
		let ti = try snd (List.find (fun (_,t) -> match follow t with TInst(i2,[]) -> i == i2 | _ -> false) types) with Not_found -> TInst (i,tl) in
		let ti = apply_params types pl ti in
		unify ctx t ti p
	) c.cl_implements

(* build an instance from a full type *)
let rec load_instance ctx t p allow_no_params =
	try
		if t.tpackage <> [] || t.tsub <> None then raise Not_found;
		let pt = List.assoc t.tname ctx.type_params in
		if t.tparams <> [] then error ("Class type parameter " ^ t.tname ^ " can't have parameters") p;
		pt
	with Not_found ->
		let types , path , f = ctx.g.do_build_instance ctx (load_type_def ctx p t) p in
		if allow_no_params && t.tparams = [] then begin
			let pl = ref [] in
			pl := List.map (fun (name,t) ->
				match follow t with
				| TInst (c,_) ->
					let t = mk_mono() in
					if c.cl_implements <> [] then delay ctx (fun() -> check_param_constraints ctx types t (!pl) c p);
					t;
				| _ -> assert false
			) types;
			f (!pl)
		end else if path = ([],"Dynamic") then
			match t.tparams with
			| [] -> t_dynamic
			| [TPType t] -> TDynamic (load_complex_type ctx p t)
			| _ -> error "Too many parameters for Dynamic" p
		else begin
			if List.length types <> List.length t.tparams then error ("Invalid number of type parameters for " ^ s_type_path path) p;
			let tparams = List.map (fun t ->
				match t with
				| TPExpr e ->
					let name = (match fst e with
						| EConst (String s) -> "S" ^ s
						| EConst (Int i) -> "I" ^ i
						| EConst (Float f) -> "F" ^ f
						| _ -> "Expr"
					) in
					let c = mk_class null_module ([],name) p in
					c.cl_kind <- KExpr e;
					TInst (c,[])
				| TPType t -> load_complex_type ctx p t
			) t.tparams in
			let params = List.map2 (fun t (name,t2) ->
				let isconst = (match t with TInst ({ cl_kind = KExpr _ },_) -> true | _ -> false) in
				if isconst <> (name = "Const") && t != t_dynamic then error (if isconst then "Constant value unexpected here" else "Constant value excepted as type parameter") p;
				match follow t2 with
				| TInst ({ cl_implements = [] }, []) ->
					t
				| TInst (c,[]) ->
					let r = exc_protect (fun r ->
						r := (fun() -> t);
						check_param_constraints ctx types t tparams c p;
						t
					) in
					delay ctx (fun () -> ignore(!r()));
					TLazy r
				| _ -> assert false
			) tparams types in
			f params
		end
(*
	build an instance from a complex type
*)
and load_complex_type ctx p t =
	match t with
	| CTParent t -> load_complex_type ctx p t
	| CTPath t -> load_instance ctx t p false
	| CTOptional _ -> error "Optional type not allowed here" p
	| CTExtend (t,l) ->
		(match load_complex_type ctx p (CTAnonymous l) with
		| TAnon a ->
			let rec loop t =
				match follow t with
				| TInst (c,tl) ->
					let c2 = mk_class null_module (fst c.cl_path,"+" ^ snd c.cl_path) p in
					c2.cl_private <- true;
					PMap.iter (fun f _ ->
						try
							ignore(class_field c f);
							error ("Cannot redefine field " ^ f) p
						with
							Not_found -> ()
					) a.a_fields;
					(* do NOT tag as extern - for protect *)
					c2.cl_kind <- KExtension (c,tl);
					c2.cl_super <- Some (c,tl);
					c2.cl_fields <- a.a_fields;
					TInst (c2,[])
				| TMono _ ->
					error "Please ensure correct initialization of cascading signatures" p
				| TAnon a2 ->
					PMap.iter (fun f _ ->
						if PMap.mem f a2.a_fields then error ("Cannot redefine field " ^ f) p
					) a.a_fields;
					mk_anon (PMap.foldi PMap.add a.a_fields a2.a_fields)
				| _ -> error "Cannot only extend classes and anonymous" p
			in
			loop (load_instance ctx t p false)
		| _ -> assert false)
	| CTAnonymous l ->
		let rec loop acc f =
			let n = f.cff_name in
			let p = f.cff_pos in
			if PMap.mem n acc then error ("Duplicate field declaration : " ^ n) p;
			let topt = function
				| None -> error ("Explicit type required for field " ^ n) p
				| Some t -> load_complex_type ctx p t
			in
			let no_expr = function
				| None -> ()
				| Some (_,p) -> error "Expression not allowed here" p
			in
			let pub = ref true in
			let dyn = ref false in
			List.iter (fun a ->
				match a with
				| APublic -> ()
				| APrivate -> pub := false;
				| ADynamic when (match f.cff_kind with FFun _ -> true | _ -> false) -> dyn := true
				| AStatic | AOverride | AInline | ADynamic -> error ("Invalid access " ^ Ast.s_access a) p
			) f.cff_access;
			let t , access = (match f.cff_kind with
				| FVar (t, e) ->
					no_expr e;
					topt t, Var { v_read = AccNormal; v_write = AccNormal }
				| FFun f ->
					if f.f_params <> [] then error "Type parameters are not allowed in structures" p;
					no_expr f.f_expr;
					let args = List.map (fun (name,o,t,e) -> no_expr e; name, o, topt t) f.f_args in
					TFun (args,topt f.f_type), Method (if !dyn then MethDynamic else MethNormal)
				| FProp (i1,i2,t,e) ->
					no_expr e;
					let access m get =
						match m with
						| "null" -> AccNo
						| "never" -> AccNever
						| "default" -> AccNormal
						| "dynamic" -> AccCall ((if get then "get_"  else "set_") ^ n)
						| _ -> AccCall m
					in
					load_complex_type ctx p t, Var { v_read = access i1 true; v_write = access i2 false }
			) in
			PMap.add n {
				cf_name = n;
				cf_type = t;
				cf_pos = p;
				cf_public = !pub;
				cf_kind = access;
				cf_params = [];
				cf_expr = None;
				cf_doc = f.cff_doc;
				cf_meta = f.cff_meta;
			} acc
		in
		mk_anon (List.fold_left loop PMap.empty l)
	| CTFunction (args,r) ->
		match args with
		| [CTPath { tpackage = []; tparams = []; tname = "Void" }] ->
			TFun ([],load_complex_type ctx p r)
		| _ ->
			TFun (List.map (fun t ->
				let t, opt = (match t with CTOptional t -> t, true | _ -> t,false) in
				"",opt,load_complex_type ctx p t
			) args,load_complex_type ctx p r)

let hide_types ctx =
	let old_locals = ctx.local_types in
	let old_type_params = ctx.type_params in
	ctx.local_types <- ctx.g.std.m_types;
	ctx.type_params <- [];
	(fun() ->
		ctx.local_types <- old_locals;
		ctx.type_params <- old_type_params;
	)

(*
	load a type while ignoring the current imports or local types
*)
let load_core_type ctx name =
	let show = hide_types ctx in
	let t = load_instance ctx { tpackage = []; tname = name; tparams = []; tsub = None; } null_pos false in
	show();
	t

let t_iterator ctx =
	let show = hide_types ctx in
	match load_type_def ctx null_pos { tpackage = []; tname = "Iterator"; tparams = []; tsub = None } with
	| TTypeDecl t ->
		show();
		if List.length t.t_types <> 1 then assert false;
		let pt = mk_mono() in
		apply_params t.t_types [pt] t.t_type, pt
	| _ ->
		assert false

(*
	load either a type t or Null<Unknown> if not defined
*)
let load_type_opt ?(opt=false) ctx p t =
	let t = (match t with None -> mk_mono() | Some t -> load_complex_type ctx p t) in
	if opt then ctx.t.tnull t else t

(* ---------------------------------------------------------------------- *)
(* Structure check *)

let valid_redefinition ctx f1 t1 f2 t2 =
	let valid t1 t2 =
		type_eq EqStrict t1 t2;
		if is_null t1 <> is_null t2 then raise (Unify_error [Cannot_unify (t1,t2)]);
	in
	let t1, t2 = (match f1.cf_params, f2.cf_params with
		| [], [] -> t1, t2
		| l1, l2 when List.length l1 = List.length l2 ->
			let monos = List.map (fun _ -> mk_mono()) l1 in
			apply_params l1 monos t1, apply_params l2 monos t2
		| _  -> t1, t2
	) in
	match follow t1, follow t2 with
	| TFun (args1,r1) , TFun (args2,r2) when List.length args1 = List.length args2 ->
		List.iter2 (fun (n,o1,a1) (_,o2,a2) ->
			if o1 <> o2 then raise (Unify_error [Not_matching_optional n]);
			valid a1 a2;
		) args1 args2;
		valid r1 r2;
	| _ , _ ->
		(* in case args differs, or if an interface var *)
		valid t1 t2

let check_overriding ctx c p () =
	match c.cl_super with
	| None ->
		(match c.cl_overrides with
		| [] -> ()
		| i :: _ ->
			display_error ctx ("Field " ^ i ^ " is declared 'override' but doesn't override any field") p)
	| Some (csup,params) ->
		PMap.iter (fun i f ->
			try
				let t , f2 = raw_class_field (fun f -> f.cf_type) csup i in
				(* allow to define fields that are not defined for this platform version in superclass *)
				(match f2.cf_kind with
				| Var { v_read = AccRequire _ } -> raise Not_found;
				| _ -> ());
				ignore(follow f.cf_type); (* force evaluation *)
				let p = (match f.cf_expr with None -> p | Some e -> e.epos) in
				if not (List.mem i c.cl_overrides) then
					display_error ctx ("Field " ^ i ^ " should be declared with 'override' since it is inherited from superclass") p
				else if f.cf_public <> f2.cf_public then
					display_error ctx ("Field " ^ i ^ " has different visibility (public/private) than superclass one") p
				else (match f.cf_kind, f2.cf_kind with
				| _, Method MethInline ->
					display_error ctx ("Field " ^ i ^ " is inlined and cannot be overridden") p
				| a, b when a = b -> ()
				| Method MethInline, Method MethNormal ->
					() (* allow to redefine a method as inlined *)
				| _ ->
					display_error ctx ("Field " ^ i ^ " has different property access than in superclass") p);
				try
					let t = apply_params csup.cl_types params t in
					valid_redefinition ctx f f.cf_type f2 t
				with
					Unify_error l ->
						display_error ctx ("Field " ^ i ^ " overload parent class with different or incomplete type") p;
						display_error ctx (error_msg (Unify l)) p;
			with
				Not_found ->
					if List.mem i c.cl_overrides then display_error ctx ("Field " ^ i ^ " is declared 'override' but doesn't override any field") p
		) c.cl_fields

let class_field_no_interf c i =
	try
		let f = PMap.find i c.cl_fields in
		f.cf_type , f
	with Not_found ->
		match c.cl_super with
		| None ->
			raise Not_found
		| Some (c,tl) ->
			(* rec over class_field *)
			let t , f = raw_class_field (fun f -> f.cf_type) c i in
			apply_params c.cl_types tl t , f

let rec check_interface ctx c p intf params =
	PMap.iter (fun i f ->
		try
			let t2, f2 = class_field_no_interf c i in
			ignore(follow f2.cf_type); (* force evaluation *)
			let p = (match f2.cf_expr with None -> p | Some e -> e.epos) in
			let mkind = function
				| MethNormal | MethInline -> 0
				| MethDynamic -> 1
				| MethMacro -> 2
			in
			if f.cf_public && not f2.cf_public then
				display_error ctx ("Field " ^ i ^ " should be public as requested by " ^ s_type_path intf.cl_path) p
			else if not (unify_kind f2.cf_kind f.cf_kind) || not (match f.cf_kind, f2.cf_kind with Var _ , Var _ -> true | Method m1, Method m2 -> mkind m1 = mkind m2 | _ -> false) then
				display_error ctx ("Field " ^ i ^ " has different property access than in " ^ s_type_path intf.cl_path ^ " (" ^ s_kind f2.cf_kind ^ " should be " ^ s_kind f.cf_kind ^ ")") p
			else try
				valid_redefinition ctx f2 t2 f (apply_params intf.cl_types params f.cf_type)
			with
				Unify_error l ->
					display_error ctx ("Field " ^ i ^ " has different type than in " ^ s_type_path intf.cl_path) p;
					display_error ctx (error_msg (Unify l)) p;
		with
			Not_found ->
				if not c.cl_interface then display_error ctx ("Field " ^ i ^ " needed by " ^ s_type_path intf.cl_path ^ " is missing") p
	) intf.cl_fields;
	List.iter (fun (i2,p2) ->
		check_interface ctx c p i2 (List.map (apply_params intf.cl_types params) p2)
	) intf.cl_implements

let check_interfaces ctx c p () =
	match c.cl_path with
	| "Proxy" :: _ , _ -> ()
	| _ ->
	List.iter (fun (intf,params) -> check_interface ctx c p intf params) c.cl_implements

let rec return_flow ctx e =
	let error() = display_error ctx "A return is missing here" e.epos; raise Exit in
	let return_flow = return_flow ctx in
	match e.eexpr with
	| TReturn _ | TThrow _ -> ()
	| TParenthesis e ->
		return_flow e
	| TBlock el ->
		let rec loop = function
			| [] -> error()
			| [e] -> return_flow e
			| { eexpr = TReturn _ } :: _ | { eexpr = TThrow _ } :: _ -> ()
			| _ :: l -> loop l
		in
		loop el
	| TIf (_,e1,Some e2) ->
		return_flow e1;
		return_flow e2;
	| TSwitch (v,cases,Some e) ->
		List.iter (fun (_,e) -> return_flow e) cases;
		return_flow e
	| TSwitch (e,cases,None) when (match follow e.etype with TEnum _ -> true | _ -> false) ->
		List.iter (fun (_,e) -> return_flow e) cases;
	| TMatch (_,_,cases,def) ->
		List.iter (fun (_,_,e) -> return_flow e) cases;
		(match def with None -> () | Some e -> return_flow e)
	| TTry (e,cases) ->
		return_flow e;
		List.iter (fun (_,e) -> return_flow e) cases;
	| _ ->
		error()

(* ---------------------------------------------------------------------- *)
(* PASS 1 & 2 : Module and Class Structure *)

let set_heritance ctx c herits p =
	let process_meta csup =
		List.iter (fun m ->
			match m with
			| ":final", _, _ -> if not (Type.has_meta ":hack" c.cl_meta) then error "Cannot extend a final class" p;
			| ":autoBuild", el, p -> c.cl_meta <- (":build",el,p) :: m :: c.cl_meta;
			| _ -> ()
		) csup.cl_meta
	in
	let rec loop = function
		| HPrivate | HExtern | HInterface ->
			()
		| HExtends t ->
			if c.cl_super <> None then error "Cannot extend several classes" p;
			let t = load_instance ctx t p false in
			(match follow t with
			| TInst ({ cl_path = [],"Array" },_)
			| TInst ({ cl_path = [],"String" },_)
			| TInst ({ cl_path = [],"Date" },_)
			| TInst ({ cl_path = [],"Xml" },_) when ((not (platform ctx.com Cpp)) && (match c.cl_path with "mt" :: _ , _ -> false | _ -> true)) ->
				error "Cannot extend basic class" p;
			| TInst (csup,params) ->
				if is_parent c csup then error "Recursive class" p;
				if c.cl_interface then error "Cannot extend an interface" p;
				if csup.cl_interface then error "Cannot extend by using an interface" p;
				process_meta csup;
				c.cl_super <- Some (csup,params)
			| _ -> error "Should extend by using a class" p)
		| HImplements t ->
			let t = load_instance ctx t p false in
			(match follow t with
			| TInst ({ cl_path = [],"ArrayAccess"; cl_extern = true; },[t]) ->
				if c.cl_array_access <> None then error "Duplicate array access" p;
				c.cl_array_access <- Some t
			| TInst (intf,params) ->
				if is_parent c intf then error "Recursive class" p;
				process_meta intf;
				c.cl_implements <- (intf, params) :: c.cl_implements
			| TDynamic t ->
				if c.cl_dynamic <> None then error "Cannot have several dynamics" p;
				c.cl_dynamic <- Some t
			| _ -> error "Should implement by using an interface or a class" p)
	in
	(*
		resolve imports before calling build_inheritance, since it requires full paths.
		that means that typedefs are not working, but that's a fair limitation
	*)
	let rec resolve_imports t =
		match t.tpackage with
		| _ :: _ -> t
		| [] ->
			try
				let lt = List.find (fun lt -> snd (t_path lt) = t.tname) ctx.local_types in
				{ t with tpackage = fst (t_path lt) }
			with
				Not_found -> t
	in
	let herits = List.map (function
		| HExtends t -> HExtends (resolve_imports t)
		| HImplements t -> HImplements (resolve_imports t)
		| h -> h
	) herits in
	List.iter loop (List.filter (ctx.g.do_inherit ctx c p) herits)

let type_type_params ctx path get_params p (n,flags) =
	let c = mk_class ctx.current (fst path @ [snd path],n) p in
	c.cl_kind <- KTypeParameter;
	let t = TInst (c,[]) in
	match flags with
	| [] -> n, t
	| _ ->
		let r = exc_protect (fun r ->
			r := (fun _ -> t);
			let ctx = { ctx with type_params = ctx.type_params @ get_params() } in
			set_heritance ctx c (List.map (fun t -> match t with CTPath t -> HImplements t | _ -> error "Unsupported type constraint" p) flags) p;
			t
		) in
		delay ctx (fun () -> ignore(!r()));
		n, TLazy r

let type_function ctx args ret fmode f p =
	let locals = save_locals ctx in
	let fargs = List.map (fun (n,c,t) ->
		let c = (match c with
			| None -> None
			| Some e ->
				let p = pos e in
				let e = ctx.g.do_optimize ctx (type_expr ctx e true) in
				unify ctx e.etype t p;
				match e.eexpr with
				| TConst c -> Some c
				| _ -> display_error ctx "Parameter default value should be constant" p; None
		) in
		add_local ctx n t, c
	) args in
	let old_ret = ctx.ret in
	let old_fun = ctx.curfun in
	let old_opened = ctx.opened in
	ctx.curfun <- fmode;
	ctx.ret <- ret;
	ctx.opened <- [];
	let e = type_expr ctx (match f.f_expr with None -> error "Function body required" p | Some e -> e) false in
	let rec loop e =
		match e.eexpr with
		| TReturn (Some _) -> raise Exit
		| TFunction _ -> ()
		| _ -> Type.iter loop e
	in
	let have_ret = (try loop e; false with Exit -> true) in
	if have_ret then
		(try return_flow ctx e with Exit -> ())
	else
		unify ctx ret ctx.t.tvoid p;
	let rec loop e =
		match e.eexpr with
		| TCall ({ eexpr = TConst TSuper },_) -> raise Exit
		| TFunction _ -> ()
		| _ -> Type.iter loop e
	in
	let has_super_constr() =
		match ctx.curclass.cl_super with
		| None -> false
		| Some (csup,_) ->
			try ignore(get_constructor (fun f->f.cf_type) csup); true with Not_found -> false
	in
	if fmode = FConstructor && has_super_constr() then
		(try
			loop e;
			display_error ctx "Missing super constructor call" p
		with
			Exit -> ());
	locals();
	let e = match ctx.curfun, ctx.vthis with
		| (FMember|FConstructor), Some v ->
			let ev = mk (TVars [v,Some (mk (TConst TThis) ctx.tthis p)]) ctx.t.tvoid p in
			(match e.eexpr with
			| TBlock l -> { e with eexpr = TBlock (ev::l) }
			| _ -> mk (TBlock [ev;e]) e.etype p)
		| _ -> e
	in
	List.iter (fun r -> r := Closed) ctx.opened;
	ctx.ret <- old_ret;
	ctx.curfun <- old_fun;
	ctx.opened <- old_opened;
	e , fargs

let init_core_api ctx c =
	let ctx2 = (match ctx.g.core_api with
		| None ->
			let com2 = Common.clone ctx.com in
			Common.define com2 "core_api";
			com2.class_path <- ctx.com.std_path;
			let ctx2 = ctx.g.do_create com2 in
			ctx.g.core_api <- Some ctx2;
			ctx2
		| Some c ->
			c
	) in
	let t = load_instance ctx2 { tpackage = fst c.cl_path; tname = snd c.cl_path; tparams = []; tsub = None; } c.cl_pos true in
	match t with
	| TInst (ccore,_) ->
		(match c.cl_doc with
		| None -> c.cl_doc <- ccore.cl_doc
		| Some _ -> ());
		let compare_fields f f2 =
			let p = (match f2.cf_expr with None -> c.cl_pos | Some e -> e.epos) in
			(try
				type_eq EqCoreType (apply_params ccore.cl_types (List.map snd c.cl_types) f.cf_type) f2.cf_type
			with Unify_error l ->
				display_error ctx ("Field " ^ f.cf_name ^ " has different type than in core type") p;
				display_error ctx (error_msg (Unify l)) p);
			if f2.cf_public <> f.cf_public then error ("Field " ^ f.cf_name ^ " has different visibility than core type") p;
			(match f2.cf_doc with
			| None -> f2.cf_doc <- f.cf_doc
			| Some _ -> ());
			if f2.cf_kind <> f.cf_kind then begin
				match f2.cf_kind, f.cf_kind with
				| Method MethInline, Method MethNormal -> () (* allow to add 'inline' *)
				| Method MethNormal, Method MethInline -> () (* allow to disable 'inline' *)
				| _ ->
					error ("Field " ^ f.cf_name ^ " has different property access than core type") p;
			end;
			(match follow f.cf_type, follow f2.cf_type with
			| TFun (pl1,_), TFun (pl2,_) ->
				if List.length pl1 != List.length pl2 then assert false;
				List.iter2 (fun (n1,_,_) (n2,_,_) ->
					if n1 <> n2 then error ("Method parameter name '" ^ n2 ^ "' should be '" ^ n1 ^ "'") p;
				) pl1 pl2;
			| _ -> ());
		in
		let check_fields fcore fl =
			PMap.iter (fun i f ->
				if not f.cf_public then () else
				let f2 = try PMap.find f.cf_name fl with Not_found -> error ("Missing field " ^ i ^ " required by core type") c.cl_pos in
				compare_fields f f2;
			) fcore;
			PMap.iter (fun i f ->
				let p = (match f.cf_expr with None -> c.cl_pos | Some e -> e.epos) in
				if f.cf_public && not (PMap.mem f.cf_name fcore) && not (List.mem f.cf_name c.cl_overrides) then error ("Public field " ^ i ^ " is not part of core type") p;
			) fl;
		in
		check_fields ccore.cl_fields c.cl_fields;
		check_fields ccore.cl_statics c.cl_statics;
		(match ccore.cl_constructor, c.cl_constructor with
		| None, None -> ()
		| Some f, Some f2 -> compare_fields f f2
		| None, Some { cf_public = false } -> ()
		| _ -> error "Constructor differs from core type" c.cl_pos)

	| _ -> assert false

let patch_class ctx c fields =
	let h = (try Some (Hashtbl.find ctx.g.type_patches c.cl_path) with Not_found -> None) in
	match h with
	| None -> fields
	| Some (h,hcl) ->
		c.cl_meta <- c.cl_meta @ hcl.tp_meta;
		let rec loop acc = function
			| [] -> acc
			| f :: l ->
				(* patch arguments types *)
				(match f.cff_kind with
				| FFun ff ->
					let param ((n,opt,t,e) as p) =
						try
							let t2 = (try Hashtbl.find h (("$" ^ f.cff_name ^ "__" ^ n),false) with Not_found -> Hashtbl.find h (("$" ^ n),false)) in
							n, opt, t2.tp_type, e
						with Not_found ->
							p
					in
					f.cff_kind <- FFun { ff with f_args = List.map param ff.f_args }
				| _ -> ());
				(* other patches *)
				match (try Some (Hashtbl.find h (f.cff_name,List.mem AStatic f.cff_access)) with Not_found -> None) with
				| None -> loop (f :: acc) l
				| Some { tp_remove = true } -> loop acc l
				| Some p ->
					f.cff_meta <- f.cff_meta @ p.tp_meta;
					(match p.tp_type with
					| None -> ()
					| Some t ->
						f.cff_kind <- match f.cff_kind with
						| FVar (_,e) -> FVar (Some t,e)
						| FProp (get,set,_,eo) -> FProp (get,set,t,eo)
						| FFun f -> FFun { f with f_type = Some t });
					loop (f :: acc) l
		in
		List.rev (loop [] fields)

let build_module_def ctx mt meta fvars fbuild =
	let rec loop = function
		| (":build",args,p) :: l ->
			let epath, el = (match args with
				| [ECall (epath,el),p] -> epath, el
				| _ -> error "Invalid build parameters" p
			) in
			let rec getpath (e,p) =
				match e with
				| EConst (Ident i) | EConst (Type i) -> [i]
				| EField (e,f) | EType (e,f) -> f :: getpath e
				| _ -> error "Build call parameter must be a class path" p
			in
			let s = String.concat "." (List.rev (getpath epath)) in
			if ctx.in_macro then error "You cannot used :build inside a macro : make sure that your enum is not used in macro" p;
			let old = ctx.g.get_build_infos in
			ctx.g.get_build_infos <- (fun() -> Some (mt, fvars()));
			let r = try apply_macro ctx MBuild s el p with e -> ctx.g.get_build_infos <- old; raise e in
			ctx.g.get_build_infos <- old;
			(match r with
			| None -> error "Build failure" p
			| Some e -> fbuild e; loop l)
		| _ :: l -> loop l
		| [] -> ()
	in
	try
		loop meta
	with Error (Custom msg,p) ->
		display_error ctx msg p

let init_class ctx c p herits fields =
	incr stats.s_classes_built;
	let fields = patch_class ctx c fields in
	let ctx = { ctx with type_params = c.cl_types } in
	c.cl_extern <- List.mem HExtern herits;
	c.cl_interface <- List.mem HInterface herits;
	if c.cl_path = (["haxe";"macro"],"MacroType") then c.cl_kind <- KMacroType;
	set_heritance ctx c herits p;
	let fields = ref fields in
	let get_fields() = !fields in
	build_module_def ctx (TClassDecl c) c.cl_meta get_fields (fun (e,p) ->
		match e with
		| EVars [_,Some (CTAnonymous f),None] -> fields := f
		| _ -> error "Class build macro must return a single variable with anonymous fields" p
	);
	let fields = !fields in
	let core_api = has_meta ":core_api" c.cl_meta in
	let is_macro = has_meta ":macro" c.cl_meta in
	let fields, herits = if is_macro && not ctx.in_macro then begin
		c.cl_extern <- true;
		List.filter (fun f -> List.mem AStatic f.cff_access) fields, []
	end else fields, herits in
	if core_api && not (ctx.com.display || ctx.com.dead_code_elimination) then delay ctx (fun() -> init_core_api ctx c);
	let tthis = TInst (c,List.map snd c.cl_types) in
	let rec extends_public c =
		List.exists (fun (c,_) -> c.cl_path = (["haxe"],"Public") || extends_public c) c.cl_implements ||
		match c.cl_super with
		| None -> false
		| Some (c,_) -> extends_public c
	in
	let extends_public = extends_public c in
	let is_public access parent =
		if List.mem APrivate access then
			false
		else if List.mem APublic access then
			true
		else match parent with
			| Some { cf_public = p } -> p
			| _ -> c.cl_extern || c.cl_interface || extends_public
	in
	let rec get_parent c name =
		match c.cl_super with
		| None -> None
		| Some (csup,_) ->
			try
				Some (PMap.find name csup.cl_fields)
			with
				Not_found -> get_parent csup name
	in
	let type_opt ctx p t =
		match t with
		| None when c.cl_extern || c.cl_interface ->
			display_error ctx "Type required for extern classes and interfaces" p;
			t_dynamic
		| None when core_api ->
			display_error ctx "Type required for core api classes" p;
			t_dynamic
		| _ ->
			load_type_opt ctx p t
	in
	let rec has_field f = function
		| None -> false
		| Some (c,_) ->
			PMap.exists f c.cl_fields || has_field f c.cl_super || List.exists (fun i -> has_field f (Some i)) c.cl_implements
	in

	(* ----------------------- COMPLETION ----------------------------- *)

	let display_file = if ctx.com.display then Common.unique_full_path p.pfile = (!Parser.resume_display).pfile else false in

	let fields = if not display_file || Common.defined ctx.com "no-copt" then fields else Optimizer.optimize_completion c fields in

	let rec is_full_type t =
		match t with
		| TFun (args,ret) -> is_full_type ret && List.for_all (fun (_,_,t) -> is_full_type t) args
		| TMono r -> (match !r with None -> false | Some t -> is_full_type t)
		| TInst _ | TEnum _ | TLazy _ | TDynamic _ | TAnon _ | TType _ -> true
	in
	let bind_type cf r p macro =
		if ctx.com.display then begin
			let cp = !Parser.resume_display in
			if display_file && (cp.pmin = 0 || (p.pmin <= cp.pmin && p.pmax >= cp.pmax)) then begin
				if macro && not ctx.in_macro then
					(* force macro system loading of this class in order to get completion *)
					(fun() -> ignore(ctx.g.do_macro ctx MExpr c.cl_path cf.cf_name [] p))
				else begin
					cf.cf_type <- TLazy r;
					(fun() -> ignore((!r)()))
				end
			end else begin
				if not (is_full_type cf.cf_type) then cf.cf_type <- TLazy r;
				(fun() -> ())
			end
		end else if macro && not ctx.in_macro then
			(fun () -> ())
		else begin
			cf.cf_type <- TLazy r;
			if ctx.com.dead_code_elimination && cf.cf_name <> "__init__" then (fun() -> ()) else (fun () -> ignore(!r()))
		end
	in

	(* ----------------------- FIELD INIT ----------------------------- *)

	let loop_cf f =
		let name = f.cff_name in
		let p = f.cff_pos in
		let stat = List.mem AStatic f.cff_access in
		let inline = List.mem AInline f.cff_access in
		let ctx = { ctx with curclass = c; tthis = tthis } in
		let mark_used cf =
			if ctx.com.dead_code_elimination then cf.cf_meta <- (":?used",[],p) :: cf.cf_meta
		in
		match f.cff_kind with
		| FVar (t,e) ->
			if not stat && has_field name c.cl_super then error ("Redefinition of variable " ^ name ^ " in subclass is not allowed") p;
			if inline && not stat then error "Inline variable must be static" p;
			(match e with
			| None when inline -> error "Inline variable must be initialized" p
			| Some (_,p) when not stat -> error "Member variable initialization is not allowed outside of class constructor" p
			| _ -> ());
			let t = (match t with
				| None ->
					if not stat then error ("Type required for member variable " ^ name) p;
					mk_mono()
				| Some t ->
					let old = ctx.type_params in
					if stat then ctx.type_params <- [];
					let t = load_complex_type ctx p t in
					if stat then ctx.type_params <- old;
					t
			) in
			let cf = {
				cf_name = name;
				cf_doc = f.cff_doc;
				cf_meta = f.cff_meta;
				cf_type = t;
				cf_pos = f.cff_pos;
				cf_kind = Var (if inline then { v_read = AccInline ; v_write = AccNever } else { v_read = AccNormal; v_write = AccNormal });
				cf_expr = None;
				cf_public = is_public f.cff_access None;
				cf_params = [];
			} in
			let delay = (match e with
				| None when ctx.com.dead_code_elimination && not ctx.com.display ->
					let r = exc_protect (fun r ->
						r := (fun() -> t);
						mark_used cf;
						t
					) in
					cf.cf_type <- TLazy r;
					(fun() -> ())
				| None ->
					(fun() -> ())
				| Some e ->
					let r = exc_protect (fun r ->
						if not !return_partial_type then begin
							r := (fun() -> t);
							if ctx.com.verbose then Common.log ctx.com ("Typing " ^ (if ctx.in_macro then "macro " else "") ^ s_type_path c.cl_path ^ "." ^ name);
							mark_used cf;
							cf.cf_expr <- Some (type_static_var ctx t e p);
							cf.cf_type <- t;
						end;
						t
					) in
					bind_type cf r (snd e) false
			) in
			f, false, cf, delay
		| FFun fd ->
			let params = ref [] in
			params := List.map (fun (n,flags) ->
				(match flags with
				| [] -> ()
				| _ ->
					(** look if the type is contained into arguments **)
					let rec lookup_type t =
						match t with
						| CTPath { tpackage = []; tname = n2 } when n = n2 -> true
						| CTPath p -> List.exists lookup_tparam p.tparams
						| CTFunction (cl,r) -> List.exists lookup_type (r::cl)
						| CTExtend (_,fl) | CTAnonymous fl -> List.exists lookup_cfield fl
						| CTOptional t | CTParent t -> lookup_type t						
					and lookup_cfield f =
						match f.cff_kind with
						| FVar (None,_) -> false
						| FProp (_,_,t,_) | FVar (Some t,_) -> lookup_type t
						| FFun f -> lookup_fun f
					and lookup_fun f =
						List.exists (fun (_,_,t,_) -> match t with None -> false | Some t -> lookup_type t) f.f_args || 
						List.exists (fun (_,tl) -> List.exists lookup_type tl) f.f_params ||
						(match f.f_type with None -> false | Some t -> lookup_type t)
					and lookup_tparam = function
						| TPType t -> lookup_type t
						| TPExpr _ -> false
					in
					if lookup_fun { fd with f_type = None; f_params = [] } && not (has_meta ":allowConstraint" f.cff_meta) then error "This notation is not allowed because it can't be checked" p);
				type_type_params ctx ([],name) (fun() -> !params) p (n,flags)
			) fd.f_params;
			let params = !params in
			if inline && c.cl_interface then error "You can't declare inline methods in interfaces" p;
			let is_macro = (is_macro && stat) || has_meta ":macro" f.cff_meta in
			let f, stat, fd = if not is_macro || stat then
				f, stat, fd
			else if ctx.in_macro then
				(* non-static macros methods are turned into static when we are running the macro *)
				{ f with cff_access = AStatic :: f.cff_access }, true, fd
			else
				(* remove display of first argument which will contain the "this" expression *)
				f, stat, { fd with f_args = match fd.f_args with [] -> [] | _ :: l -> l }
			in
			let fd = if not is_macro then
				fd
			else if ctx.in_macro then
				let texpr = CTPath { tpackage = ["haxe";"macro"]; tname = "Expr"; tparams = []; tsub = None } in
				{
					f_params = fd.f_params;
					f_type = (match fd.f_type with None -> Some texpr | t -> t);
					f_args = List.map (fun (a,o,t,e) -> a,o,(match t with None -> Some texpr | _ -> t),e) fd.f_args;
					f_expr = fd.f_expr;
				}
			else
				let tdyn = Some (CTPath { tpackage = []; tname = "Dynamic"; tparams = []; tsub = None }) in
				let to_dyn = function
					| { tpackage = ["haxe";"macro"]; tname = "Expr"; tsub = Some ("ExprRequire"|"ExprOf"); tparams = [TPType t] } -> Some t
					| { tpackage = []; tname = ("ExprRequire"|"ExprOf"); tsub = None; tparams = [TPType t] } -> Some t
					| _ -> tdyn
				in
				{
					f_params = fd.f_params;
					f_type = (match fd.f_type with Some (CTPath t) -> to_dyn t | _ -> tdyn);
					f_args = List.map (fun (a,o,t,_) -> a,o,(match t with Some (CTPath t) -> to_dyn t | _ -> tdyn),None) fd.f_args;
					f_expr = None;
				}
			in
			let parent = (if not stat then get_parent c name else None) in
			let dynamic = List.mem ADynamic f.cff_access || (match parent with Some { cf_kind = Method MethDynamic } -> true | _ -> false) in
			if inline && dynamic then error "You can't have both 'inline' and 'dynamic'" p;
			ctx.curmethod <- name;
			ctx.type_params <- if stat then params else params @ ctx.type_params;
			let ret = type_opt ctx p fd.f_type in
			let args = List.map (fun (name,opt,t,c) ->
				let t, c = type_function_param ctx (type_opt ctx p t) c opt p in
				name, c, t
			) fd.f_args in
			let t = TFun (fun_args args,ret) in
			let constr = (name = "new") in
			if constr && c.cl_interface then error "An interface cannot have a constructor" p;
			if c.cl_interface && not stat && fd.f_expr <> None then error "An interface method cannot have a body" p;
			if constr then (match fd.f_type with
				| None | Some (CTPath { tpackage = []; tname = "Void" }) -> ()
				| _ -> error "A class constructor can't have a return value" p
			);
			let cf = {
				cf_name = name;
				cf_doc = f.cff_doc;
				cf_meta = f.cff_meta;
				cf_type = t;
				cf_pos = f.cff_pos;
				cf_kind = Method (if is_macro then MethMacro else if inline then MethInline else if dynamic then MethDynamic else MethNormal);
				cf_expr = None;
				cf_public = is_public f.cff_access parent;
				cf_params = params;
			} in
			let r = exc_protect (fun r ->
				if not !return_partial_type then begin
					r := (fun() -> t);
					incr stats.s_methods_typed;
					if ctx.com.verbose then Common.log ctx.com ("Typing " ^ (if ctx.in_macro then "macro " else "") ^ s_type_path c.cl_path ^ "." ^ name);
					let e , fargs = type_function ctx args ret (if constr then FConstructor else if stat then FStatic else FMember) fd p in
					let f = {
						tf_args = fargs;
						tf_type = ret;
						tf_expr = e;
					} in
					if stat && name = "__init__" then
						(match e.eexpr with
						| TBlock [] | TBlock [{ eexpr = TConst _ }] | TConst _ | TObjectDecl [] -> ()
						| _ -> c.cl_init <- Some e);
					mark_used cf;
					cf.cf_expr <- Some (mk (TFunction f) t p);
					cf.cf_type <- t;
				end;
				t
			) in
			let delay = if ((c.cl_extern && not inline) || c.cl_interface) && cf.cf_name <> "__init__" then
				(fun() -> ())
			else
				bind_type cf r (match fd.f_expr with Some e -> snd e | None -> f.cff_pos) is_macro
			in
			f, constr, cf, delay
		| FProp (get,set,t,eo) ->
			(match eo with
			| None -> ()
			| Some e -> error "Property initialization is not allowed" (snd e));
			let ret = load_complex_type ctx p t in
			let check_get = ref (fun() -> ()) in
			let check_set = ref (fun() -> ()) in
			let check_method m t () =
				if ctx.com.display then () else
				try
					let t2 = (if stat then (PMap.find m c.cl_statics).cf_type else fst (class_field c m)) in
					unify_raise ctx t2 t p;
				with
					| Error (Unify l,_) -> raise (Error (Stack (Custom ("In method " ^ m ^ " required by property " ^ name),Unify l),p))
					| Not_found -> if not (c.cl_interface || c.cl_extern) then display_error ctx ("Method " ^ m ^ " required by property " ^ name ^ " is missing") p
			in
			let get = (match get with
				| "null" -> AccNo
				| "dynamic" -> AccCall ("get_" ^ name)
				| "never" -> AccNever
				| "default" -> AccNormal
				| _ ->
					check_get := check_method get (TFun ([],ret));
					AccCall get
			) in
			let set = (match set with
				| "null" ->
					(* standard flash library read-only variables can't be accessed for writing, even in subclasses *)
					if c.cl_extern && (match c.cl_path with "flash" :: _  , _ -> true | _ -> false) && Common.defined ctx.com "flash9" then
						AccNever
					else
						AccNo
				| "never" -> AccNever
				| "dynamic" -> AccCall ("set_" ^ name)
				| "default" -> AccNormal
				| _ ->
					check_set := check_method set (TFun (["",false,ret],ret));
					AccCall set
			) in
			if set = AccNormal && (match get with AccCall _ -> true | _ -> false) then error "Unsupported property combination" p;
			let cf = {
				cf_name = name;
				cf_doc = f.cff_doc;
				cf_meta = f.cff_meta;
				cf_pos = f.cff_pos;
				cf_kind = Var { v_read = get; v_write = set };
				cf_expr = None;
				cf_type = ret;
				cf_public = is_public f.cff_access None;
				cf_params = [];
			} in
			if ctx.com.dead_code_elimination && not ctx.com.display then begin
				let r = exc_protect (fun r ->
					r := (fun() -> ret);
					mark_used cf;
					ret
				) in
				cf.cf_type <- TLazy r;
			end;
			f, false, cf, (fun() -> (!check_get)(); (!check_set)())
	in
	let rec check_require = function
		| [] -> None
		| (":require",conds,_) :: l ->
			let rec loop = function
				| [] -> check_require l
				| (EConst (Ident i | Type i),_) :: l ->
					if not (Common.defined ctx.com i) then
						Some i
					else
						loop l
				| _ -> error "Invalid require identifier" p
			in
			loop conds
		| _ :: l ->
			check_require l
	in
	let cl_req = check_require c.cl_meta in
	let fl = List.fold_left (fun acc f ->
		try
			let p = f.cff_pos in
			let fd , constr, f , delayed = loop_cf f in
			let is_static = List.mem AStatic fd.cff_access in
			if is_static && f.cf_name = "name" && Common.defined ctx.com "js" then error "This identifier cannot be used in Javascript for statics" p;
			if (is_static || constr) && c.cl_interface && f.cf_name <> "__init__" then error "You can't declare static fields in interfaces" p;
			let req = check_require fd.cff_meta in
			let req = (match req with None -> if is_static || constr then cl_req else None | _ -> req) in
			(match req with
			| None -> ()
			| Some r -> f.cf_kind <- Var { v_read = AccRequire r; v_write = AccRequire r });
			if constr then begin
				if c.cl_constructor <> None then error "Duplicate constructor" p;
				c.cl_constructor <- Some f;
			end else if not is_static || f.cf_name <> "__init__" then begin
				if PMap.mem f.cf_name (if is_static then c.cl_statics else c.cl_fields) then error ("Duplicate class field declaration : " ^ f.cf_name) p;
				if PMap.exists f.cf_name (if is_static then c.cl_fields else c.cl_statics) then error ("Same field name can't be use for both static and instance : " ^ f.cf_name) p;
				if is_static then begin
					c.cl_statics <- PMap.add f.cf_name f c.cl_statics;
					c.cl_ordered_statics <- f :: c.cl_ordered_statics;
				end else begin
					c.cl_fields <- PMap.add f.cf_name f c.cl_fields;
					c.cl_ordered_fields <- f :: c.cl_ordered_fields;
					if List.mem AOverride fd.cff_access then c.cl_overrides <- f.cf_name :: c.cl_overrides;
				end;
			end;
			delayed :: acc
		with Error (Custom str,p) ->
			display_error ctx str p;
			acc
	) [] fields in
	c.cl_ordered_statics <- List.rev c.cl_ordered_statics;
	c.cl_ordered_fields <- List.rev c.cl_ordered_fields;
	(*
		make sure a default contructor with same access as super one will be added to the class structure at some point.
	*)
	let rec add_constructor c =
		match c.cl_constructor, c.cl_super with
		| None, Some (csup,cparams) when not c.cl_extern ->
			add_constructor csup;
			(match csup.cl_constructor with
			| None -> ()
			| Some cf ->
				let args = (match follow (apply_params csup.cl_types cparams cf.cf_type) with
					| TFun (args,_) -> args
					| _ -> assert false
				) in
				let p = c.cl_pos in
				let vars = List.map (fun (n,o,t) ->
					let t = if o then ctx.t.tnull t else t in
					alloc_var n t, (if o then Some TNull else None)
				) args in
				let super_call = mk (TCall (mk (TConst TSuper) (TInst (csup,cparams)) p,List.map (fun (v,_) -> mk (TLocal v) v.v_type p) vars)) ctx.t.tvoid p in
				let constr = mk (TFunction {
					tf_args = vars;
					tf_type = ctx.t.tvoid;
					tf_expr = super_call;
				}) (TFun (List.map (fun (v,c) -> v.v_name, c <> None, v.v_type) vars,ctx.t.tvoid)) p in
				c.cl_constructor <- Some { cf with cf_pos = p; cf_type = constr.etype; cf_meta = []; cf_doc = None; cf_expr = Some constr })
		| _ ->
			(* nothing to do *)
			()
	in
	delay ctx (fun() -> add_constructor c);
	List.rev fl

let resolve_typedef ctx t =
	match t with
	| TClassDecl _ | TEnumDecl _ -> t
	| TTypeDecl td ->
		match follow td.t_type with
		| TEnum (e,_) -> TEnumDecl e
		| TInst (c,_) -> TClassDecl c
		| _ -> t

let add_module ctx m p =
	let decl_type t =
		let t = t_infos t in
		try
			let m2 = Hashtbl.find ctx.g.types_module t.mt_path in
			if m.m_path <> m2 && String.lowercase (s_type_path m2) = String.lowercase (s_type_path m.m_path) then error ("Module " ^ s_type_path m2 ^ " is loaded with a different case than " ^ s_type_path m.m_path) p;
			error ("Type name " ^ s_type_path t.mt_path ^ " is redefined from module " ^ s_type_path m2) p
		with
			Not_found ->
				Hashtbl.add ctx.g.types_module t.mt_path m.m_path
	in
	List.iter decl_type m.m_types;
	Hashtbl.add ctx.g.modules m.m_path m

let type_module ctx m file tdecls loadp =
	(* PASS 1 : build module structure - does not load any module or type - should be atomic ! *)
	let decls = ref [] in
	let make_path name priv =
		if List.exists (fun t -> snd (t_path t) = name) (!decls) then error ("Type name " ^ name ^ " is already defined in this module") loadp;
		if priv then (fst m @ ["_" ^ snd m], name) else (fst m, name)
	in
	let m = {
		m_id = alloc_mid();
		m_path = m;
		m_types = [];
		m_extra = module_extra (Common.unique_full_path file) (Common.get_signature ctx.com) (file_time file) (if ctx.in_macro then MMacro else MCode);
	} in
	List.iter (fun (d,p) ->
		match d with
		| EImport _ | EUsing _ -> ()
		| EClass d ->
			let priv = List.mem HPrivate d.d_flags in
			let path = make_path d.d_name priv in
			let c = mk_class m path p in
			c.cl_module <- m;
			c.cl_private <- priv;
			c.cl_doc <- d.d_doc;
			c.cl_meta <- d.d_meta;
			decls := TClassDecl c :: !decls
		| EEnum d ->
			let priv = List.mem EPrivate d.d_flags in
			let path = make_path d.d_name priv in
			let e = {
				e_path = path;
				e_module = m;
				e_pos = p;
				e_doc = d.d_doc;
				e_meta = d.d_meta;
				e_types = [];
				e_private = priv;
				e_extern = List.mem EExtern d.d_flags;
				e_constrs = PMap.empty;
				e_names = [];
			} in
			decls := TEnumDecl e :: !decls
		| ETypedef d ->
			let priv = List.mem EPrivate d.d_flags in
			let path = make_path d.d_name priv in
			let t = {
				t_path = path;
				t_module = m;
				t_pos = p;
				t_doc = d.d_doc;
				t_private = priv;
				t_types = [];
				t_type = mk_mono();
				t_meta = d.d_meta;
			} in
			decls := TTypeDecl t :: !decls
	) tdecls;
	m.m_types <- List.rev !decls;
	add_module ctx m loadp;
	(* PASS 2 : build types structure - does not type any expression ! *)
	let ctx = {
		com = ctx.com;
		g = ctx.g;
		t = ctx.t;
		curclass = ctx.curclass;
		tthis = ctx.tthis;
		ret = ctx.ret;
		current = m;
		locals = PMap.empty;
		local_types = ctx.g.std.m_types @ m.m_types;
		local_using = [];
		type_params = [];
		curmethod = "";
		curfun = FStatic;
		untyped = false;
		in_super_call = false;
		in_macro = ctx.in_macro;
		in_display = false;
		in_loop = false;
		opened = [];
		param_type = None;
		vthis = None;
	} in
	let delays = ref [] in
	let get_class name =
		let c = List.find (fun d -> match d with TClassDecl { cl_path = _ , n } -> n = name | _ -> false) m.m_types in
		match c with TClassDecl c -> c | _ -> assert false
	in
	let get_enum name =
		let e = List.find (fun d -> match d with TEnumDecl { e_path = _ , n } -> n = name | _ -> false) m.m_types in
		match e with TEnumDecl e -> e | _ -> assert false
	in
	let get_tdef name =
		let s = List.find (fun d -> match d with TTypeDecl { t_path = _ , n } -> n = name | _ -> false) m.m_types in
		match s with TTypeDecl s -> s | _ -> assert false
	in
	(* here is an additional PASS 1 phase, which handle the type parameters declaration, with lazy contraints *)
	List.iter (fun (d,p) ->
		match d with
		| EImport _ | EUsing _ -> ()
		| EClass d ->
			let c = get_class d.d_name in
			c.cl_types <- List.map (type_type_params ctx c.cl_path (fun() -> c.cl_types) p) d.d_params;
		| EEnum d ->
			let e = get_enum d.d_name in
			e.e_types <- List.map (type_type_params ctx e.e_path (fun() -> e.e_types) p) d.d_params;
		| ETypedef d ->
			let t = get_tdef d.d_name in
			t.t_types <- List.map (type_type_params ctx t.t_path (fun() -> t.t_types) p) d.d_params;
	) tdecls;
	(* back to PASS2 *)
	List.iter (fun (d,p) ->
		match d with
		| EImport t ->
			(match t.tsub with
			| None ->
				let md = ctx.g.do_load_module ctx (t.tpackage,t.tname) p in
				let types = List.filter (fun t -> not (t_infos t).mt_private) md.m_types in
				ctx.local_types <- ctx.local_types @ types
			| Some _ ->
				let t = load_type_def ctx p t in
				ctx.local_types <- ctx.local_types @ [t]
			)
		| EUsing t ->
			(match t.tsub with
			| None ->
				let md = ctx.g.do_load_module ctx (t.tpackage,t.tname) p in
				let types = List.filter (fun t -> not (t_infos t).mt_private) md.m_types in
				ctx.local_using <- ctx.local_using @ (List.map (resolve_typedef ctx) types);
			| Some _ ->
				let t = load_type_def ctx p t in
				ctx.local_using<- ctx.local_using @ [resolve_typedef ctx t])
		| EClass d ->
			let c = get_class d.d_name in
			let checks = if not ctx.com.display then [check_overriding ctx c p; check_interfaces ctx c p] else [] in
			delays := !delays @ (checks @ init_class ctx c p d.d_flags d.d_data)
		| EEnum d ->
			let e = get_enum d.d_name in
			let ctx = { ctx with type_params = e.e_types } in
			let h = (try Some (Hashtbl.find ctx.g.type_patches e.e_path) with Not_found -> None) in
			(match h with
			| None -> ()
			| Some (h,hcl) ->
				Hashtbl.iter (fun _ _ -> error "Field type patch not supported for enums" e.e_pos) h;
				e.e_meta <- e.e_meta @ hcl.tp_meta);
			let constructs = ref d.d_data in
			let get_constructs() =
				List.map (fun (c,doc,meta,pl,p) ->
					{
						cff_name = c;
						cff_doc = doc;
						cff_meta = meta;
						cff_pos = p;
						cff_access = [];
						cff_kind = (match pl with
							| [] -> FVar (None,None)
							| _ -> FFun { f_params = []; f_type = None; f_expr = None; f_args = List.map (fun (n,o,t) -> n,o,Some t,None) pl });
					}
				) (!constructs)
			in
			build_module_def ctx (TEnumDecl e) e.e_meta get_constructs (fun (e,p) ->
				match e with
				| EVars [_,Some (CTAnonymous fields),None] ->
					constructs := List.map (fun f ->
						(f.cff_name,f.cff_doc,f.cff_meta,(match f.cff_kind with
						| FVar (None,None) -> []
						| FFun { f_params = []; f_type = None; f_expr = (None|Some (EBlock [],_)); f_args = pl } -> List.map (fun (n,o,t,_) -> match t with None -> error "Missing function parameter type" f.cff_pos | Some t -> n,o,t) pl
						| _ -> error "Invalid enum constructor in @:build result" p
						),f.cff_pos)
					) fields
				| _ -> error "Enum build macro must return a single variable with anonymous object fields" p
			);
			let et = TEnum (e,List.map snd e.e_types) in
			let names = ref [] in
			let index = ref 0 in
			List.iter (fun (c,doc,meta,t,p) ->
				if c = "name" && Common.defined ctx.com "js" then error "This identifier cannot be used in Javascript" p;
				let t = (match t with
					| [] -> et
					| l ->
						let pnames = ref PMap.empty in
						TFun (List.map (fun (s,opt,t) ->
							if PMap.mem s (!pnames) then error ("Duplicate parameter '" ^ s ^ "' in enum constructor " ^ c) p;
							pnames := PMap.add s () (!pnames);
							s, opt, load_type_opt ~opt ctx p (Some t)
						) l, et)
				) in
				if PMap.mem c e.e_constrs then error ("Duplicate constructor " ^ c) p;
				e.e_constrs <- PMap.add c {
					ef_name = c;
					ef_type = t;
					ef_pos = p;
					ef_doc = doc;
					ef_index = !index;
					ef_meta = meta;
				} e.e_constrs;
				incr index;
				names := c :: !names;
			) (!constructs);
			e.e_names <- List.rev !names;
			e.e_extern <- e.e_extern || e.e_names = [];
		| ETypedef d ->
			let t = get_tdef d.d_name in
			let ctx = { ctx with type_params = t.t_types } in
			let tt = load_complex_type ctx p d.d_data in
			if t.t_type == follow tt then error "Recursive typedef is not allowed" p;
			(match t.t_type with
			| TMono r ->
				(match !r with
				| None -> r := Some tt;
				| Some _ -> assert false);
			| _ -> assert false);
	) tdecls;
	(* PASS 3 : type checking, delayed until all modules and types are built *)
	List.iter (delay ctx) (List.rev (!delays));
	m

let resolve_module_file com m remap p =
	let file = (match m with
		| [] , name -> name
		| x :: l , name ->
			let x = (try
				match PMap.find x com.package_rules with
				| Forbidden -> raise (Error (Forbid_package (x,m),p));
				| Directory d -> d
				| Remap d -> remap := d :: l; d
				with Not_found -> x
			) in
			String.concat "/" (x :: l) ^ "/" ^ name
	) ^ ".hx" in
	let file = Common.find_file com file in
	match String.lowercase (snd m) with
	| "con" | "aux" | "prn" | "nul" | "com1" | "com2" | "com3" | "lpt1" | "lpt2" | "lpt3" when Sys.os_type = "Win32" ->
		(* these names are reserved by the OS - old DOS legacy, such files cannot be easily created but are reported as visible *)
		if (try (Unix.stat file).Unix.st_size with _ -> 0) > 0 then file else raise Not_found
	| _ -> file

let parse_module ctx m p =
	let remap = ref (fst m) in
	let file = resolve_module_file ctx.com m remap p in
	let pack, decls = (!parse_hook) ctx.com file p in
	if pack <> !remap then begin
		let spack m = if m = [] then "<empty>" else String.concat "." m in
		if p == Ast.null_pos then
			display_error ctx ("Invalid commandline class : " ^ s_type_path m ^ " should be " ^ s_type_path (pack,snd m)) p
		else
			display_error ctx ("Invalid package : " ^ spack (fst m) ^ " should be " ^ spack pack) p
	end;
	file, if !remap <> fst m then
		(* build typedefs to redirect to real package *)
		List.rev (List.fold_left (fun acc (t,p) ->
			let build f d =
				let priv = List.mem f d.d_flags in
				(ETypedef {
					d_name = d.d_name;
					d_doc = None;
					d_meta = [];
					d_params = d.d_params;
					d_flags = if priv then [EPrivate] else [];
					d_data = CTPath (if priv then { tpackage = []; tname = "Dynamic"; tparams = []; tsub = None; } else
						{
							tpackage = !remap;
							tname = d.d_name;
							tparams = List.map (fun (s,_) ->
								TPType (CTPath { tpackage = []; tname = s; tparams = []; tsub = None; })
							) d.d_params;
							tsub = None;
						});
				},p) :: acc
			in
			match t with
			| EClass d -> build HPrivate d
			| EEnum d -> build EPrivate d
			| ETypedef d -> build EPrivate d
			| EImport _ | EUsing _ -> acc
		) [(EImport { tpackage = !remap; tname = snd m; tparams = []; tsub = None; },null_pos)] decls)
	else
		decls

let load_module ctx m p =
	let m2 = (try
		Hashtbl.find ctx.g.modules m
	with
		Not_found ->
			match !type_module_hook ctx m p with
			| Some m -> m
			| None ->
			let file, decls = (try
				parse_module ctx m p
			with Not_found ->
				let rec loop = function
					| [] ->
						raise (Error (Module_not_found m,p))
					| load :: l ->
						match load m p with
						| None -> loop l
						| Some (file,(_,a)) -> file, a
				in
				loop ctx.com.load_extern_type
			) in
			type_module ctx m file decls p
	) in
	add_dependency ctx.current m2;
	m2
