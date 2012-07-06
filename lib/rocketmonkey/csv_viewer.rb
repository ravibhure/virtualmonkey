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

# Third party requires
require 'rubygems'
require 'terminal-table'

# RocketMonkey requires
require 'rocketmonkey_base'


########################################################################################################################
# CsvViewer class
########################################################################################################################
class CsvViewer < RocketMonkeyBase

  ######################################################################################################################
  # instance method: initialize
  ######################################################################################################################
  def initialize(version, csv_input_filename)
    super(version, false, csv_input_filename, 0, false, nil)
  end



  ######################################################################################################################
  # instance method: view
  #
  # Based on the supplied inputs this function will view the csv file
  ######################################################################################################################
  def view
    table = Terminal::Table.new
    @parsed_job_definition.collect do |line|
      table << line
      table << :separator
    end
    puts table
  end
end
