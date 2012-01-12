/*
var d1 = [ [0,10], [1,20], [2,80], [3,70], [4,60] ];
var d2 = [ [0,30], [1,25], [2,50], [3,60], [4,95] ];
var d3 = [ [0,50], [1,40], [2,60], [3,95], [4,30] ];

var autocomplete_values = [];
var graph_data = [];

var options = {
  series: {
    spider: {
      active: true,
      highlight: {
        mode: "area",
        opacity: 0.5
      },
      legs: {
        data: [{label: "OEE"},
               {label: "MOE"},
               {label: "OER"},
               {label: "OEC"},
               {label: "Quality"}],
        legScaleMax: 1
        legScaleMin: 0.8
      },
      spiderSize: 0.9
    }
  },
  grid: {
    hoverable: true,
    clickable: true,
    tickColor: "rgba(0,0,0,0.2)",
    autoHighlight: true,
    mode: "spider"
  }
};

var data = [{
              label: "Goal",
              color: "rgb(0,0,0)",
              data: d1,
              spider: {
                show: true,
                lineWidth: 12
              }
            },
            {
              label: "Complete",
              color: "rgb(0,255,0)",
              data: d3,
              spider: {
                show: true
              }
            }];
function dataRow(data)
{
  this.data
}
*/

var VirtualMonkey = {
  plotUpdates: [],
  rawData: [],
};

function pollServer()
{
  field_values = {};
  $("#sidebar").find("div.input").find("input").each(function(index) {
    field = $(this);
    if (field.val() !== "") {
      field_values[this.id] = field.val();
    }
  });

  // Get data
  $.getJSON("/api/reports/autocomplete", field_values, function(json) {
    // Always returns full gamut of autocomplete values
    // Update autocomplete
    $("#sidebar").find("div.input").find("input").each(function(index) {
      field = $(this);
      if (this.id.indexOf("date") < 0) {
        field.autocomplete({source: json[this.id]});
      }
    });
  });

  console.log(field_values)
  $.getJSON("/api/reports", field_values, function(json) {
    // Populate Spreadsheet
    var to_insert = $("#raw_table");
    var html = []
    var column_order = []
    var i = json.length;
    while (i--) {
      var obj = {}
      for (field in json[i]) {
        // Add field to column_order if not in there
        if (column_order.indexOf(field) < 0) { column_order.push(field); } // TODO:optimize - later
        obj[field] = "<td>" + json[i][field] + "</td>";
      }
      html.push(obj);
    }

    to_insert.find("thead").html(function() {
      var ret = "";
      for (j=0; j < column_order.length; j++) {
        ret += "<th class='header'>" + column_order[j] + "</th>"
      }
      return ret;
    });

    to_insert.find("tbody").html(function() {
      var ret = "";
      for (i=0; i < html.length; i++) {
        ret += "<tr>"
        for (j=0; j < column_order.length; j++) {
          ret += html[i][column_order[j]];
        }
        ret += "</tr>"
      }
      return ret;
    })();
  });

//  updatePlot(); TODO - later
}
/*
function updatePlot()
{
  // TODO Serialize Data from Spreadsheet
  // Plot data
  p1 = $.plot($("#container"), data, options);
}
*/
function animateManager(data) {
  scrollDistance = $("#pane_0").height() + 15;
  switch (data.action) {
    case "createedit":
      $("#new_task_btn").addClass("disabled").unbind("click");
      var iframe = $("<iframe src='/edit_task/new' sandbox='allow-same-origin allow-forms allow-scripts' />");
      iframe.load(function() {
        $("#manager_strip").animate({top: '-='+scrollDistance}, 250, 'swing');
        iframe.unbind("load");
      });
      $("#pane_1").append(iframe);
      break;
    case "openedit":
      // Takes UID
      $("#new_task_btn").addClass("disabled").unbind("click");
      href = "/edit_task/" + data.uid
      var iframe = $("<iframe src='" + href + "' sandbox='allow-same-origin allow-forms allow-scripts' />");
      iframe.load(function() {
        $("#manager_strip").animate({top: '-='+scrollDistance}, 250, 'swing');
        iframe.unbind("load");
      });
      $("#pane_1").append(iframe);
      break;
    case "closeedit":
      $("#new_task_btn").removeClass("disabled").bind("click", function() {
        animateManager({action: 'createedit'});
      });
      $("#manager_strip").animate({top: '+='+scrollDistance}, 250, 'swing', function() {
        $("#pane_1").html("");
      });
      break;
    case "togglemodal":
      $("#manager_modal").modal('toggle');
      break;
    case "refreshtasks":
      $.ajax({
        type: 'GET',
        url: "/tasks",
        data: {actions: data.actions},
        success: function(newHTML) { $("ul.task_list").html(newHTML); },
        error: ajaxErrorHandler
      });
      break;
    case "deletetask":
      // Takes UID
      $("ul.task_list li[data-uid='" + data.uid + "']").remove();
      break;
    case "addtask":
      // Takes API HREF
      var a = data.href.split("/")
      if (!data.actions) { data.actions = null; }
      $.ajax({
        type: 'GET',
        url: "/tasks/" + a[a.length-1],
        data: {actions: data.actions},
        success: function(newHTML) { $("ul.task_list").append(newHTML); },
        error: ajaxErrorHandler
      });
      break;
    case "refreshjobs":
      $.ajax({
        type: 'GET',
        url: "/jobs",
        success: function(newHTML) { $("ul.job_list").html(newHTML); },
        error: ajaxErrorHandler
      });
      break;
    case "deletejob":
      // Takes UID
      $("ul.job_list li[data-uid='" + data.uid + "']").remove();
      break;
    case "addjob":
      // Takes API HREF
      var a = data.href.split("/")
      $.ajax({
        type: 'GET',
        url: "/jobs/" + a[a.length-1],
        success: function(newHTML) { $("ul.job_list").append(newHTML); },
        error: ajaxErrorHandler
      });
      break;
    default:
      console.error("Invalid action: " + data.action);
  }
}

function messageHandler(event) {
  if (event.origin === (location.protocol + "//" + location.host)) {
    animateManager(event.data);
  } else {
    console.error("Origin Mismatch: " + event.origin);
  }
}

function startAutoUpdate() {
  if (!window.autoupdate) {
    window.autoupdate = true;
    window.interval_id = window.setInterval(function() {
      animateManager({action: "refreshjobs"});
      pollServer();
    }, 30000); // Query Server every 30s
    animateManager({action: "refreshjobs"});
    pollServer();
  }
}

function stopAutoUpdate() {
  if (window.autoupdate) {
    window.autoupdate = false;
    window.clearInterval(window.interval_id);
  }
}

(function($) {
  var dates = $("#from_date, #to_date").datepicker({
    defaultDate: -1, //this.id.indexOf("from") > 0 ? -1 : null,
    maxDate: "+1D",
    dateFormat: "yymmdd",
    changeMonth: false,
    changeYear: false,
    showAnim: "slideDown",
    onSelect: function(selectedDate) {
      option = this.id.indexOf("from") >= 0 ? "minDate" : "maxDate";
      instance = $(this).data("datepicker");
      date = $.datepicker.parseDate(instance.settings.dateFormat || $.datepicker._defaults.dateFormat,
                                    selectedDate,
                                    instance.settings);
      dates.not(this).datepicker("option", option, date);
    }
  });

  $("#autorefresh_toggle").click(function() {
    ($(this).hasClass("active") ? startAutoUpdate() : stopAutoUpdate());
  });

  $(window).load(startAutoUpdate);

  window.addEventListener('message', messageHandler, true);

  // More initializations...
  $("#new_task_btn").removeClass("disabled").bind("click", function() {
    animateManager({action: 'createedit'});
  });

  $("#raw_table").tablesorter();
})(jQuery);
