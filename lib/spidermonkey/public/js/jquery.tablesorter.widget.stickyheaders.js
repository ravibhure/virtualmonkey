// Sticky header widget
// based on this awesome article:
// http://css-tricks.com/13465-persistent-headers/
// **************************
$.tablesorter.addWidget({
  id: "stickyHeaders",
  format: function(table) {
    if ($(table).hasClass('hasStickyHeaders')) { return; }
    var $table = $(table).addClass('hasStickyHeaders'),
      win = $(window),
      header = $(table).find('thead'),
      hdrCells = header.find('tr').children(),
      firstCell = hdrCells.eq(0),
      brdr = parseInt(hdrCells.eq(0).css('border-left-width'),10),
      sticky = header.find('tr:not(.filters)').clone()
        .addClass('stickyHeader')
        .css({
          width      : header.outerWidth() + brdr * 2,
          position   : 'fixed',
          left       : firstCell.offset().left,
          marginLeft : -brdr,
          top        : 0,
          visibility : 'hidden',
          zIndex     : 10
        }),
      stkyCells = sticky.children(),
      laststate;
    // update sticky header class names to match real header
    $table.bind('sortEnd', function(e,t){
      var th = $(t).find('thead tr'),
        sh = th.filter('.stickyHeader').children();
      th.filter(':not(.stickyHeader)').children().each(function(i){
        sh.eq(i).attr('class', $(this).attr('class'));
      });
    });
    // set sticky header cell width and link clicks to real header
    hdrCells.each(function(i){
      var t = $(this),
      s = stkyCells.eq(i)
      // set cell widths
      .width( t.width() )
      // clicking on sticky will trigger sort
      .bind('click', function(e){
        t.trigger(e);
      })
      // prevent sticky header text selection
      .bind('mousedown', function(){
        this.onselectstart = function(){ return false; };
        return false;
      });
    });
    header.prepend( sticky );
    // make it sticky!
    win
      .scroll(function(){
        var offset = firstCell.offset(),
          sTop = win.scrollTop(),
          vis = ((sTop > offset.top) && (sTop < offset.top + $table.find('tbody').height())) ? 'visible' : 'hidden';
        sticky.css({
          left : offset.left - win.scrollLeft(),
          visibility : vis
        });
        if (vis !== laststate) {
          // trigger resize to make sure the column widths match
          win.resize();
          laststate = vis;
        }
      })
      .resize(function(){
        sticky.css({
          left : firstCell.offset().left - win.scrollLeft(),
          width: header.outerWidth() + brdr * 2
        });
        stkyCells.each(function(i){
          $(this).width( hdrCells.eq(i).width() );
        });
      });
  }
});
