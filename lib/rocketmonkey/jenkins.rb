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
# Jenkins related helper functions
########################################################################################################################

# Third party requires
require 'rubygems'


########################################################################################################################
# function: stop_jenkins_service
#########################################################################################################################
def stop_jenkins_service()
  puts "Stopping Jenkins Service..."
  system("service jenkins stop")
end



########################################################################################################################
# function: start_jenkins_service
#########################################################################################################################
def start_jenkins_service()
  puts "Starting Jenkins Service..."
  system("service jenkins start")
end
