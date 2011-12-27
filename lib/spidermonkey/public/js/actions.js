function ajaxErrorHandler(jqXHR, textStatus, errorThrown) {
  $("#error_bar").remove();
  $("<div class='alert-message error fade' id='error_bar' style='display:none;' />")
    .alert()
    .append("<p><strong>"+textStatus+"</strong>:"+errorThrown+"</p>")
    .prependTo("body")
    .slideDown(250);
}

function sendMsg(e) {
  if (typeof animateManager === "function") {
    animateManager(e);
  } else {
    parent.postMessage(e, location.protocol + "//" + location.host);
  }
}

function actionRun(href) {
  $.ajax({
    type: 'POST',
    url: href + "/start",
    success: function(data) {
      sendMsg({action: "refreshjobs"});
    },
    error: ajaxErrorHandler
  });
}

function actionEdit(uid) {
  sendMsg({action: "openedit", uid: ""+uid});
}

function actionSave(href) {
  // TODO - later: Save isn't implemented yet
}

function actionDelete(href) {
  if (confirm("Are you sure you want to delete this item?")) {
    $.ajax({
      type: 'DELETE',
      url: href,
      success: function(data) {
        a = href.split("/")
        e = {uid: ""+a[a.length-1]}
        if (href.match(/task/)) {
          e.action = "deletetask";
        } else if (href.match(/job/)) {
          e.action = "deletejob";
        }

        sendMsg(e);
      },
      error: ajaxErrorHandler
    });
  }
}

function actionCancel(href) { return actionDelete(href); }

$(window).load(function() {
  var runHandler = function() { actionRun($(this).data("uri")) };
  var editHandler = function() { actionEdit($(this).data("uid")) };
  var saveHandler = function() { actionSave($(this).data("uri")) };
  var deleteHandler = function() { actionDelete($(this).data("uri")) };
  var elements = "div.resource_list";
  if ((/^1\.[7-9]/).test($.fn.jquery)) {
    $(elements).on("click", "img.action.run", runHandler);
    $(elements).on("click", "img.action.edit", editHandler);
    $(elements).on("click", "img.action.save", saveHandler);
    $(elements).on("click", "img.action.delete", deleteHandler);
    $(elements).on("click", "img.action.cancel", deleteHandler);
  } else {
    $(elements).delegate("img.action.run", "click", runHandler);
    $(elements).delegate("img.action.edit", "click", editHandler);
    $(elements).delegate("img.action.save", "click", saveHandler);
    $(elements).delegate("img.action.delete", "click", deleteHandler);
    $(elements).delegate("img.action.cancel", "click", deleteHandler);
  }
});
