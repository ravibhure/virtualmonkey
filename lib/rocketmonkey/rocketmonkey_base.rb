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
require 'yaml'
require 'csv'

# RocketMonkey requires
require 'patches'


# Global to hold the truncate troops default value
$truncate_troops_default = 10240


########################################################################################################################
# RocketMonkeyBase "abstract" class
########################################################################################################################
class RocketMonkeyBase

  ######################################################################################################################
  # instance method: initialize
  ######################################################################################################################
  def initialize(version, suppress_variable_data, csv_input_filename, refresh_rate_in_seconds, truncate_troops,
      failure_report_run_time, cloud_filter)

    # Initialize the logger
    @logger = Logger.new(STDOUT)
    @logger.level = Logger::INFO
    @logger.progname = "Rocket Monkey"
    # Force flushing stdout on every call to the logger
    $stdout.sync = true

    @version = version
    @suppress_variable_data = suppress_variable_data
    @csv_input_filename = csv_input_filename
    @refresh_rate_in_seconds = refresh_rate_in_seconds
    @truncate_troops = truncate_troops
    @failure_report_run_time = failure_report_run_time
    @show_wip_statistics_table = true # CURRENTLY, may only reset from within the CSV file

    # Initialize CSV in memory array fixed row and column variables
    @report_title_prefix_row = 0
    @key_value_pairs_row = 0
    @key_value_pairs_column = 1
    @server_template_column = 0
    @cloud_row = 1
    @troop_column = 1
    @start_row = 2
    @start_column = 2

    # Parse the yaml file settings
    config_file_name = ".rocketmonkey.yaml"
    puts "\nLoading #{config_file_name}..."
    @config = YAML::load(File.open(File.dirname($0) + "/.rocketmonkey.yaml"))

    # Sanity check config file inputs
    raise "Missing resume definition in yaml file" if @config[:resume] == nil
    raise "Missing email_from definition in yaml file" if @config[:email_from] == nil
    raise "Missing email_to definition in yaml file" if @config[:email_to] == nil
    raise "Missing jenkins_user definition in yaml file" if @config[:jenkins_user] == nil
    raise "Missing jenkins_password definition in yaml file" if @config[:jenkins_password] == nil
    raise "Missing cloud_ids definition in yaml file" if @config[:cloud_ids] == nil
    raise "cloud_ids definition in yaml file is not a hash" if !@config[:cloud_ids].is_a?(Hash)
    raise "Missing output_file_path definition in yaml file" if @config[:output_file_path] == nil
    raise "Missing troop_path definition in yaml file" if @config[:troop_path] == nil
    raise "Missing chain definition in yaml file" if @config[:chain] == nil
    raise "Missing threshold definition in yaml file" if @config[:threshold] == nil
    raise "Missing rightscale_account definition in yaml file" if @config[:rightscale_account] == nil
    raise "Missing virtual_monkey_path definition in yaml file" if @config[:virtual_monkey_path] == nil
    raise "Missing failure_report_regular_expressions hash definition in yaml file" \
      if @config[:failure_report_regular_expressions] == nil
    raise "failure_report_regular_expressions definition in yaml file is not a hash" \
      if !@config[:failure_report_regular_expressions].is_a?(Hash)
    raise "Missing cloud_shepherd_max_retries definition in yaml file" if @config[:cloud_shepherd_max_retries] == nil
    raise "Missing cloud_shepherd_sleep_before_retrying_job_in_seconds definition in yaml file" if @config[:cloud_shepherd_sleep_before_retrying_job_in_seconds] == nil
    raise "Missing cloud_shepherd_sleep_after_job_start_in_seconds definition in yaml file" if @config[:cloud_shepherd_sleep_after_job_start_in_seconds] == nil

    @resume = @config[:resume]
    @email_to = @config[:email_to]
    @email_from = @config[:email_from]
    @jenkins_user = @config[:jenkins_user]
    @jenkins_password = @config[:jenkins_password]
    @cloud_ids = @config[:cloud_ids]
    @output_file_path = @config[:output_file_path]
    @mci_override_file_name = @config[:mci_override_file_name] # The mci_override_file_name is optional
    @troop_path = @config[:troop_path]
    @chain = @config[:chain]
    @threshold = @config[:threshold]
    @rightscale_account = @config[:rightscale_account]
    @virtual_monkey_path = @config[:virtual_monkey_path]
    @cloud_shepherd_max_retries = @config[:cloud_shepherd_max_retries]
    @cloud_shepherd_sleep_before_retrying_job_in_seconds = @config[:cloud_shepherd_sleep_before_retrying_job_in_seconds]
    @cloud_shepherd_sleep_after_job_start_in_seconds = @config[:cloud_shepherd_sleep_after_job_start_in_seconds]

    # Get ip address of Jenkins host
    if @suppress_variable_data
      @jenkins_ip_address = "localhost"
    else
      @jenkins_ip_address = IPSocket.getaddress(Socket.gethostname)
    end

    # Parse the CSV file into a 2-dimensional array
    @parsed_job_definition = CSV.read(@csv_input_filename)

    # Parse out cloud filter and check that it is valid
    cloud_filter ||= ""
    @cloud_filter = cloud_filter.split(/ /)
    @cloud_filter.each { |element|
      # Calling get_cloud_id will validate the cloud-region for us
      get_cloud_id(element)
    }

    # Clean up the input path and make sure it has the trailing '/'
    # Here in the report generator we use what was the @output_file_path in the JenkinsJobGenerator
    # as the input file path. This came from the yaml file.
    @edited_input_file_path = edit_path(@output_file_path)

    # Get the suite prefix from the first element
    @suite_prefix = @parsed_job_definition[@cloud_row][@server_template_column].strip

    # Parse out any CSV file "overall" key value pairs
    key_value_pairs = @parsed_job_definition[@key_value_pairs_row][@key_value_pairs_column]
    if key_value_pairs != nil
      # Handle any optional <key>:<value> pairs - there may be any number of them and if there
      # are duplicate keys, the last one encountered wins.
      split_key_value_pairs = key_value_pairs.split(/\n/)

      split_key_value_pairs.each do |element|
        split_key_value_pairs_array = element.split(/:/)

        if split_key_value_pairs_array.length < 2
          raise "Invalid format for optional key,value pairs found in \"#{element}\", should be in the form <key>:<value> at row: #{@key_value_pairs_row + 1}, column: #{@key_value_pairs_column + 1} in #{@csv_input_filename}"
        end

        # Set values if they were not already set via command line arguments
        if split_key_value_pairs_array[0].upcase == "TRUNCATE-TROOPS"
          if @truncate_troops == $truncate_troops_default
            @truncate_troops = Integer(split_key_value_pairs_array[1])
          end
        elsif split_key_value_pairs_array[0].upcase == "FAILURE-REPORT-RUN-TIME"
          if @failure_report_run_time == nil
            @failure_report_run_time = split_key_value_pairs_array[1]
          end
        elsif split_key_value_pairs_array[0].upcase == "SHOW-JOB-NUMBERS"
          if @show_job_numbers == nil
            @show_job_numbers = split_key_value_pairs_array[1].to_bool
          end
        elsif split_key_value_pairs_array[0].upcase == "SHOW-WIP-STATISTICS-TABLE"
          @show_wip_statistics_table = split_key_value_pairs_array[1].to_bool
        else
          raise "Invalid column parameter key \"#{element}\" found at row: #{@key_value_pairs_row + 1}, column: #{@key_value_pairs_column +1 } in #{@csv_input_filename}"
        end
      end
    end
  end



  ######################################################################################################################
  # instance method: edit_path
  #
  # Strips leading and trailing whitespace and then adds a trailing slash '/' to path if it isn't already there
  ######################################################################################################################
  def edit_path(path)
    # Clean up the output path and make sure it has the trailing '/'
    edited_output_file_path = path.strip
    if edited_output_file_path[edited_output_file_path.length - 1] != '/'
      edited_output_file_path += '/'
    end
    return edited_output_file_path
  end



  ######################################################################################################################
  # instance method: get_cloud_variables
  #
  # The <column> header has the cloud name, region name and image name separated by a newline so
  # parse them out into their respective variables.
  ######################################################################################################################
  def get_cloud_variables(column)
    split_cloud_region_image_array = @parsed_job_definition[@cloud_row][column].split(/\n/)
    raw_cloud_name = cloud_lookup_name = cloud_name = split_cloud_region_image_array[0]
    region_name = split_cloud_region_image_array[1]
    cloud_name += "_" + region_name if region_name != ""
    image_name = split_cloud_region_image_array[2]
    cloud_lookup_name += "-"
    cloud_lookup_name += region_name if region_name != ""
    cloud_lookup_name += "-"
    cloud_lookup_name += image_name if image_name != ""
    return split_cloud_region_image_array, raw_cloud_name, cloud_lookup_name, cloud_name, region_name, image_name
  end



  ######################################################################################################################
  # instance method: get_cloud_id
  #
  # Returns the cloud ID based on the cloud lookup name.
  #
  # If no mapping exists, an exception is raised
  ######################################################################################################################
  def get_cloud_id(cloud_lookup_name)
    # Remove image from the cloud-region-image for looking up the cloud-region in the yaml file
    element_array = cloud_lookup_name.split(/-/)
    cloud_region = element_array[0]
    cloud_region += "-" + element_array[1] if element_array[1] != ""

    # Get cloud ID from the lookup name
    cloud_id = @cloud_ids[cloud_region]

    # If the cloud we find isn't defined in the yaml config file raise an error
    raise "Cloud-Region #{cloud_region} not found in cloud_ids map in yaml file." if cloud_id == nil

    return cloud_id
  end



  ######################################################################################################################
  # instance method: cloud_in_filter?
  #
  # Based on the supplied inputs this function will return true if the given cloud_lookup_name is in
  # the cloud filter or if the filter is empty (i.e., all clouds included), otherwise false.
  ######################################################################################################################
  def cloud_in_filter?(cloud_lookup_name)
    if @cloud_filter.length > 0
      return @cloud_filter.include?(cloud_lookup_name)
    end
    return true
  end



  ######################################################################################################################
  # instance method: get_next_job
  #
  # Will return the next job number, troop pair skipping over NS, NSY & DIS cells
  ######################################################################################################################
  def get_next_job(current_row, current_column)
    next_row = current_row + 1
    while next_row < @parsed_job_definition.length
      element = @parsed_job_definition[next_row][current_column]
      if element.respond_to?(:upcase)
        if (element.upcase == "NS") || (element.upcase == "NSY") || (element.upcase == "DIS")
          # Skip past the "Not Supported" type entries
          next_row = next_row + 1
        else
          # Some other text that may or may not be allowed but that is tested elsewhere
          break
        end
      else
        break
      end
    end

    if next_row < @parsed_job_definition.length
      next_job_number = sprintf('%03d', next_row)
      next_troop = @parsed_job_definition[next_row][@troop_column]
    else
      next_job_number = nil
      next_troop = nil
    end
    return next_job_number, next_troop
  end



  ######################################################################################################################
  # instance method: raise_invalid_element_exception
  #
  # Will raise the invalid element exception when called
  ######################################################################################################################
  def raise_invalid_element_exception(element, row, column)
    raise "Invalid value \"#{element}\" found at row: #{row + 1}, column: #{column + 1} in #{@csv_input_filename}"
  end



  ######################################################################################################################
  # instance method: is_cloud_column_enabled?
  #
  # Returns the true if the cloud column is enabled, otherwise false.
  ######################################################################################################################
  def is_cloud_column_enabled?(split_cloud_region_image_array)
    # Check to see if the column has been completely disabled
    column_enabled = true
    for split_column_parameters_index in 3..split_cloud_region_image_array.length - 1
      split_column_parameters_array = split_cloud_region_image_array[split_column_parameters_index].split(/:/)

      # Enforce <key>:<value> semantics
      if split_column_parameters_array.length != 2
        raise "Invalid format for optional column parameter found in \"#{split_cloud_region_image_array[split_column_parameters_index]}\", should be in the form <key>:<value> in #{@csv_input_filename}"
      end

      if split_column_parameters_array[0].upcase == "ENABLED" && !split_column_parameters_array[1].to_bool
        column_enabled = false
      end
    end
    return column_enabled
  end



  ######################################################################################################################
  # instance method: is_job_element?
  #
  # Returns true if the given element is a normal job element (i.e., the element is empty
  # or it has a valid element file reference (f:<filename>)
  ######################################################################################################################
  def is_job_element?(element)
    return element == nil || (element[0..1].upcase == "F:" && element.length > 2) ||
        (element[0..1].upcase == "M:" && element.length > 2)
  end



  ######################################################################################################################
  # instance method: is_not_supported_element?
  #
  # Returns true if the given element is a not supported job element (i.e., contains only "NS")
  ######################################################################################################################
  def is_not_supported_element?(element)
    return element.upcase == "NS"
  end



  ######################################################################################################################
  # instance method: is_not_supported_yet_element?
  #
  # Returns true if the given element is a not supported yet job element (i.e., contains only "NSY")
  ######################################################################################################################
  def is_not_supported_yet_element?(element)
    return element.upcase == "NSY"
  end



  ######################################################################################################################
  # instance method: is_disabled_element?
  #
  # Returns true if the given element is a disabled job element (i.e., contains only "DIS")
  ######################################################################################################################
  def is_disabled_element?(element)
    return element.upcase == "DIS"
  end



  ######################################################################################################################
  # instance method: is_ns_nsy_dis_element?
  #
  # Returns true if the given element is a disabled job element (i.e., contains only "NS", "NSY" or "DIS")
  ######################################################################################################################
  def is_ns_nsy_dis_element?(element)
    return is_not_supported_element?(element) ||
        is_not_supported_yet_element?(element) ||
        is_disabled_element?(element)
  end



  ######################################################################################################################
  # instance method: get_job_order_number_as_string
  #
  # Returns a string containing a properly formatted job order number.
  ######################################################################################################################
  def get_job_order_number_as_string(column)
    return sprintf('%03d', column)
  end



  ######################################################################################################################
  # instance method: validate_jenkins_folder
  #
  # Based on the supplied inputs this function will validate the jenkins folder path for a specific job. If it is
  # invalid, an exception is raised.
  ######################################################################################################################
  def validate_jenkins_folder(input_folder_path)
    # Assemble the Jenkins config.xml file name and make sure that it is there
    config_file_path = input_folder_path + "/" + "config.xml"

    if !FileTest.exists? config_file_path
      puts "Unexpected Jenkins folder structure encountered, \"#{config_file_path}\" missing."
      return false
    end

    return true
  end



  ######################################################################################################################
  # instance method: start_jenkins_job
  #
  # Based on the supplied inputs this function will launch the jenkins job named <deployment_name>.
  ######################################################################################################################
  def start_jenkins_job(logger, deployment_name, max_tries, sleep_between_http_retries_in_seconds)
    logger.info("Launching #{deployment_name}...")

    for http_retry_counter in 1..max_tries
      if http_retry_counter == max_tries
        raise "Jenkins failed after #{max_tries - 1} attempts to start #{deployment_name}"
      end
      response = nil
      Net::HTTP.start("#{@jenkins_ip_address}", 8080) { |http|
        request = Net::HTTP::Get.new("/job/#{deployment_name}/build?delay=0sec")
        request.basic_auth @jenkins_user, @jenkins_password
        response = http.request(request)
      }

      # Test to see if Jenkins is still waking up
      if response.body =~ /Please wait while Jenkins is getting ready to work/
        logger.info("Jenkins is still getting ready, sleeping for #{sleep_between_http_retries_in_seconds} seconds then retrying...")
        sleep(sleep_between_http_retries_in_seconds)
      elsif response.body =~ /Error/i
        logger.info("Error starting job, sleeping for #{sleep_between_http_retries_in_seconds} seconds then retrying...")
        sleep(sleep_between_http_retries_in_seconds)
      else
        logger.info("Jenkins reported start was successful.")
        break
      end
    end
  end



  ######################################################################################################################
  # instance method: get_log_file_information
  #
  # Based on the supplied inputs this function will return the last line from the Jenkins console log if it exists
  # or and empty string if it doesn't. It also returns a link to that same log and the log as a string if it exists
  # or nil if it doesn't.
  ######################################################################################################################
  def get_log_file_information(current_build_log, jenkins_job_href, currentBuildNumber)
    last_line = ""
    link_to_log = nil
    log_as_string = nil
    if FileTest.exists? current_build_log
      # Attempt to load the the virtual monkey report url as will can use it in all 4 cases below
      log_as_string = File.open(current_build_log, 'rb') { |file| file.read }
      monkey_results = log_as_string.scan(/http:\/\/s3.amazonaws.*?html/)

      # if we have some results from the monkey use those as the link, otherwise provide a URL to
      # this Job's Jenkins console output
      if monkey_results.length > 0
        link_to_log = monkey_results[0]
      else
        link_to_log = "#{jenkins_job_href}/#{currentBuildNumber}/console"
      end

      # Get the last line of the build file
      Elif.open(current_build_log, "r").each_line { |s|
        # Need to chomp off the newline
        last_line = s.chomp
        break
      }
    end
    return last_line, link_to_log, log_as_string
  end



  ######################################################################################################################
  # instance method: get_jenkins_root_href
  #
  # Based on the supplied inputs this function will return Jenkins root href.
  ######################################################################################################################
  def get_jenkins_root_href()
    return "http://#{@jenkins_ip_address}:8080"
  end



  ######################################################################################################################
  # instance method: get_jenkins_job_href
  #
  # Based on the supplied inputs this function will return a valid Jenkins job href.
  ######################################################################################################################
  def get_jenkins_job_href(deployment_name)
    return "#{get_jenkins_root_href()}/job/#{deployment_name}"
  end
end
