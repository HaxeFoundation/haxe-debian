package flash.display;

extern class LoaderInfo extends flash.events.EventDispatcher {
	var actionScriptVersion(default,null) : ActionScriptVersion;
	var applicationDomain(default,null) : flash.system.ApplicationDomain;
	/** new in FP 9.0.115 **/
	var bytes(default,null) : flash.utils.ByteArray;
	var bytesLoaded(default,null) : UInt;
	var bytesTotal(default,null) : UInt;
	var childAllowsParent(default,null) : Bool;
	var content(default,null) : DisplayObject;
	var contentType(default,null) : String;
	var frameRate(default,null) : Float;
	var height(default,null) : Int;
	var loader(default,null) : Loader;
	var loaderURL(default,null) : String;
	var parameters(default,null) : Dynamic<String>;
	var parentAllowsChild(default,null) : Bool;
	var sameDomain(default,null) : Bool;
	var sharedEvents(default,null) : flash.events.EventDispatcher;
	var swfVersion(default,null) : SWFVersion;
	var url(default,null) : String;
	var width(default,null) : Int;
	/** new in FP 9.0.115 **/
	static function getLoaderInfoByDefinition(object : Dynamic) : flash.display.LoaderInfo;
}
