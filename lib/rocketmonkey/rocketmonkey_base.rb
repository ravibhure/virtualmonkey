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
      failure_report_run_time)
    @version = version
    @suppress_variable_data = suppress_variable_data
    @csv_input_filename = csv_input_filename
    @refresh_rate_in_seconds = refresh_rate_in_seconds
    @truncate_troops = truncate_troops
    @failure_report_run_time = failure_report_run_time

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
    @config = YAML::load(File.open(".rocketmonkey.yaml"))

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

    # Get ip address of Jenkins host
    if @suppress_variable_data
      @jenkins_ip_address = "localhost"
    else
      @jenkins_ip_address = IPSocket.getaddress(Socket.gethostname)
    end

    # Parse the CSV file into a 2-dimensional array
    @parsed_job_definition = CSV.read(@csv_input_filename)

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
    raw_cloud_name = cloud_lookup = cloud_name = split_cloud_region_image_array[0]
    region_name = split_cloud_region_image_array[1]
    cloud_name += "_" + region_name if region_name != ""
    image_name = split_cloud_region_image_array[2]
    cloud_lookup += "-" + region_name if region_name != ""
    return split_cloud_region_image_array, raw_cloud_name, cloud_lookup, cloud_name, region_name, image_name
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
  # instance method: get_cloud_id
  #
  # Returns the cloud ID based on the cloud lookup name.
  #
  # If no mapping exists, an exception is raised
  ######################################################################################################################
  def get_cloud_id(cloud_lookup_name)
    # Get cloud ID from the lookup name
    cloud_id = @cloud_ids[cloud_lookup_name]

    # If the cloud we find isn't defined in the yaml config file raise an error
    raise "Missing cloud definition in yaml file for #{cloud_lookup_name}" if cloud_id == nil

    return cloud_id
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

end
