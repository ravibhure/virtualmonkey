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
    @logger.info("[CONFIG] Max retries = #{@cloud_shepherd_max_retries}")
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

    job_run_count = 0

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

    # Now that we have the first (possible) job to start, process the the vertical
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

      # The row "j" header has the troop name so get that
      troop_name = @parsed_job_definition[i][@troop_column]

      # Assemble the input folder name
      suite_name = @suite_prefix + "_#{cloud_name}" + "_" + image_name
      deployment_name = "#{@destroyers ? "Z_" : ""}" + suite_name + "_#{job_number}" + "_" + troop_name
      input_folder_path = @edited_input_file_path + deployment_name

      # Only clean the Jenkins job if this is a normal job element
      if is_job_element?(element)
        @logger.info("Processing deployment #{deployment_name}...")


        # Validate the Jenkins job for this element
        if !validate_jenkins_folder(input_folder_path)
          next
        end

        # If the nextBuildNumber file is missing then this job has not yet been built, so this means
        # this cell's job has not yet run and we generate a white empty cell
        next_build_number_file = input_folder_path + "/" + "nextBuildNumber"
        current_build_log = ""
        if FileTest.exists? next_build_number_file
          # Parse the next build number from the nextBuildNumber file and decrement it to get the last build number
          currentBuildNumber = Integer(File.open(next_build_number_file, 'rb') { |file| file.read }) - 1

          # Now look in the last build folder for the log file
          current_build_log = input_folder_path + "/" + "builds/" + "#{currentBuildNumber}/log"
        end

        # Save path to current Jenkins job
        path_to_current_jenkins_job = "http://#{@jenkins_ip_address}:8080/job/#{deployment_name}"

        # Parse the log file if it exists to save off the information
        last_line, link_to_log, log_as_string = get_log_file_information(current_build_log,
                                                                         path_to_current_jenkins_job,
                                                                         currentBuildNumber)

        # If the current test is in the "PASSED" state skip it
        if last_line == "Finished: SUCCESS"
          @logger.info("Skipping #{deployment_name} [SUCCEEDED]...")
        else
          #
          # If this isn't active job, start it
          #

          @logger.info("Searching for #{deployment_name} in current deployments...")

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

          if deployment_exists
            @logger.info("#{deployment_name} active, sleeping for #{@cloud_shepherd_sleep_before_retrying_job_in_seconds} seconds and retrying...")
            sleep(@cloud_shepherd_sleep_before_retrying_job_in_seconds)
            redo
          else
            # The deployment wasn't found so kick off the test
            @logger.info("Deployment #{deployment_name} not active, starting via Jenkins then sleeping for #{@cloud_shepherd_sleep_after_job_start_in_seconds} seconds...")
            job_run_count += 1
            start_jenkins_job(@logger, deployment_name, 3, 10)

            # Now sleep to wait for the deployment to be created
            sleep(@cloud_shepherd_sleep_after_job_start_in_seconds)
            redo
          end
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
    end

    if job_run_count > 0
      @logger.info("#{job_run_count} jobs run.")
    else
      # Warning user if no jobs to run found
      @logger.info("No jobs found to run!")
    end

    @logger.info("Cloud Shepherd run completed.")
  end
end
