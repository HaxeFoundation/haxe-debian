package flash.filters;

extern class GradientGlowFilter extends BitmapFilter {
	var alphas : Array<Dynamic>;
	var angle : Float;
	var blurX : Float;
	var blurY : Float;
	var colors : Array<Dynamic>;
	var distance : Float;
	var knockout : Bool;
	var quality : Int;
	var ratios : Array<Dynamic>;
	var strength : Float;
	var type : BitmapFilterType;
	function new(?distance : Float, ?angle : Float, ?colors : Array<Dynamic>, ?alphas : Array<Dynamic>, ?ratios : Array<Dynamic>, ?blurX : Float, ?blurY : Float, ?strength : Float, ?quality : Int, ?type : BitmapFilterType, ?knockout : Bool) : Void;
}
