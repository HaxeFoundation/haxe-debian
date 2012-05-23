﻿package unit;

class MyDynamicClass {

	var v : Int;

	public function new(v) {
		this.v = v;
	}

	public function get() {
		return v;
	}

	public dynamic function add(x,y) {
		return v + x + y;
	}

	public inline function iadd(x,y) {
		return v + x + y;
	}

	static var Z = 10;

	public dynamic static function staticDynamic(x,y) {
		return Z + x + y;
	}

}

class MyDynamicSubClass extends MyDynamicClass {

	override function add(x,y) {
		return (v + x + y) * 2;
	}

}

class MyDynamicSubClass2 extends MyDynamicClass {

	override dynamic function add(x,y) {
		return (v + x + y) * 2;
	}

}

class MyOtherDynamicClass extends MyDynamicClass {

	public function new(v) {
		add = function(x,y) return x + y + 10;
		super(v);
	}

}

interface IDefArgs {
	public function get( x : Int = 5 ) : Int;
}

class BaseDefArgs {
	public function get( x = 3 ) {
		return x;
	}
}

class ExtDefArgs extends BaseDefArgs, implements IDefArgs {
	public function new() {
	}
	override function get( x = 7 ) {
		return x;
	}
}

class TestMisc extends Test {

	function testClosure() {
		var c = new MyClass(100);
		var add = c.add;
		eq( c.add(1,2), 103 );
		eq( callback(c.add,1)(2), 103 );
		eq( add(1,2), 103 );

		var x = 4;
		var f = function() return x;
		eq( f(), 4 );
		x++;
		eq( f(), 5 );

		var o = { f : f };
		eq( o.f(), 5 );
		eq( o.f, o.f ); // we shouldn't create a new closure here

		var o = { add : c.add };
		eq( o.add(1,2), 103 );
		eq( o.add, o.add ); // we shouldn't create a new closure here

		var o = { cos : Math.cos };
		eq( o.cos(0), 1. );

		// check enum
		var c = MyEnum.C;
		t( Type.enumEq(MyEnum.C(1,"hello"), c(1,"hello")) );
	}

	function testInlineClosure() {
		var inst = new MyDynamicClass(100);
		var add = inst.iadd;
		eq( inst.iadd(1,2), 103 );
		eq( add(1,2), 103 );
	}

	function testDynamicClosure() {
		var inst = new MyDynamicClass(100);
		var add = inst.add;
		eq( inst.add(1,2), 103 );
		eq( callback(inst.add,1)(2), 103 );
		eq( add(1,2), 103 );

		// check overriden dynamic method
		var inst = new MyDynamicSubClass(100);
		var add = inst.add;
		eq( inst.add(1,2), 206 );
		eq( callback(inst.add,1)(2), 206 );
		eq( add(1,2), 206 );

		// check overriden dynamic method
		var inst = new MyDynamicSubClass2(100);
		var add = inst.add;
		eq( inst.add(1,2), 206 );
		eq( callback(inst.add,1)(2), 206 );
		eq( add(1,2), 206 );
		
		// check redefined dynamic method
		inst.add = function(x,y) return inst.get() * 2 + x + y;
		var add = inst.add;
		eq( inst.add(1,2), 203 );
		eq( callback(inst.add,1)(2), 203 );
		eq( add(1,2), 203 );

		// check inherited dynamic method
		var inst = new MyOtherDynamicClass(0);
		var add = inst.add;
		eq( inst.add(1,2), 13 );
		eq( callback(inst.add,1)(2), 13 );
		eq( add(1,2), 13 );

		// check static dynamic
		eq( MyDynamicClass.staticDynamic(1,2), 13 );
		MyDynamicClass.staticDynamic = function(x,y) return x + y + 100;
		eq( MyDynamicClass.staticDynamic(1,2), 103 );
	}

	function testMD5() {
		eq( haxe.Md5.encode(""), "d41d8cd98f00b204e9800998ecf8427e" );
		eq( haxe.Md5.encode("hello"), "5d41402abc4b2a76b9719d911017c592" );
		// depending of ISO/UTF8 native
		allow( haxe.Md5.encode("héllo"), ["1a722f7e6c801d9e470a10cb91ba406d","be50e8478cf24ff3595bc7307fb91b50"] );
	}

	function testBaseCode() {
		var b = new haxe.BaseCode(haxe.io.Bytes.ofString("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-"));
		eq( b.encodeString("Héllow"), "iceFr6NLtM" );
		eq( b.decodeString("iceFr6NLtM"), "Héllow" );
	}

	function testUrlEncode() {
		eq( StringTools.urlEncode("é"), "%C3%A9" );
		eq( StringTools.urlDecode("%C3%A9"), "é" );
	}

	function opt1( ?x : Int, ?y : String ) {
		return { x : x, y : y };
	}

	function opt2( ?x = 5, ?y = "hello" ) {
		return { x : x, y : y };
	}
	
	function opt3( ?x : Null<Int> = 5, ?y : Null<Float> = 6 ) {
		return { x : x, y : y };
	}

	function testOptionalParams() {
		eq( opt1().x, null );
		eq( opt1().y, null );
		eq( opt1(55).x, 55 );
		eq( opt1(55).y, null );
		eq( opt1("str").x, null );
		eq( opt1("str").y, "str" );
		eq( opt1(66,"hello").x, 66 );
		eq( opt1(66, "hello").y, "hello" );

		eq( opt2().x, 5 );
		eq( opt2().y, "hello" );
		
		#if !flash9
		eq( opt2(null, null).x, 5 );
		#end
		eq( opt2(0, null).y, "hello" );

		eq( opt3().x, 5 );
		eq( opt3().y, 6 );
		eq( opt3(9).x, 9 );
		eq( opt3(9).y, 6 );
		eq( opt3(9,10).x, 9 );
		eq( opt3(9,10).y, 10 );
		eq( opt3(null,null).x, 5 );
		eq( opt3(null,null).y, 6 );
		eq( opt3(null).x, 5 );
		eq( opt3(null).y, 6 );
		eq( opt3(null,7).x, 5 );
		eq( opt3(null, 7).y, 7 );
		
		// skipping
		eq( opt3(7.4).x, 5 );
		eq( opt3(7.4).y, 7.4 );
	}

	function testIncr() {
		var z = 0;
		eq( z++, 0 );
		eq( z, 1 );
		eq( ++z, 2 );
		eq( z, 2 );
		z++;
		eq( z, 3 );
		++z;
		eq( z, 4 );

		eq( z += 3, 7 );

		var x = 0;
		var arr = [3];
		eq( arr[x++]++, 3 );
		eq( x, 1 );
		eq( arr[0], 4 );
		x = 0;
		eq( arr[x++] += 3, 7 );
		eq( arr[0], 7 );

		var x = 0;
		var arr = [{ v : 3 }];
		eq( arr[x++].v++, 3 );
		eq( x, 1 );
		eq( arr[0].v, 4 );

		#if !as3
		x = 0;
		eq( arr[x++].v += 3, 7 );
		eq( arr[0].v, 7 );
		#end
	}

	function testInitOrder() {
		var i = 0;
		var o = {
			y : i++,
			x : i++,
			z : i++,
			blabla : i++,
		};
		eq(o.y,0);
		eq(o.x,1);
		eq(o.z,2);
		eq(o.blabla,3);
	}

	static inline function foo(x) return x + 5

	function testInline() {
		// check that operations are correctly generated
		var x = 3; // prevent optimization
		eq( 2 * foo(x), 16 );
		eq( -foo(x), -8 );
	}

	function testEvalAccessOrder() {
		var a = [0,0];
		var x = 0;
		a[x++]++;
		eq(a[0],1);
		eq(a[1],0);

		var x = 0;
		var a = new Array();
		a[x++] = x++;
		eq(a[0],1);

		var x = 0;
		var foo = function() return x++;
		a[foo()] = foo();
		eq(a[0],1);
	}

	static var add = function (x, y) return x + y;

	function testStaticVarFun() {
		eq( add(2,3), 5);
	}
	
	function testDefArgs() {
		var e = new ExtDefArgs();
		eq( e.get(), 7 );
		var b : BaseDefArgs = e;
		eq( e.get(), 7 );
		var i : IDefArgs = e;
		eq( e.get(), 7 );
	}

	function testStringBuf() {
		var b = new StringBuf();
		b.add( -45);
		b.add(1.456);
		b.add(null);
		b.add(true);
		b.add(false);
		b.add("Hello!");
		b.addSub("Bla", 1, 2);
		b.addChar("R".code);
		eq(b.toString(), "-451.456nulltruefalseHello!laR");
	}
	
	function testToString():Void
	{
		var x = { toString : function() return "foo" };
		eq( Std.string(x), "foo" );
	}
	
	#if !macro
	function testFormat()
	{
		var x = 5;
		var y = 6;
		eq(Std.format("$x${x+y}"), "511");
	}
	#end
	
	function testJSon() {
		var str = haxe.Json.stringify( { x : -4500, y : 1.456, a : ["hello", "wor'\"\n\t\rd"] } );
		str = str.substr(1, str.length - 2); // remove {}
		var parts = str.split(",");
		t( parts.remove('"x":-4500') );
		t( parts.remove('"y":1.456') );
		t( parts.remove('"a":["hello"') );
		t( parts.remove('"wor\'\\"\\n\\t\\rd"]') );
		eq( parts.join("#"), "" );
		
		// no support for regexps
		#if flash8
		return;
		#end
		
		function id(v:Dynamic,?pos:haxe.PosInfos) eq(haxe.Json.parse(haxe.Json.stringify(v)),v);
		function deepId(v:Dynamic) {
			var str = haxe.Json.stringify(v);
			eq(haxe.Json.stringify(haxe.Json.parse(str)), str);
		}
		
		id(true);
		id(false);
		id(null);
		id(0);
		id(145);
		id( -145 );
		id(0.15461);
		id( -485.15461);
		id( 1e10 );
		id( -1e-10 );
		id( "" );
		id( "hello" );
		id( "he\n\r\t\\\\llo");

		deepId( {field: 4} );
		deepId( {test: {nested: null}} );
		deepId( {array: [1,2,3,"str"]} );
		
		eq( haxe.Json.parse('"\\u00E9"'), "é" );
		
	}
	
}
