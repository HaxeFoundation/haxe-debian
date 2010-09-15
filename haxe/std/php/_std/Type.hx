enum ValueType {
	TNull;
	TInt;
	TFloat;
	TBool;
	TObject;
	TFunction;
	TClass( c : Class<Dynamic> );
	TEnum( e : Enum<Dynamic> );
	TUnknown;
}

@:core_api class Type {

	public static function getClass<T>( o : T ) : Class<T> untyped {
		if(o == null) return null;
		untyped if(__call__("is_array",  o)) {
			if(__call__("count", o) == 2 && __call__("is_callable", o)) return null;
			return __call__("_hx_ttype", 'Array');
		}
		if(untyped __call__("is_string", o)) {
			if(__call__("_hx_is_lambda", untyped o)) return null;
			return __call__("_hx_ttype", 'String');
		}
		if(!untyped __call__("is_object", o)) {
			return null;
		}
		var c = __call__("get_class", o);
		if(c == false || c == '_hx_anonymous' || __call__("is_subclass_of", c, "enum"))
			return null;
		else
			return __call__("_hx_ttype", c);
	}

	public static function getEnum( o : Dynamic ) : Enum<Dynamic> untyped {
		if(!__php__("$o instanceof Enum"))
			return null;
		else
			return __php__("_hx_ttype(get_class($o))");
	}

	public static function getSuperClass( c : Class<Dynamic> ) : Class<Dynamic> {
		var s = untyped __php__("get_parent_class")(c.__tname__);
		if(s == false)
			return null;
		else
			return untyped __call__("_hx_ttype", s);
	}

	public static function getClassName( c : Class<Dynamic> ) : String {
		if( c == null )
			return null;
		return untyped c.__qname__;
	}

	public static function getEnumName( e : Enum<Dynamic> ) : String {
		return untyped e.__qname__;
	}

	public static function resolveClass( name : String ) : Class<Dynamic> untyped {
		var c = untyped __call__("_hx_qtype", name);
		if(__php__("$c instanceof _hx_class"))
			return c;
		else
			return null;
	}

	public static function resolveEnum( name : String ) : Enum<Dynamic> {
		var e = untyped __call__("_hx_qtype", name);
		if(untyped __php__("$e instanceof _hx_enum"))
			return e;
		else
			return null;
	}

	public static function createInstance<T>( cl : Class<T>, args : Array<Dynamic> ) : T untyped {
		if(cl.__qname__ == 'Array') return [];
		if(cl.__qname__ == 'String') return args[0];
		var c = cl.__rfl__();
		if(c == null) return null;
		return __php__("$inst = $c->getConstructor() ? $c->newInstanceArgs($args->�a) : $c->newInstanceArgs()");
	}

	public static function createEmptyInstance<T>( cl : Class<T> ) : T untyped {
		if(cl.__qname__ == 'Array') return [];
		if(cl.__qname__ == 'String') return '';
		try {
			__php__("php_Boot::$skip_constructor = true");
			var rfl = cl.__rfl__();
			if(rfl == null) return null;
			var m = __php__("$rfl->getConstructor()");
			var nargs : Int = m.getNumberOfRequiredParameters();
			var i;
			if(nargs > 0) {
				var args = __call__("array_fill", 0, m.getNumberOfRequiredParameters(), null);
				i = __php__("$rfl->newInstanceArgs($args)");
			} else {
				i = __php__("$rfl->newInstanceArgs(array())");
			}
			__php__("php_Boot::$skip_constructor = false");
			return i;
		} catch( e : Dynamic ) {
			__php__("php_Boot::$skip_constructor = false");
			throw "Unable to instantiate " + Std.string(cl);
		}
		return null;
	}

	public static function createEnum<T>( e : Enum<T>, constr : String, ?params : Array<Dynamic> ) : T {
		var f = Reflect.field(e,constr);
		if( f == null ) throw "No such constructor "+constr;
		if( Reflect.isFunction(f) ) {
			if( params == null ) throw "Constructor "+constr+" need parameters";
			return Reflect.callMethod(e,f,params);
		}
		if( params != null && params.length != 0 )
			throw "Constructor "+constr+" does not need parameters";
		return f;
	}

	public static function createEnumIndex<T>( e : Enum<T>, index : Int, ?params : Array<Dynamic> ) : T {
		var c = Type.getEnumConstructs(e)[index];
		if( c == null ) throw index+" is not a valid enum constructor index";
		return createEnum(e,c,params);
	}

	public static function getInstanceFields( c : Class<Dynamic> ) : Array<String> {
		if(untyped c.__qname__ == 'String') return ['substr', 'charAt', 'charCodeAt', 'indexOf', 'lastIndexOf', 'split', 'toLowerCase', 'toUpperCase', 'toString', 'length'];
		if(untyped c.__qname__ == 'Array') return  ['push', 'concat', 'join', 'pop', 'reverse', 'shift', 'slice', 'sort', 'splice', 'toString', 'copy', 'unshift', 'insert', 'remove', 'iterator', 'length'];
		untyped __php__("
		$rfl = $c->__rfl__();
		if($rfl === null) return new _hx_array(array());
		$r = array();
		$internals = array('__construct', '__call', '__get', '__set', '__isset', '__unset', '__toString');
		$ms = $rfl->getMethods();
		while(list(, $m) = each($ms)) {
			$n = $m->getName();
			if(!$m->isStatic() && ! in_array($n, $internals)) $r[] = $n;
		}
		$ps = $rfl->getProperties();
		while(list(, $p) = each($ps))
			if(!$p->isStatic()) $r[] = $p->getName()");
		return untyped __php__("new _hx_array(array_values(array_unique($r)))");
	}

	public static function getClassFields( c : Class<Dynamic> ) : Array<String> {
		if(untyped c.__qname__ == 'String') return ['fromCharCode'];
		if(untyped c.__qname__ == 'Array')  return [];
		untyped __php__("
		$rfl = $c->__rfl__();
		if($rfl === null) return new _hx_array(array());
		$ms = $rfl->getMethods();
		$r = array();
		while(list(, $m) = each($ms))
			if($m->isStatic()) $r[] = $m->getName();
		$ps = $rfl->getProperties();
		while(list(, $p) = each($ps))
			if($p->isStatic()) $r[] = $p->getName();
		");
		return untyped __php__("new _hx_array(array_unique($r))");
	}

	public static function getEnumConstructs( e : Enum<Dynamic> ) : Array<String> untyped {
		if (__php__("$e->__tname__ == 'Bool'")) return ['true', 'false'];
		if (__php__("$e->__tname__ == 'Void'")) return [];
		return __call__("new _hx_array", e.__constructors);
	}

	public static function typeof( v : Dynamic ) : ValueType untyped {
		if(v == null) return TNull;
		if(__call__("is_array", v)) {
			if(__call__("is_callable", v)) return TFunction;
			return TClass(Array);
		}
		if(__call__("is_string", v)) {
			if(__call__("_hx_is_lambda", v)) return TFunction;
			return TClass(String);
		}
		if(__call__("is_bool", v)) return TBool;
		if(__call__("is_int", v)) return TInt;
		if(__call__("is_float", v)) return TFloat;
		if(__php__("$v instanceof _hx_anonymous"))  return TObject;
		if(__php__("$v instanceof _hx_enum"))  return TObject;
		if(__php__("$v instanceof _hx_class"))  return TObject;

		var c = __php__("_hx_ttype(get_class($v))");

		if(__php__("$c instanceof _hx_enum"))  return TEnum(cast c);
		if(__php__("$c instanceof _hx_class")) return TClass(cast c);
		return TUnknown;
	}

	public static function enumEq<T>( a : T, b : T ) : Bool untyped {
		if( a == b )
			return true;
		try {
			if( a.index != b.index )
				return false;
			for( i in 0...__call__("count", a.params))
				if(getEnum(untyped __php__("$a->params[$i]")) != null) {
					if(!untyped enumEq(__php__("$a->params[$i]"),__php__("$b->params[$i]")))
						return false;
				} else {
					if(!untyped __call__("_hx_equal", __php__("$a->params[$i]"),__php__("$b->params[$i]")))
						return false;
				}
		} catch( e : Dynamic ) {
			return false;
		}
		return true;
	}

	public static function enumConstructor( e : Dynamic ) : String {
		return e.tag;
	}

	public static function enumParameters( e : Dynamic ) : Array<Dynamic> {
		if(e.params == null)
			return [];
		else
			return untyped __php__("new _hx_array($e->params)");
	}

	public inline static function enumIndex( e : Dynamic ) : Int {
		return e.index;
	}

}

