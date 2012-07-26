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
require "net/http"

# RocketMonkey requires
require 'rocketmonkey_base'


########################################################################################################################
# TestStarter class
########################################################################################################################
class TestStarter < RocketMonkeyBase

  ######################################################################################################################
  # instance method: initialize
  ######################################################################################################################
  def initialize(version, csv_input_filename)
    super(version, false, csv_input_filename, 0, false, nil, nil)
  end



  ######################################################################################################################
  # instance method: start_column_header_jobs
  #
  # Based on the supplied inputs this function will kick off all the job columns
  ######################################################################################################################
  def start_column_header_jobs
    @logger.info("Please wait while Jenkins is getting ready to work...")

    # Sleep for a while to allow Jenkins to respond to http requests. This is needed because after a service start,
    # it take Jenkins a little while before it is available to respond to the http requests we will be making below.
    sleep(20)

    # Get the suite prefix from the first element
    suite_prefix = @parsed_job_definition[@cloud_row][@server_template_column].strip

    # Setup array to track if a column has been started
    column_started = Array.new(@parsed_job_definition[@start_row].length)
    column_started.fill(false)

    # Traverse rows
    for i in @start_row..@parsed_job_definition.length - 1

      # The row "j" header has the troop name so get that
      troop_name = @parsed_job_definition[i][@troop_column]

      # Traverse columns
      for j in @start_column..@parsed_job_definition[i].length - 1

        # Skip this column if it has already been started
        next if column_started[j]

        element = @parsed_job_definition[i][j]

        # Strip off all leading and trailing spaces
        element.strip! if element != nil

        # Parse out the cloud variables
        split_cloud_region_image_array, raw_cloud_name, cloud_lookup_name, cloud_name, region_name, image_name \
            = get_cloud_variables(j)

        if !is_cloud_column_enabled?(split_cloud_region_image_array)
          next
        end

        # Only clean the Jenkins job if this is a normal job element
        if is_job_element?(element)

          # Get cloud ID from the lookup name
          cloud_id = get_cloud_id(cloud_lookup_name)

          # Build the complete suite name
          suite_name = suite_prefix + "_#{cloud_name}" + "_" + image_name

          # Compute a unique job number
          job_number = get_job_order_number_as_string(i)

          # Assemble the input folder name
          suite_name = suite_prefix + "_#{cloud_name}" + "_" + image_name
          deployment_name = suite_name + "_#{job_number}" + "_" + troop_name

          # Launch the job
          start_jenkins_job(@logger, deployment_name, 21, 10)

          # Flag that we have started this column
          column_started[j] = true

        elsif is_ns_nsy_dis_element?(element)
          # OK - nothing to clean in this case
        else
          raise_invalid_element_exception(element, i, j)
        end
      end
    end
  end
end
