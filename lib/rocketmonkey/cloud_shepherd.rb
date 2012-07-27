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
require 'fileutils'
require 'logger'

# RocketMonkey requires
require 'rocketmonkey_base'


########################################################################################################################
# CloudShepherd class
########################################################################################################################
class CloudShepherd < RocketMonkeyBase

  ######################################################################################################################
  # instance method: initialize
  ######################################################################################################################
  def initialize(version, csv_input_filename, cloud_filter)
    super(version, false, csv_input_filename, 0, false, nil, cloud_filter)
  end



  ######################################################################################################################
  # instance method: start
  #
  # Based on the supplied inputs this function will clean the specified Jenkins job folder
  ######################################################################################################################
  def start(start_job)

    # Log starting point
    @logger.info("Cloud Shepherd started...")

    # Only allow one cloud filter name, i.e., we will only shepherd on vertical in this process
    raise "Only one cloud filter name allowed in cloud shepherd mode" if @cloud_filter.count() > 1

    cloud_filter = @cloud_filter.first

    @logger.info("[CONFIG] Cloud filter = '#{cloud_filter}'")
    @logger.info("[CONFIG] Start job = #{start_job}")
    @logger.info("[CONFIG] Max deployment start try count = #{@cloud_shepherd_max_retries}")
    @logger.info("[CONFIG] Sleep before retrying job in seconds = #{@cloud_shepherd_sleep_before_retrying_job_in_seconds}")
    @logger.info("[CONFIG] Sleep after job start in seconds = #{@cloud_shepherd_sleep_after_job_start_in_seconds}")

    # Find the matching cloud-region column
    cloud_state = :not_found
    for j in @start_column..@parsed_job_definition[@cloud_row].length - 1
      # Split out the cloud, region and image which are all separated by newlines
      split_cloud_region_image_array, raw_cloud_name, cloud_lookup_name, cloud_name, region_name, image_name \
        = get_cloud_variables(j)

      # Skip this column if this cloud/region should be filtered
      if cloud_in_filter?(cloud_lookup_name)
        cloud_state = :found
        break
      end

      if !is_cloud_column_enabled?(split_cloud_region_image_array)
        cloud_state = :disabled
        break
      end
    end

    # Make sure we found a matching cloud
    raise "No matching cloud found!" if cloud_state == :not_found

    # Make the matching cloud is enabled
    raise "Cloud #{cloud_lookup_name} is disabled" if cloud_state == :disabled

    # Initialize the deployment start counter
    deployment_start_count = 0

    # Find the first job that matches start_job
    job_number_found = false
    for i in @start_row..@parsed_job_definition.length - 1
      # Compute a unique job number
      job_number = get_job_order_number_as_string(i)
      if start_job == job_number.to_i
        job_number_found = true
        break
      end
    end

    # Make sure we found a matching cloud
    raise "Start job #{start_job} not found! Highest job number found for #{cloud_lookup_name} was #{job_number}" if !job_number_found

    # Get the suite prefix from the first element
    suite_prefix = @parsed_job_definition[@cloud_row][@server_template_column].strip

    # Now that we have the first (possible) job to start, process the vertical
    deployment_start_try_count = 1
    for i in i..@parsed_job_definition.length - 1
      # Compute a unique job number
      job_number = get_job_order_number_as_string(i)

      # Split out the cloud, region and image which are all separated by newlines
      split_cloud_region_image_array, raw_cloud_name, cloud_lookup_name, cloud_name, region_name, image_name \
        = get_cloud_variables(j)

      # The row "i" header has the troop name so get that
      troop_name = @parsed_job_definition[i][@troop_column]

      element = @parsed_job_definition[i][j]

      # Strip off all leading and trailing spaces
      element.strip! if element != nil

      # Get cloud ID from the lookup name
      cloud_id = get_cloud_id(cloud_lookup_name)

      # The row "i" header has the troop name so get that
      troop_name = @parsed_job_definition[i][@troop_column]

      # Assemble the input folder name
      suite_name = @suite_prefix + "_#{cloud_name}" + "_" + image_name
      deployment_name = suite_name + "_#{job_number}" + "_" + troop_name
      input_folder_path = @edited_input_file_path + deployment_name

      # Only clean the Jenkins job if this is a normal job element
      if is_job_element?(element)
        @logger.info("Processing deployment #{deployment_name}...")

        # Validate the Jenkins job for this element
        if !validate_jenkins_folder(input_folder_path)
          # Invalid element so reset the counter
          deployment_start_try_count = 1

          # Move on to the next deployment
          next
        end

        # Process the build log file if it exists
        next_build_number_file = input_folder_path + "/" + "nextBuildNumber"
        current_build_log = ""
        if FileTest.exists? next_build_number_file
          # Parse the next build number from the nextBuildNumber file and decrement it to get the last build number
          currentBuildNumber = Integer(File.open(next_build_number_file, 'rb') { |file| file.read }) - 1

          # Now look in the last build folder for the log file
          current_build_log = input_folder_path + "/" + "builds/" + "#{currentBuildNumber}/log"
        end

        # Save href to current Jenkins job
        current_jenkins_job_href = get_jenkins_job_href(deployment_name)

        # Parse the log file if it exists to save off the information
        last_line, link_to_log, log_as_string = get_log_file_information(current_build_log,
                                                                         current_jenkins_job_href,
                                                                         currentBuildNumber)

        if last_line == "Finished: SUCCESS"
          # If the current test is in the "PASSED" state just skip past it
          @logger.info("Skipping #{deployment_name} [SUCCEEDED]...")
        else
          #
          # Handle all non-"PASSED" cases
          #

          #
          # Search for this deployment in the list of live deployments
          #
          @logger.info("Searching for #{deployment_name} in live deployments...")

          # Go get all the deployments
          deployment_array = Deployment.find_all

          # Now look for our deployment treating it as a prefix
          deployment_exists = false
          deployment_array.each do |d|
            if d.nickname.to_s =~ /^#{deployment_name}.*/
              deployment_exists = true
              break
            end
          end

          # If the deployment exists in the live deployments, log that we found it, sleep and then loop again but stay
          # on this deployment
          if deployment_exists
            @logger.info("#{deployment_name} active, sleeping for #{@cloud_shepherd_sleep_before_retrying_job_in_seconds} seconds and retrying (#{deployment_start_try_count})...")

            # Sleep before trying again
            sleep(@cloud_shepherd_sleep_before_retrying_job_in_seconds)

            # Loop again BUT STAY ON THE SAME DEPLOYMENT
            redo
          end

          #
          # The deployment wasn't found in the live deployments so kick off the test
          #
          @logger.info("Deployment not active, starting #{deployment_name} via Jenkins...")

          # This block is used to handle any exceptions thrown from start_jenkins_job
          begin
            # If we have exceeded the maximum number of start invocations, log that and move on to the next deployment.
            if deployment_start_try_count > @cloud_shepherd_max_retries
              @logger.info("Skipping #{deployment_name} [TIMED OUT] Maximum number of start attempts (#{@cloud_shepherd_max_retries}) exceeded...")

              # Reset the counter
              deployment_start_try_count = 1

              # Move on to the next deployment
              next
            end

            start_jenkins_job(@logger, deployment_name, 3, 10)

            # Bump counters since no exception was thrown
            deployment_start_count += 1
            deployment_start_try_count += 1

            # Log that we are sleeping to wait for newly started deployment to start
            @logger.info("Sleeping for #{@cloud_shepherd_sleep_after_job_start_in_seconds} seconds waiting for #{deployment_name} to be created...")

            # Now sleep to wait for the deployment to be created
            sleep(@cloud_shepherd_sleep_after_job_start_in_seconds)

          rescue Exception => e
            @logger.warn("Caught exception \"#{e.message}\", skipping...")

            # Reset the counter
            deployment_start_try_count = 1

            # Move on to the next deployment
            next
          end

          # Loop again but stay on the same deployment
          redo
        end

      elsif is_not_supported_element?(element)
        @logger.info("Skipping #{deployment_name} [NOT SUPPORTED]...")
      elsif is_not_supported_yet_element?(element)
        @logger.info("Skipping #{deployment_name} [NOT SUPPORTED YET]...")
      elsif is_disabled_element?(element)
        @logger.info("Skipping #{deployment_name} [DISABLED]...")
      else
        raise_invalid_element_exception(element, i, j)
      end

      # Fell through so Reset the counter
      deployment_start_try_count = 1

      # Move on to the next deployment (implicit next)
    end

    #
    # All done so wrap it up
    #

    # Log deployment start count
    if deployment_start_count > 0
      @logger.info("There were #{deployment_start_count} deployment job starts.")
    else
      # Warning user if no jobs to run found
      @logger.info("No jobs successfully run.")
    end

    # Adios...
    @logger.info("Cloud Shepherd run completed.")
  end
end
