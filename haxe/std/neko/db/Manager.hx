/*
 * Copyright (c) 2005, The haXe Project Contributors
 * All rights reserved.
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 *   - Redistributions of source code must retain the above copyright
 *     notice, this list of conditions and the following disclaimer.
 *   - Redistributions in binary form must reproduce the above copyright
 *     notice, this list of conditions and the following disclaimer in the
 *     documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE HAXE PROJECT CONTRIBUTORS "AS IS" AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE HAXE PROJECT CONTRIBUTORS BE LIABLE FOR
 * ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH
 * DAMAGE.
 */
package neko.db;

import Reflect;
import neko.db.Connection;

/**
	SPOD Manager : the persistent object database manager. See the tutorial on
	haXe website to learn how to use SPOD.
**/
class Manager<T : Object> {

	/* ----------------------------- STATICS ------------------------------ */
	public static var cnx(default,setConnection) : Connection;
	private static var object_cache : Hash<Object> = new Hash();
	private static var init_list : List<Manager<Object>> = new List();
	private static var cache_field = "__cache__";
	private static var no_update : Dynamic = function() { throw "Cannot update not locked object"; }
	private static var LOCKS = ["","",""];
	private static var KEYWORDS = {
		var h = new Hash();
		for( k in ["read","write","desc","out","group","version","option",
				"primary","exists","from","key","keys","limit","lock","use",
				"create","order","range"] )
			h.set(k,true);
		h;
	}

	private static function setConnection( c : Connection ) {
		Reflect.setField(Manager,"cnx",c);
		if( c != null ) {
			if( c.dbName() == "MySQL" ) {
				LOCKS[1] = " LOCK IN SHARE MODE";
				LOCKS[2] = " FOR UPDATE";
			} else {
				LOCKS[1] = "";
				LOCKS[2] = "";
			}
		}
		return c;
	}

	/* ---------------------------- BASIC API ----------------------------- */
	var table_name : String;
	var table_fields : List<String>;
	var table_keys : Array<String>;
	var class_proto : { prototype : Dynamic };
	var lock_mode : Int;

	public function new( classval : Class<T> ) {
		var cl : Dynamic = classval;

		// get basic infos
		var cname : Array<String> = cl.__name__;
		table_name = quoteField(if( cl.TABLE_NAME != null ) cl.TABLE_NAME else cname[cname.length-1]);
		table_keys = if( cl.TABLE_IDS != null ) cl.TABLE_IDS else ["id"];
		class_proto = cl;
		lock_mode = 2;

		// get the list of private fields
		var apriv : Array<String> = cl.PRIVATE_FIELDS;
		apriv = if( apriv == null ) new Array() else apriv.copy();
		apriv.push("local_manager");
		apriv.push("__class__");

		// get the proto fields not marked private (excluding methods)
		table_fields = new List();
		var proto : { local_manager : neko.db.Manager<T> } = class_proto.prototype;
		for( f in Reflect.fields(proto) ) {
			var isfield = !Reflect.isFunction(Reflect.field(proto,f));
			if( isfield )
				for( f2 in apriv )
					if( f == f2 ) {
						isfield = false;
						break;
					}
			if( isfield )
				table_fields.add(f);
		}

		// set the manager and ready for further init
		proto.local_manager = this;
		init_list.add(cast this);
	}

	public function get( id : Int, ?lock : Bool ) : T {
		if( lock == null )
			lock = true;
		if( table_keys.length != 1 )
			throw "Invalid number of keys";
		if( id == null )
			return null;
		var x : Dynamic = getFromCacheKey(id + table_name);
		if( x != null && (!lock || x.update != no_update) )
			return x;
		var s = new StringBuf();
		s.add("SELECT * FROM ");
		s.add(table_name);
		s.add(" WHERE ");
		s.add(quoteField(table_keys[0]));
		s.add(" = ");
		cnx.addValue(s,id);
		if( lock )
			s.add(getLockMode());
		return object(s.toString(),lock);
	}

	public function getWithKeys( keys : {}, ?lock : Bool ) : T {
		if( lock == null )
			lock = true;
		var x : Dynamic = getFromCacheKey(makeCacheKey(cast keys));
		if( x != null && (!lock || x.update != no_update) )
			return x;
		var s = new StringBuf();
		s.add("SELECT * FROM ");
		s.add(table_name);
		s.add(" WHERE ");
		addKeys(s,keys);
		if( lock )
			s.add(getLockMode());
		return object(s.toString(),lock);
	}

	public function delete( x : {} ) {
		var s = new StringBuf();
		s.add("DELETE FROM ");
		s.add(table_name);
		s.add(" WHERE ");
		addCondition(s,x);
		execute(s.toString());
	}

	public function search( x : {}, ?lock : Bool ) : List<T> {
		if( lock == null )
			lock = true;
		var s = new StringBuf();
		s.add("SELECT * FROM ");
		s.add(table_name);
		s.add(" WHERE ");
		addCondition(s,x);
		if( lock )
			s.add(getLockMode());
		return objects(s.toString(),lock);
	}

	function addCondition(s : StringBuf,x) {
		var first = true;
		if( x != null )
			for( f in Reflect.fields(x) ) {
				if( first )
					first = false;
				else
					s.add(" AND ");
				s.add(quoteField(f));
				var d = Reflect.field(x,f);
				if( d == null )
					s.add(" IS NULL");
				else {
					s.add(" = ");
					cnx.addValue(s,d);
				}
			}
		if( first )
			s.add("1");
	}

	public function all( ?lock: Bool ) : List<T> {
		if( lock == null )
			lock = true;
		return objects("SELECT * FROM " + table_name + if( lock ) getLockMode() else "",lock);
	}

	public function count( ?x : {} ) : Int {
		var s = new StringBuf();
		s.add("SELECT COUNT(*) FROM ");
		s.add(table_name);
		s.add(" WHERE ");
		addCondition(s,x);
		return execute(s.toString()).getIntResult(0);
	}

	public function quote( s : String ) : String {
		return cnx.quote( s );
	}

	public function result( sql : String ) : Dynamic {
		return cnx.request(sql).next();
	}

	public function results<T>( sql : String ) : List<T> {
		return cast cnx.request(sql).results();
	}

	/* -------------------------- SPODOBJECT API -------------------------- */

	function doInsert( x : T ) {
		unmake(x);
		var s = new StringBuf();
		var fields = new List();
		var values = new List();
		for( f in table_fields ) {
			var v = Reflect.field(x,f);
			if( v != null ) {
				fields.add(quoteField(f));
				values.add(v);
			}
		}
		s.add("INSERT INTO ");
		s.add(table_name);
		s.add(" (");
		s.add(fields.join(","));
		s.add(") VALUES (");
		var first = true;
		for( v in values ) {
			if( first )
				first = false;
			else
				s.add(", ");
			cnx.addValue(s,v);
		}
		s.add(")");
		execute(s.toString());
		// table with one key not defined : suppose autoincrement
		if( table_keys.length == 1 && Reflect.field(x,table_keys[0]) == null )
			Reflect.setField(x,table_keys[0],cnx.lastInsertId());
		addToCache(x);
	}

	function doUpdate( x : T ) {
		unmake(x);
		var s = new StringBuf();
		s.add("UPDATE ");
		s.add(table_name);
		s.add(" SET ");
		var cache = Reflect.field(x,cache_field);
		var mod = false;
		for( f in table_fields ) {
			var v = Reflect.field(x,f);
			var vc = Reflect.field(cache,f);
			if( v != vc ) {
				if( mod )
					s.add(", ");
				else
					mod = true;
				s.add(quoteField(f));
				s.add(" = ");
				cnx.addValue(s,v);
				Reflect.setField(cache,f,v);
			}
		}
		if( !mod )
			return;
		s.add(" WHERE ");
		addKeys(s,x);
		execute(s.toString());
	}

	function doDelete( x : T ) {
		var s = new StringBuf();
		s.add("DELETE FROM ");
		s.add(table_name);
		s.add(" WHERE ");
		addKeys(s,x);
		execute(s.toString());
		removeFromCache(x);
	}


	function doSync( i : T ) {
		object_cache.remove(makeCacheKey(i));
		var i2 = getWithKeys(i,(cast i).update != no_update);
		// delete all fields
		for( f in Reflect.fields(i) )
			Reflect.deleteField(i,f);
		// copy fields from new object
		for( f in Reflect.fields(i2) )
			Reflect.setField(i,f,Reflect.field(i2,f));
		// set same field-cache
		Reflect.setField(i,cache_field,Reflect.field(i2,cache_field));
		// rebuild in case it's needed
		make(i);
		addToCache(i);
	}

	function objectToString( it : T ) : String {
		var s = new StringBuf();
		s.add(table_name);
		if( table_keys.length == 1 ) {
			s.add("#");
			s.add(Reflect.field(it,table_keys[0]));
		} else {
			s.add("(");
			var first = true;
			for( f in table_keys ) {
				if( first )
					first = false;
				else
					s.add(",");
				s.add(quoteField(f));
				s.add(":");
				s.add(Reflect.field(it,f));
			}
			s.add(")");
		}
		return s.toString();
	}

	/* ---------------------------- INTERNAL API -------------------------- */

	function cacheObject( x : T, lock : Bool ) {
		addToCache(x);
		untyped __dollar__objsetproto(x,class_proto.prototype);
		Reflect.setField(x,cache_field,untyped __dollar__new(x));
		if( !lock )
			x.update = no_update;
	}

	function make( x : T ) {
	}

	function unmake( x : T ) {
	}

	function quoteField(f : String) {
		return KEYWORDS.exists(f.toLowerCase()) ? "`"+f+"`" : f;
	}

	function addKeys( s : StringBuf, x : {} ) {
		var first = true;
		for( k in table_keys ) {
			if( first )
				first = false;
			else
				s.add(" AND ");
			s.add(quoteField(k));
			s.add(" = ");
			var f = Reflect.field(x,k);
			if( f == null )
				throw ("Missing key "+k);
			cnx.addValue(s,f);
		}
	}

	function execute( sql : String ) {
		return cnx.request(sql);
	}

	function select( cond : String ) {
		var s = new StringBuf();
		s.add("SELECT * FROM ");
		s.add(table_name);
		s.add(" WHERE ");
		s.add(cond);
		s.add(getLockMode());
		return s.toString();
	}

	function selectReadOnly( cond : String ) {
		var s = new StringBuf();
		s.add("SELECT * FROM ");
		s.add(table_name);
		s.add(" WHERE ");
		s.add(cond);
		return s.toString();
	}

	public function object( sql : String, lock : Bool ) : T {
		var r = cnx.request(sql).next();
		if( r == null )
			return null;
		var c = getFromCache(r,lock);
		if( c != null )
			return c;
		cacheObject(r,lock);
		make(r);
		return r;
	}

	public function objects( sql : String, lock : Bool ) : List<T> {
		var me = this;
		var l = cnx.request(sql).results();
		var l2 = new List<T>();
		for( x in l ) {
			var c = getFromCache(x,lock);
			if( c != null )
				l2.add(c);
			else {
				cacheObject(x,lock);
				make(x);
				l2.add(x);
			}
		}
		return l2;
	}

	/* --------------------------- MISC API  ------------------------------ */

	inline function getLockMode() {
		return LOCKS[lock_mode];
	}

	public function setLockMode( exclusive, readShared ) {
		lock_mode = exclusive ? 2 : (readShared ? 1 : 0);
	}

	public function dbClass() : Class<Dynamic> {
		return cast class_proto;
	}

	/* --------------------------- INIT / CLEANUP ------------------------- */

	public static function initialize() {
		var l = init_list;
		init_list = new List();
		for( m in l ) {
			var rl : Void -> Array<Dynamic> = (cast m.class_proto).RELATIONS;
			if( rl != null )
				for( r in rl() )
					m.initRelation(r);
		}
	}

	public static function cleanup() {
		object_cache = new Hash();
	}

	function initRelation(r : { prop : String, key : String, manager : Manager<Object>, lock : Bool } ) {
		// setup getter/setter
		var manager = r.manager;
		var hprop = "__"+r.prop;
		var hkey = r.key;
		var lock = r.lock;
		if( lock == null ) lock = true;
		if( manager == null || manager.table_keys == null ) throw ("Invalid manager for relation "+table_name+":"+r.prop);
		if( manager.table_keys.length != 1 ) throw ("Relation "+r.prop+"("+r.key+") on a multiple key table");
		Reflect.setField(class_proto.prototype,"get_"+r.prop,function() {
			var othis = untyped this;
			var f = Reflect.field(othis,hprop);
			if( f != null )
				return f;
			var id = Reflect.field(othis,hkey);
			f = manager.get(id,lock);
			// it's highly possible that in that case the object has been inserted
			// after we started our transaction : in that case, let's lock it, since
			// it's still better than returning 'null' while it exists
			if( f == null && id != null && !lock )
				f = manager.get(id,true);
			Reflect.setField(othis,hprop,f);
			return f;
		});
		Reflect.setField(class_proto.prototype,"set_"+r.prop,function(f) {
			var othis = untyped this;
			Reflect.setField(othis,hprop,f);
			Reflect.setField(othis,hkey,Reflect.field(f,manager.table_keys[0]));
			return f;
		});
		// remove prop from precomputed table_fields
		// always add key to table fields (even if not declared)
		table_fields.remove(r.prop);
		table_fields.remove(r.key);
		table_fields.add(r.key);
	}

	/* ---------------------------- OBJECT CACHE -------------------------- */

	function makeCacheKey( x : T ) : String {
		if( table_keys.length == 1 ) {
			var k = Reflect.field(x,table_keys[0]);
			if( k == null )
				throw("Missing key "+table_keys[0]);
			return Std.string(k)+table_name;
		}
		var s = new StringBuf();
		for( k in table_keys ) {
			var v = Reflect.field(x,k);
			if( k == null )
				throw("Missing key "+k);
			s.add(v);
			s.add("#");
		}
		s.add(table_name);
		return s.toString();
	}

	function addToCache( x : T ) {
		object_cache.set(makeCacheKey(x),x);
	}

	function removeFromCache( x : T ) {
		object_cache.remove(makeCacheKey(x));
	}

	function getFromCacheKey( key : String ) : T {
		return cast object_cache.get(key);
	}

	function getFromCache( x : T, lock : Bool ) : T {
		var c : Dynamic = object_cache.get(makeCacheKey(x));
		if( c != null && lock && c.update == no_update ) {
			// restore update method since now the object is locked
			c.update = class_proto.prototype.update;
			// and synchronize the fields since our result is up-to-date !
			for( f in Reflect.fields(c) )
				Reflect.deleteField(c,f);
			for( f in Reflect.fields(x) )
				Reflect.setField(c,f,Reflect.field(x,f));
			// use the new object as our cache of fields
			Reflect.setField(c,cache_field,x);
			// remake object
			make(c);
		}
		return c;
	}

}
