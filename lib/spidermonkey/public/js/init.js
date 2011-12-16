$(document).ready(function() {
  $(".init").removeClass("init")
            .addClass(function() { return (this.tagName == "input" ? "ui-widget-content ui-corner-all" : ""); })
            .wrap("<div class='clearfix' />")
            .wrap("<div class='input' />")
            .attr("name", function(index,old) { return this.id; })
            .before(function(index) { return "<label>" + $(this).data("label") + "</label>"; });
});
