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

# RocketMonkey requires
require 'rocketmonkey_base'
require 'report_generator'


########################################################################################################################
# JenkinsJobCleaner class
########################################################################################################################
class JenkinsJobCleaner < RocketMonkeyBase

  ######################################################################################################################
  # instance method: initialize
  ######################################################################################################################
  def initialize(version, csv_input_filename, nuclear_option)
    super(version, false, csv_input_filename, 0, false, nil, nil)

    @nuclear_option = nuclear_option
  end



  ########################################################################################################################
  # class method: cleanup_old_jenkins_jobs
  #########################################################################################################################
  def self.cleanup_old_jenkins_jobs(opts, version, nuclear_option)
    if get_user_confirmation("Delete current Jenkins build state for #{opts[:input]} (y/n)?", opts[:yes], opts[:no])
      if get_user_confirmation("Generate snapshot reports for #{opts[:input]} before cleaning (y/n)?", opts[:yes],
                               opts[:no])
        report_type = "Snapshot"
        report_generator = ReportGenerator.new(version, opts[:input], opts[:refresh_rate], true, opts[:leave],
                                               opts[:suppress_variable_data], false, opts[:truncate_troops],
                                               opts[:cloud_filter], opts[:generate_actions], opts[:mail_failure_report])
        report_generator.generate_reports()

        report_generator = ReportGenerator.new(version, opts[:input], opts[:refresh_rate], true, opts[:leave],
                                               opts[:suppress_variable_data], true, opts[:truncate_troops],
                                               opts[:cloud_filter], opts[:generate_actions], opts[:mail_failure_report])
        report_generator.generate_reports()
      end
      jenkins_job_cleaner = JenkinsJobCleaner.new(version, opts[:input], nuclear_option)
      jenkins_job_cleaner.clean()
    end
  end



  ######################################################################################################################
  # instance method: clean_jenkins_job
  #
  # Based on the supplied inputs this function will clean the specified Jenkins job folder
  ######################################################################################################################
  def clean_jenkins_job(output_folder_name)
    # Clean the job
    edited_job_folder_path = "#{edit_path(@output_file_path) + output_folder_name + "/"}"
    edited_next_build_number_file_path = "#{edited_job_folder_path + "nextBuildNumber"}"
    edited_job_folder_builds_path = "#{edited_job_folder_path + "builds"}"

    puts "Cleaning #{output_folder_name}..."
    if File.exists?(edited_next_build_number_file_path)
      File.unlink(edited_next_build_number_file_path)
    end
    if File.exists?(edited_job_folder_builds_path)
      FileUtils.rm_rf(edited_job_folder_builds_path)
    end
  end



  ######################################################################################################################
  # instance method: clean
  #
  # Based on the supplied inputs this function will clean all the Jenkins jobs
  ######################################################################################################################
  def clean

    # Get the suite prefix from the first element
    suite_prefix = @parsed_job_definition[@cloud_row][@server_template_column].strip

    puts "Cleaning #{suite_prefix}..."

    if @nuclear_option
      folder_spec = edit_path(@output_file_path) + "*"
      puts "Removing #{folder_spec}..."
      system("rm -rf " + folder_spec)
    else
      # Traverse rows
      for i in @start_row..@parsed_job_definition.length - 1

        # The row "j" header has the troop name so get that
        troop_name = @parsed_job_definition[i][@troop_column]

        # Traverse columns
        for j in @start_column..@parsed_job_definition[i].length - 1

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

            # Compute a unique job number and build the complete XML output file name
            job_number = get_job_order_number_as_string(i)
            output_folder_name = suite_name + "_#{job_number}" + "_" + troop_name

            # Clean the job
            clean_jenkins_job(output_folder_name)

            # Clean the destroyer job
            clean_jenkins_job("Z_" + output_folder_name)

          elsif is_ns_nsy_dis_element?(element)
            # OK - nothing to clean in this case
          else
            raise_invalid_element_exception(element, i, j)
          end
        end
      end
    end
  end
end
