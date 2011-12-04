$(document).ready(function() {
  $("input.large").wrap("<div class='clearfix' />")
                  .wrap("<div class='input' />")
                  .before(function(index) { return "<label>" + this.name + "</label>" });
});
