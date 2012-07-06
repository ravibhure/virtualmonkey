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
# Helpers
########################################################################################################################

# Third party requires
require 'rubygems'


########################################################################################################################
# function: get_user_confirmation
#
# Get confirmation to proceed. Returns true if we should proceed, otherwise false.
#
# This implementation allows us to get a single character of input without requiring the user to hit Enter.
########################################################################################################################
def get_user_confirmation(message, yes_override, no_override)
  if !yes_override && !no_override
    begin
      print message + " "
      begin
        system("stty raw -echo")
        str = STDIN.getc
      ensure
        system("stty -raw echo")
      end
      answer = str.chr
      answer.downcase!
      printf("%s\n", answer)
    end while answer != "y" && answer != "n"
    return answer == "y"
  else
    if no_override
      return false
    else
      return true
    end
  end
end
