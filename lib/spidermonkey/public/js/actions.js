function actionRun(href) {
  $.post(href + "/start", function(data) {
    // TODO: Callback...maybe update the job index?
  });
}

function actionEdit(href) {
  e = {action: "openedit", url: href};
  if (typeof animateManager === "function") {
    animateManager(e);
  } else {
    parent.postMessage(e, location.protocol + "//" + location.host);
  }
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
        // TODO: Callback...refresh the listing
      }
    });
  }
}

function actionCancel(href) { return actionDelete(href); }
