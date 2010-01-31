package unit;
import Type;

class TestReflect extends Test {

	static var TYPES = [
		null,Int,String,Bool,Float,
		Array,Hash,List,Date,Xml,Math,
		unit.MyEnum,unit.MyClass,unit.MySubClass,
		Class,Enum,Void,Dynamic,
	];

	static inline function u( s : String ) : String {
		#if flash
		return untyped __unprotect__(s);
		#else
		return s;
		#end
	}

	static inline function u2( s : String, s2 ) : String {
		return u(s)+"."+u(s2);
	}

	static var TNAMES = [
		"null","Int","String","Bool","Float",
		"Array",u("Hash"),u("List"),"Date","Xml","Math",
		u2("unit","MyEnum"),u2("unit","MyClass"),u2("unit","MySubClass"),
		#if !flash9 u #end("Class"),u("Enum"),u("Void"),u("Dynamic"),
	];

	public function testTypes() {
		for( i in 1...TYPES.length ) {
			var t : Dynamic = TYPES[i];
			var name = TNAMES[i];
			infos("type "+name);
			f( t == null );
			if( name == u("Enum") ) {
				// neither an enum or a class
			} else if( t == MyEnum || t == Void || t == Bool ) {
				eq( Type.getEnumName(t), name );
				eq( Type.resolveEnum(name), t );
			} else {
				eq( Type.getClassName(t), name );
				eq( Type.resolveClass(name), t );
			}
		}
		infos(null);
		// we allow to have a common object class
		allow( Class == Enum, [true,false] );
		// these are very specific cases since we can't allow reflection on core type
		unspec( function() Type.getEnumConstructs(Void) );
		unspec( function() Type.getEnumConstructs(Bool) );
	}

	public function testIs() {
		is(null,null);
		is(0,Int,Float);
		is(1,Int,Float);
		is(-1,Int,Float);
		// unspec : is(1.0,Int,Float);
		is(1.2,Float);
		is(1e10,Float);
		is(-1e10,Float);
		is(Math.NaN,Float);
		is(Math.POSITIVE_INFINITY,Float);
		is(Math.NEGATIVE_INFINITY,Float);
		is(true,Bool);
		is(false,Bool);
		is("Hello",String);
		is("123",String);
		is("false",String);
		is("",String);
		is([],Array);
		is(new List(),List);
		is(new Hash(),Hash);
		is(new MyClass(0),MyClass);
		is(new MySubClass(0),MyClass,MySubClass);
		is(MyEnum.A,MyEnum);
		is(MyEnum.C(0,""),MyEnum);
		is(Date.now(),Date);
		is({ x : 0 },null);
		is(function() { },null);
		is(MyClass,Class);
		is(MyEnum,Enum);
		is(Void,Enum);
		is(Class,Class);
		// it is allowed to have Class==Enum
		if( Class == Enum ) is(Enum,Enum) else is(Enum,null);
	}

	function is( v : Dynamic, t1 : Dynamic, ?t2 : Dynamic, ?pos : haxe.PosInfos ){
		for( i in 0...TYPES.length ) {
			var c : Dynamic = TYPES[i];
			infos(Std.string(v)+" is "+TNAMES[i]);
			eq( Std.is(v,c), c != null && (c == t1 || c == t2) || (c == Dynamic), pos );
		}
		infos(null);
		t( Std.is(v,Dynamic), pos );
	}

	public function testTypeof() {
		typeof(null,TNull);
		typeof(0,TInt);
		typeof(1,TInt);
		typeof(-1,TInt);
		typeof(1.2,TFloat);
		typeof(1e10,TFloat);
		typeof(-1e10,TFloat);
		typeof(Math.NaN,TFloat);
		typeof(Math.POSITIVE_INFINITY,TFloat);
		typeof(Math.NEGATIVE_INFINITY,TFloat);
		typeof(true,TBool);
		typeof(false,TBool);
		typeof("Hello",TClass(String));
		typeof("",TClass(String));
		typeof([],TClass(Array));
		typeof(new List(),TClass(List));
		typeof(new Hash(),TClass(Hash));
		typeof(new MyClass(0),TClass(MyClass));
		typeof(new MySubClass(0),TClass(MySubClass));
		typeof(MyEnum.A,TEnum(MyEnum));
		typeof(MyEnum.C(0,""),TEnum(MyEnum));
		typeof(Date.now(),TClass(Date));
		typeof({ x : 0 },TObject);
		typeof(function() {},TFunction);
		typeof(MyClass,TObject);
		typeof(MyEnum,TObject);
		typeof(Void,TObject);
		#if !flash9
		// on flash9, Type.typeof(Class) is crashing the player
		typeof(Class,TObject);
		typeof(Enum,TObject);
		#end
	}

	function typeof( v : Dynamic, rt : ValueType, ?pos : haxe.PosInfos ) {
		var vt = Type.typeof(v);
		infos("typeof("+Std.string(v)+") = "+vt);
		t( Type.enumEq(vt,rt), pos );
	}

	function testConv() {
		eq( String.fromCharCode(65), "A" );
		unspec(function() String.fromCharCode(1024));
		eq( "A".charCodeAt(0), 65 );
		eq( "".charCodeAt(0), null );
		eq( Std.int(65), 65 );
		eq( Std.int(65.456), 65 );
		eq( Std.int(-65.456), -65 );
		eq( Std.int(1.5), 1 );
		eq( Std.int(-1.5), -1 );
		eq( Std.int(1.7), 1 );
		eq( Std.int(-1.7), -1 );
		eq( Std.parseInt("65"), 65 );
		eq( Std.parseInt("65.3"), 65 );
		eq( Std.parseFloat("65"), 65.0 );
		eq( Std.parseFloat("65.3"), 65.3 );
		eq( Std.parseFloat("-1e10"), -1e10 );
		eq( Std.parseInt("0xFF"), 255 );
	}

	function testCreate() {
		var i = Type.createInstance(MyClass,[33]);
		t( Std.is(i,MyClass) );
		eq( i.get(), 33 );
		eq( i.intValue, 55 );
		var i = Type.createEmptyInstance(MyClass);
		t( Std.is(i,MyClass) );
		eq( i.get(), #if (flash9 || cpp) 0 #else null #end );
		eq( i.intValue, #if (flash9 || cpp) 0 #else null #end );
		var e : MyEnum = Type.createEnum(MyEnum,__unprotect__("A"));
		eq( e, MyEnum.A );
		var e : MyEnum = Type.createEnum(MyEnum,__unprotect__("C"),[55,"hello"]);
		switch( e ) {
		case C(i,s): eq(i,55); eq(s,"hello");
		default: assert();
		}
		exc( function() Type.createEnum(MyEnum,__unprotect__("A"),[0]) );
		exc( function() Type.createEnum(MyEnum,__unprotect__("C")) );
		exc( function() Type.createEnum(MyEnum,"Z",[]) );
	}

}
