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

function pollServer()
{
  field_values = {};
  $("#sidebar").find("div div input").each(function(index) {
    field = $(this);
    if (field.val() !== "") {
      field_values[this.id] = field.val();
    }
  });

  // Get data
  $.getJSON("/api/get_data", field_values, function(json) {
    // Always returns full gamut of autocomplete values
    autocomplete_values = json.autocomplete_values;
    // Update autocomplete
    $("#sidebar").find("div div input").each(function(index) {
      field = $(this);
      if (this.id.indexOf("date") < 0) {
        field.autocomplete({source: autocomplete_values[this.id]});
      }
    });

    // Populate Spreadsheet
    // TODO
  });

  // Get Queue Info
  $.getJSON("/api/queue", function(json) {
    // TODO do something with Queue info
  });

  updatePlot();
}

function updatePlot()
{
  // TODO Serialize Data from Spreadsheet
  // Plot data
  p1 = $.plot($("#container"), data, options);
}

var interval_id = setInterval(pollServer, 30000);
pollServer();
*/
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

function animateManager(data) {
  scrollDistance = $("#pane_0").height() + 15;
  switch (data.action) {
    case "createedit":
      $("#new_task_btn").addClass("disabled").unbind("click");
      var iframe = $("<iframe src='/tasks/new' sandbox='allow-same-origin allow-forms allow-scripts' />");
      iframe.load(function() {
        $("#manager_strip").animate({top: '-='+scrollDistance}, 250, 'swing');
        iframe.unbind("load");
      });
      $("#pane_1").append(iframe);
      break;
    case "openedit":
      $("#new_task_btn").addClass("disabled").unbind("click");
      var iframe = $("<iframe src='"+data.url+"' sandbox='allow-same-origin allow-forms allow-scripts' />");
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

window.addEventListener('message', messageHandler, true);

// More initializations...
$("#new_task_btn").removeClass("disabled").bind("click", function() {
  animateManager({action: 'createedit'});
});
