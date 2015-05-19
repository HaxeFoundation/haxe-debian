/*
 * Copyright (C)2005-2012 Haxe Foundation
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */
import cs.NativeArray;

/**
	An Array is a storage for values. You can access it using indexes or
	with its API. On the server side, it's often better to use a [List] which
	is less memory and CPU consuming, unless you really need indexed access.
**/
@:classCode('
	public Array(T[] native)
	{
		this.__a = native;
		this.length = native.Length;
	}
')
@:final @:coreApi class Array<T> implements ArrayAccess<T> {

	/**
		The length of the Array
	**/
	public var length(default,null) : Int;

	private var __a:NativeArray<T>;

	@:functionCode('
			return new Array<X>(native);
	')
	private static function ofNative<X>(native:NativeArray<X>):Array<X>
	{
		return null;
	}

	@:functionCode('
			return new Array<Y>(new Y[size]);
	')
	private static function alloc<Y>(size:Int):Array<Y>
	{
		return null;
	}

	/**
		Creates a new Array.
	**/
	public function new() : Void
	{
		this.length = 0;
		this.__a = new NativeArray(0);
	}

	/**
		Returns a new Array by appending [a] to [this].
	**/
	public function concat( a : Array<T> ) : Array<T>
	{
		var len = length + a.length;
		var retarr = new NativeArray(len);
		cs.system.Array.Copy(__a, 0, retarr, 0, length);
		cs.system.Array.Copy(a.__a, 0, retarr, length, a.length);

		return ofNative(retarr);
	}

	private function concatNative( a : NativeArray<T> ) : Void
	{
		var __a = __a;
		var len = length + a.Length;
		if (__a.Length >= len)
		{
			cs.system.Array.Copy(a, 0, __a, length, length);
		} else {
			var newarr = new NativeArray(len);
			cs.system.Array.Copy(__a, 0, newarr, 0, length);
			cs.system.Array.Copy(a, 0, newarr, length, a.Length);

			this.__a = newarr;
		}

		this.length = len;
	}

	/**
		Returns a representation of an array with [sep] for separating each element.
	**/
	public function join( sep : String ) : String
	{
		var buf = new StringBuf();
		var i = -1;

		var first = true;
		var length = length;
		while (++i < length)
		{
			if (first)
				first = false;
			else
				buf.add(sep);
			buf.add(__a[i]);
		}

		return buf.toString();
	}

	/**
		Removes the last element of the array and returns it.
	**/
	public function pop() : Null<T>
	{
		var __a = __a;
		var length = length;
		if (length > 0)
		{
			var val = __a[--length];
			__a[length] = null;
			this.length = length;

			return val;
		} else {
			return null;
		}
	}

	/**
		Adds the element [x] at the end of the array.
	**/
	public function push(x : T) : Int
	{
		if (length >= __a.Length)
		{
			var newLen = (length << 1) + 1;
			var newarr = new NativeArray(newLen);
			__a.CopyTo(newarr, 0);

			this.__a = newarr;
		}

		__a[length] = x;
		return ++length;
	}

	/**
		Reverse the order of elements of the Array.
	**/
	public function reverse() : Void
	{
		var i = 0;
		var l = this.length;
		var a = this.__a;
		var half = l >> 1;
		l -= 1;
		while ( i < half )
		{
			var tmp = a[i];
			a[i] = a[l-i];
			a[l-i] = tmp;
			i += 1;
		}
	}

	/**
		Removes the first element and returns it.
	**/
	public function shift() : Null<T>
	{
		var l = this.length;
		if( l == 0 )
			return null;

		var a = this.__a;
		var x = a[0];
		l -= 1;
		cs.system.Array.Copy(a, 1, a, 0, length-1);
		a[l] = null;
		this.length = l;

		return x;
	}

	/**
		Copies the range of the array starting at [pos] up to,
		but not including, [end]. Both [pos] and [end] can be
		negative to count from the end: -1 is the last item in
		the array.
	**/
	public function slice( pos : Int, ?end : Int ) : Array<T>
	{
		if( pos < 0 ){
			pos = this.length + pos;
			if( pos < 0 )
				pos = 0;
		}
		if( end == null )
			end = this.length;
		else if( end < 0 )
			end = this.length + end;
		if( end > this.length )
			end = this.length;
		var len = end - pos;
		if ( len < 0 ) return new Array();

		var newarr = new NativeArray(len);
		cs.system.Array.Copy(__a, pos, newarr, 0, len);

		return ofNative(newarr);
	}

	/**
		Sort the Array according to the comparison public function [f].
		[f(x,y)] should return [0] if [x == y], [>0] if [x > y]
		and [<0] if [x < y].
	**/
	public function sort( f : T -> T -> Int ) : Void
	{
		if (length == 0)
			return;
		quicksort(0, length - 1, f);
	}

	/**
		quicksort author: tong disktree
		http://blog.disktree.net/2008/10/26/array-sort-performance.html
	 */
	private function quicksort( lo : Int, hi : Int, f : T -> T -> Int ) : Void
	{
        var buf = __a;
		var i = lo, j = hi;
        var p = buf[(i + j) >> 1];
		while ( i <= j )
		{
			while ( f(buf[i], p) < 0 ) i++;
            while ( f(buf[j], p) > 0 ) j--;
			if ( i <= j )
			{
                var t = buf[i];
                buf[i++] = buf[j];
                buf[j--] = t;
            }
		}

		if( lo < j ) quicksort( lo, j, f );
        if( i < hi ) quicksort( i, hi, f );
	}

	/**
		Removes [len] elements starting from [pos] an returns them.
	**/
	public function splice( pos : Int, len : Int ) : Array<T>
	{
		if( len < 0 ) return new Array();
		if( pos < 0 ) {
			pos = this.length + pos;
			if( pos < 0 ) pos = 0;
		}
		if( pos > this.length ) {
			pos = 0;
			len = 0;
		} else if( pos + len > this.length ) {
			len = this.length - pos;
			if( len < 0 ) len = 0;
		}
		var a = this.__a;

		var ret = new NativeArray(len);
		cs.system.Array.Copy(a, pos, ret, 0, len);
		var ret = ofNative(ret);

		var end = pos + len;
		cs.system.Array.Copy(a, end, a, pos, this.length - end);
		this.length -= len;
		while( --len >= 0 )
			a[this.length + len] = null;
		return ret;
	}

	private function spliceVoid( pos : Int, len : Int ) : Void
	{
		if( len < 0 ) return;
		if( pos < 0 ) {
			pos = this.length + pos;
			if( pos < 0 ) pos = 0;
		}
		if( pos > this.length ) {
			pos = 0;
			len = 0;
		} else if( pos + len > this.length ) {
			len = this.length - pos;
			if( len < 0 ) len = 0;
		}
		var a = this.__a;

		var end = pos + len;
		cs.system.Array.Copy(a, end, a, pos, this.length - end);
		this.length -= len;
		while( --len >= 0 )
			a[this.length + len] = null;
	}

	/**
		Returns a displayable representation of the Array content.
	**/
	public function toString() : String
	{
		var ret = new StringBuf();
		var a = __a;
		ret.add("[");
		var first = true;
		for (i in 0...length)
		{
			if (first)
				first = false;
			else
				ret.add(",");
			ret.add(a[i]);
		}

		ret.add("]");
		return ret.toString();
	}

	/**
		Adds the element [x] at the start of the array.
	**/
	public function unshift( x : T ) : Void
	{
		var __a = __a;
		var length = length;
		if (length >= __a.Length)
		{
			var newLen = (length << 1) + 1;
			var newarr = new NativeArray(newLen);
			cs.system.Array.Copy(__a, 0, newarr, 1, length);

			this.__a = newarr;
		} else {
			cs.system.Array.Copy(__a, 0, __a, 1, length);
		}

		this.__a[0] = x;
		++this.length;
	}

	/**
		Inserts the element [x] at the position [pos].
		All elements after [pos] are moved one index ahead.
	**/
	public function insert( pos : Int, x : T ) : Void
	{
		var l = this.length;
		if( pos < 0 ) {
			pos = l + pos;
			if( pos < 0 ) pos = 0;
		}
		if ( pos >= l ) {
			this.push(x);
			return;
		} else if (pos == 0) {
			this.unshift(x);
			return;
		}

		if (l >= __a.Length)
		{
			var newLen = (length << 1) + 1;
			var newarr = new NativeArray(newLen);
			cs.system.Array.Copy(__a, 0, newarr, 0, pos);
			newarr[pos] = x;
			cs.system.Array.Copy(__a, pos, newarr, pos + 1, l - pos);

			this.__a = newarr;
			++this.length;
		} else {
			var __a = __a;
			cs.system.Array.Copy(__a, pos, __a, pos + 1, l - pos);
			cs.system.Array.Copy(__a, 0, __a, 0, pos);
			__a[pos] = x;
			++this.length;
		}
	}

	/**
		Removes the first occurence of [x].
		Returns false if [x] was not present.
		Elements are compared by using standard equality.
	**/
	public function remove( x : T ) : Bool
	{
		var __a = __a;
		var i = -1;
		var length = length;
		while (++i < length)
		{
			if (__a[i] == x)
			{
				cs.system.Array.Copy(__a, i + 1, __a, i, length - i - 1);
				__a[--this.length] = null;

				return true;
			}
		}

		return false;
	}

	public function map<S>( f : T -> S ) : Array<S> {
		var ret = [];
		for (elt in this)
			ret.push(f(elt));
		return ret;
	}

	public function filter( f : T -> Bool ) : Array<T> {
		var ret = [];
		for (elt in this)
			if (f(elt))
				ret.push(elt);
		return ret;
	}

	/**
		Returns a copy of the Array. The values are not
		copied, only the Array structure.
	**/
	public function copy() : Array<T>
	{
		var len = length;
		var __a = __a;
		var newarr = new NativeArray(len);
		cs.system.Array.Copy(__a, 0, newarr, 0, len);
		return ofNative(newarr);
	}

	/**
		Returns an iterator of the Array values.
	**/
	public function iterator() : Iterator<T>
	{
		var i = 0;
		var len = length;
		return
		{
			hasNext:function() return i < len,
			next:function() return __a[i++]
		};
	}

	private function __get(idx:Int):T
	{
		var __a = __a;
		var idx:UInt = idx;
		if (idx >= length)
			return null;

		return __a[idx];
	}

	private function __set(idx:Int, v:T):T
	{
		var idx:UInt = idx;
		var __a = __a;
		if (idx >= __a.Length)
		{
			var len = idx + 1;
			if (idx == __a.Length)
				len = (idx << 1) + 1;
			var newArr = new NativeArray<T>(len);
			__a.CopyTo(newArr, 0);
			this.__a = __a = newArr;
		}

		if (idx >= length)
			this.length = idx + 1;

		return __a[idx] = v;
	}

	private inline function __unsafe_get(idx:Int):T
	{
		return __a[idx];
	}

	private inline function __unsafe_set(idx:Int, val:T):T
	{
		return __a[idx] = val;
	}
}
