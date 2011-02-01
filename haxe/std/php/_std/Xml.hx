import php.Lib;
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

enum XmlType {
}

@:core_api class Xml {

	public static var Element(default,null) : XmlType;
	public static var PCData(default,null) : XmlType;
	public static var CData(default,null) : XmlType;
	public static var Comment(default,null) : XmlType;
	public static var DocType(default,null) : XmlType;
	public static var Prolog(default,null) : XmlType;
	public static var Document(default,null) : XmlType;

	public var nodeType(default,null) : XmlType;
	public var nodeName(getNodeName,setNodeName) : String;
	public var nodeValue(getNodeValue,setNodeValue) : String;
	public var parent(getParent,null) : Xml;

	var _nodeName : String;
	var _nodeValue : String;
	var _attributes : Hash<String>;
	var _children : Array<Xml>;
	var _parent : Xml;

	private static var build : Xml;
	private static function __start_element_handler(parser : Dynamic, name : String, attribs : ArrayAccess<String>) : Void {
		var node = createElement(name);
		untyped __php__("while(list($k, $v) = each($attribs)) $node->set($k, $v)");
		build.addChild(node);
		build = node;
	}

	private static function __end_element_handler(parser : Dynamic, name : String) : Void {
		build = build.getParent();
	}

	private static function __character_data_handler(parser : Dynamic, data : String) : Void {
		if((untyped __call__("strlen", data) == 1 && __call__("htmlentities", data) != data) || untyped __call__("htmlentities", data) == data) {
			build.addChild(createPCData(untyped __call__("htmlentities", data)));
		} else
			build.addChild(createCData(data));
	}

	private static function __default_handler(parser : Dynamic, data : String) : Void {
		if ("<!--" == data.substr(0, 4))
			build.addChild(createComment(data.substr(4, data.length-7)));
		else
			build.addChild(createPCData(data));
	}

	static var reHeader = ~/\s*(?:<\?(.+?)\?>)?(?:<!DOCTYPE ([^>]+)>)?/mi;

	public static function parse( str : String ) : Xml {
		build = createDocument();
		var xml_parser = untyped __call__("xml_parser_create");
		untyped __call__("xml_set_element_handler", xml_parser, __start_element_handler, __end_element_handler);
		untyped __call__("xml_set_character_data_handler", xml_parser, __character_data_handler);
		untyped __call__("xml_set_default_handler", xml_parser, __default_handler);
		untyped __call__("xml_parser_set_option", xml_parser, __php__("XML_OPTION_CASE_FOLDING"), 0);
		untyped __call__("xml_parser_set_option", xml_parser, __php__("XML_OPTION_SKIP_WHITE"), 0);

		reHeader.match(str);
		
		str = "<doc>"+reHeader.matchedRight()+"</doc>";

		if(1 != untyped __call__("xml_parse", xml_parser, str, true)) {
			throw "Xml parse error ("+untyped __call__("xml_error_string", __call__("xml_get_error_code", xml_parser)) + ") line #" + __call__("xml_get_current_line_number", xml_parser);
		}

		untyped __call__("xml_parser_free", xml_parser);

		build = build._children[0];
		build._parent = null;
		build._nodeName = null;
		build.nodeType = Document;
		
		var doctype = reHeader.matched(2);
		if (null != doctype)
			build.insertChild(createDocType(doctype), 0);
			
		var prolog = reHeader.matched(1);
		if (null != prolog)
			build.insertChild(createProlog(prolog), 0);

		return build;
	}

	private function new() : Void;

	public static function createElement( name : String ) : Xml {
		var r = new Xml();
		r.nodeType = Xml.Element;
		r._children = new Array();
		r._attributes = new Hash();
		r.setNodeName( name );
		return r;
	}

	public static function createPCData( data : String ) : Xml {
		var r = new Xml();
		r.nodeType = Xml.PCData;
		r.setNodeValue( data );
		return r;
	}

	public static function createCData( data : String ) : Xml {
		var r = new Xml();
		r.nodeType = Xml.CData;
		r.setNodeValue( data );
		return r;
	}

	public static function createComment( data : String ) : Xml {
		var r = new Xml();
		r.nodeType = Xml.Comment;
		r.setNodeValue( data );
		return r;
	}

	public static function createDocType( data : String ) : Xml {
		var r = new Xml();
		r.nodeType = Xml.DocType;
		r.setNodeValue( data );
		return r;
	}

	public static function createProlog( data : String ) : Xml {
		var r = new Xml();
		r.nodeType = Xml.Prolog;
		r.setNodeValue( data );
		return r;
	}

	public static function createDocument() : Xml {
		var r = new Xml();
		r.nodeType = Xml.Document;
		r._children = new Array();
		return r;
	}

	private function getNodeName() : String {
		if( nodeType != Xml.Element )
			throw "bad nodeType";
		return _nodeName;
	}

	private function setNodeName( n : String ) : String {
		if( nodeType != Xml.Element )
			throw "bad nodeType";
		return _nodeName = n;
	}

	private function getNodeValue() : String {
		if( nodeType == Xml.Element || nodeType == Xml.Document )
			throw "bad nodeType";
		return _nodeValue;
	}

	private function setNodeValue( v : String ) : String {
		if( nodeType == Xml.Element || nodeType == Xml.Document )
			throw "bad nodeType";
		return _nodeValue = v;
	}

	private function getParent() : Xml {
		return _parent;
	}

	public function get( att : String ) : String {
		if( nodeType != Xml.Element )
			throw "bad nodeType";
		return _attributes.get( att );
	}

	public function set( att : String, value : String ) : Void {
		if( nodeType != Xml.Element )
			throw "bad nodeType";
		_attributes.set( att, untyped __call__("htmlspecialchars", value, __php__('ENT_COMPAT'), 'UTF-8'));
	}

	public function remove( att : String ) : Void{
		if( nodeType != Xml.Element )
			throw "bad nodeType";
		_attributes.remove( att );
	}

	public function exists( att : String ) : Bool {
		if( nodeType != Xml.Element )
			throw "bad nodeType";
		return _attributes.exists( att );
	}

	public function attributes() : Iterator<String> {
		if( nodeType != Xml.Element )
			throw "bad nodeType";
		return _attributes.keys();
	}

	public function iterator() : Iterator<Xml> {
		if( _children == null ) throw "bad nodetype";
		var me = this;
		var it = null;
		it = untyped {
			cur: 0,
			x: me._children,
			hasNext : function(){
				return it.cur < it.x.length;
			},
			next : function(){
				return it.x[it.cur++];
			}
		}
		return cast it;
	}

	public function elements() : Iterator<Xml> {
		if( _children == null ) throw "bad nodetype";
		var me = this;
		var it = null;
		it =  untyped {
			cur: 0,
			x: me._children,
			hasNext : function() {
				var k = it.cur;
				var l = it.x.length;
				while( k < l ) {

					if( it.x[k].nodeType == Xml.Element )
						__php__("break");
					k += 1;
				}
				it.cur = k;
				return k < l;
			},
			next : function() {
				var k = it.cur;
				var l = it.x.length;
				while( k < l ) {
					var n = it.x[k];
					k += 1;
					if( n.nodeType == Xml.Element ) {
						it.cur = k;
						return n;
					}
				}
				return null;
			}
		}
		return cast it;
	}

	public function elementsNamed( name : String ) : Iterator<Xml> {
		if( _children == null ) throw "bad nodetype";

		var me = this;
		var it = null;
		it =  untyped {
			cur: 0,
			x: me._children,
			hasNext : function() {
				var k = it.cur;
				var l = it.x.length;
				while( k < l ) {
					var n = it.x[k];
					if( n.nodeType == Xml.Element && n._nodeName == name )
						__php__("break");
					k++;
				}
				it.cur = k;
				return k < l;
			},
			next : function() {
				var k = it.cur;
				var l = it.x.length;
				while( k < l ) {
					var n = it.x[k];
					k++;
					if( n.nodeType == Xml.Element && n._nodeName == name ) {
						it.cur = k;
						return n;
					}
				}
				return null;
			}
		}
		return cast it;
	}

	public function firstChild() : Xml {
		if( _children == null ) throw "bad nodetype";
		if( _children.length == 0 ) return null;
		return _children[0];
	}

	public function firstElement() : Xml {
		if( _children == null ) throw "bad nodetype";
		var cur = 0;
		var l = _children.length;
		while( cur < l ) {
			var n = _children[cur];
			if( n.nodeType == Xml.Element )
				return n;
			cur++;
		}
		return null;
	}

	public function addChild( x : Xml ) : Void {
		if( _children == null ) throw "bad nodetype";
		if( x._parent != null ) x._parent._children.remove(x);
		x._parent = this;
		_children.push( x );
	}

	public function removeChild( x : Xml ) : Bool {
		if( _children == null ) throw "bad nodetype";
		var b = _children.remove( x );
		if( b )
			x._parent = null;
		return b;
	}

	public function insertChild( x : Xml, pos : Int ) : Void {
		if( _children == null ) throw "bad nodetype";
		if( x._parent != null ) x._parent._children.remove(x);
		x._parent = this;
		_children.insert( pos, x );
	}

	public function toString() : String {
		if( nodeType == Xml.PCData )
			return _nodeValue;

		var s = "";

		if( nodeType == Xml.Element ) {
			s += "<";
			s += _nodeName;
			for( k in _attributes.keys() ){
				s += " ";
				s += k;
				s += "=\""; // \"
				s += _attributes.get(k);
				s += "\""; // \"
			}
			if( _children.length == 0 ) {
				s += "/>";
				return s;
			}
			s += ">";
		} else if( nodeType == Xml.CData )
			return "<![CDATA["+_nodeValue+"]]>";
		else if( nodeType == Xml.Comment )
			return "<!--"+_nodeValue+"-->";
		else if( nodeType == Xml.DocType )
			return "<!DOCTYPE "+_nodeValue+">";
		else if ( nodeType == Xml.Prolog )
			return "<?"+_nodeValue+"?>";
		

		for( x in iterator() )
			s += x.toString();

		if( nodeType == Xml.Element ) {
			s += "</";
			s += _nodeName;
			s += ">";
		}
		return s;
	}

	static function __init__() : Void untyped {
		Xml.Element = "element";
		Xml.PCData = "pcdata";
		Xml.CData = "cdata";
		Xml.Comment = "comment";
		Xml.DocType = "doctype";
		Xml.Prolog = "prolog";
		Xml.Document = "document";
	}

}
