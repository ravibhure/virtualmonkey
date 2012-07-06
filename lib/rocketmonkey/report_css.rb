#--
# Copyright (c) 2012 RightScale, Inc, All Rights Reserved Worldwide.
#
# THIS PROGRAM IS CONFIDENTIAL AND PROPRIETARY TO RIGHTSCALE
# AND CONSTITUTES A VALUABLE TRADE SECRET.  Any unauthorized use,
# reproduction, modification, or disclosure of this program is
# strictly prohibited.  Any use of this program by an authorized
# licensee is strictly subject to the terms and conditions,
# including confidentiality obligations, set forth in the applicable
# License Agreement between RightScale, Inc. and
# the licensee.
#++

########################################################################################################################
# ReportCss mixin module
########################################################################################################################
module ReportCss

  ######################################################################################################################
  # instance method: initialize_css
  ######################################################################################################################
  def initialize_css
    # Setup style sheet
    @style_sheet = <<EOS
     <style type="text/css">
        h1,h2,h3,h4,h5 {
          margin:0;
          padding:0;
        }
        body { margin:0; padding:0; font-size:70.5%; /* font-family:'Lucida Sans', Verdana, Arial, sans-serif; */ font-family:"Lucida Grande","Lucida Sans Unicode","Lucida Sans",Verdana,lucida,sans-serif; background:#FFF; height:100%}
        html {height:100%}
        a img {border:none}
        a {text-decoration:none; color:#1e4a7e}

        #header {
          background:#235186;
          padding:2px 20px;
          position:relative;
          height:25px;
        }

        #header #vmonk {
          font-size: 18px;
          font-weight:bold;
          color: orange;
          padding:2px 20px;
          position:relative;
          top: -4px;
          height:25px;
          white-space:nowrap;
        }

        #header #logo {
          margin-top:3px;
        }

        #header #jenkins {
          float: left;
          position: relative;
          top: -50px;
        }

        #footer {
          background:#235186;
          padding:2px 20px;
          height:25px;
        }

        #footer #vmonkfooter {
          font-size: 12px;
          font-weight:bold;
          color: orange;
          padding:2px 10px;
          position:relative;
          top: 4px;
          height:25px;
          white-space:nowrap;
        }

        #footer #monkey {
          float: right;
          position: relative;
          top: -25px;
        }
     </style>
EOS
  end
end
