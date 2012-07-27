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
require 'uri'
require 'elif'
require 'mail'
require 'rest_connection'

# RocketMonkey requires
require 'report_generator_base'
require 'report_images'
require 'report_css'


########################################################################################################################
# ZombieReportGenerator class
########################################################################################################################
class ZombieReportGenerator < ReportGeneratorBase

  ######################################################################################################################
  # instance method: initialize
  ######################################################################################################################
  def initialize(version, csv_input_filename, leave, suppress_variable_data, truncate_troops)
    super(version, csv_input_filename, nil, false, leave, suppress_variable_data, truncate_troops, nil, nil)

    @report_sub_title = "Zombie Deployments"
  end



  ######################################################################################################################
  # instance method: generate_table_cell_image
  ######################################################################################################################
  def generate_table_cell_image(fileHtml, action_image_name, test_image, test_link_to_log, tooltip, destroyer_image,
      destroyer_link_to_log, job_name, action_href, notes, z_tooltip, job_number)

    fileHtml.puts "<td><center>"
    fileHtml.puts "<a href=\"#{action_href}\"><img src=\"#{action_image_name}\" alt=\"image\"></a>"
    fileHtml.puts "</center></td>"

    fileHtml.puts "<td><center>"
    if test_image != nil
      if test_link_to_log != nil
        fileHtml.puts "<a href=\"#{test_link_to_log}\" target=\"_blank\"><img src=\"#{test_image}\" alt=\"image\"#{tooltip.length > 0 ? " title='#{CGI.escapeHTML(tooltip)}'" : ""}></a>"
      else
        fileHtml.puts "<img src=\"#{test_image}\" alt=\"image\">"
      end
    else
      fileHtml.puts "&nbsp;"
    end
    fileHtml.puts "</center></td>"

    fileHtml.puts "<td><center>"
    if destroyer_image != nil
      if destroyer_link_to_log != nil
        fileHtml.puts "<a href=\"#{destroyer_link_to_log}\" target=\"_blank\"><img src=\"#{destroyer_image}\" alt=\"image\"#{z_tooltip.length > 0 ? " title='#{CGI.escapeHTML(z_tooltip)}'" : ""}></a>"
      else
        fileHtml.puts "<img src=\"#{destroyer_image}\" alt=\"image\">"
      end
    else
      fileHtml.puts "&nbsp;"
    end
    fileHtml.puts "</center></td>"

    fileHtml.puts "<td><font size = #{@td_font_size}>#{job_name}</font></td>"
    if @show_job_numbers
      fileHtml.puts "<td align = 'center'><font size = #{@td_font_size}>#{job_number}</font></td>"
    end
    fileHtml.puts "<td><font size = #{@td_font_size}>#{notes}</font></td>"
  end



  ######################################################################################################################
  # instance method: generate_table_header_cell
  ######################################################################################################################
  def generate_table_header_cell(fileHtml, title)
    fileHtml.puts "<td bgcolor = '#FFFFCC'><center><font size = #{@td_font_size}><b>#{title}</b></font></center></td>"
  end



  ######################################################################################################################
  # instance method: get_deployment_state
  ######################################################################################################################
  def get_deployment_state(deployment_search_name, destroyer)

    # Traverse rows
    for i in @start_row..@parsed_job_definition.length - 1

      # Compute a unique job number
      job_number = get_job_order_number_as_string(i)

      # Traverse columns
      for j in @start_column..@parsed_job_definition[i].length - 1

        element = @parsed_job_definition[i][j]

        # Strip off all leading and trailing spaces
        element.strip! if element != nil

        # Parse out the cloud variables
        split_cloud_region_image_array, raw_cloud_name, cloud_lookup_name, cloud_name, region_name, image_name \
          = get_cloud_variables(j)

        # Check to see if the column has been completely disabled and if so, skip it
        if !is_cloud_column_enabled?(split_cloud_region_image_array)
          next
        end

        # Only generate the report cell if this is a normal job element
        if is_job_element?(element)

          # Get cloud ID from the lookup name
          cloud_id = get_cloud_id(cloud_lookup_name)

          # The row "i" header has the troop name so get that
          troop_name = @parsed_job_definition[i][@troop_column]

          # Assemble the input folder name
          suite_name = @suite_prefix + "_#{cloud_name}" + "_" + image_name
          deployment_name = "#{destroyer ? "Z_" : ""}" + suite_name + "_#{job_number}" + "_" + troop_name

          if deployment_search_name == deployment_name
            input_folder_path = @edited_input_file_path + deployment_name

            # Validate the Jenkins job for this element
            if !validate_jenkins_folder(input_folder_path)
              return @test_question_image, nil, "", "", job_number
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
            # Now work through the known build scenarios
            if last_line == ""
              return @test_has_not_run_yet_image, nil, "", "", job_number

            elsif last_line == "Finished: SUCCESS"
              return @test_passed_image, link_to_log, "", "", job_number

            elsif last_line == "Finished: FAILURE"
              # Since we have a failure we need to loop through the failure regular expressions and look for the first
              # match
              failure_match, failure_results, description, reference_href, server_template_error =
                  look_for_first_regular_expression_match(deployment_name, log_as_string, nil)

              return server_template_error ? @server_template_test_failed_image : @other_test_failed_image,
                  link_to_log, "",
                  (failure_match ? (description.length > 0 ? description : failure_results[0]) : @no_match_string),
                  job_number

            elsif last_line == "Finished: ABORTED"
              return @test_aborted_image, link_to_log, "", "", job_number

            else
              return @test_running_image, link_to_log, "", "", job_number
            end
          end

        elsif is_ns_nsy_dis_element?(element)
          # Do nothing
        else
          raise_invalid_element_exception(element, i, j)
        end
      end
    end

    # Never found the deployment so warn the user
    warning = "WARNING: Deployment \"#{deployment_search_name}\" not found in this Suite!"
    warn warning
    return nil, nil, warning
  end




  ######################################################################################################################
  # instance method: get_deployment_states
  ######################################################################################################################
  def get_deployment_states(deployment_name)
    test_image, test_link_to_log, test_notes, tooltip, job_number = get_deployment_state(deployment_name, false)
    destroyer_image, destroyer_link_to_log, destroyer_notes, z_tooltip, job_number = get_deployment_state(
        "Z_" + deployment_name, true)
    if test_notes == destroyer_notes
      return test_image, test_link_to_log, tooltip, destroyer_image, destroyer_link_to_log, test_notes, z_tooltip,
          job_number
    elsif test_notes != "" && destroyer_notes == ""
      return test_image, test_link_to_log, tooltip, destroyer_image, destroyer_link_to_log, test_notes, z_tooltip,
          job_number
    elsif test_notes == "" && destroyer_notes != ""
      return test_image, test_link_to_log, tooltip, destroyer_image, destroyer_link_to_log, destroyer_notes, z_tooltip,
          job_number
    else
      return test_image, test_link_to_log, tooltip, destroyer_image, destroyer_link_to_log,
          test_notes + ", " + destroyer_notes, z_tooltip, job_number
    end
  end



  ######################################################################################################################
  # instance method: generate_report
  #
  # Based on the supplied inputs this function will generate the Zombie Deployments Report in html format
  ######################################################################################################################
  def generate_report()
    report_uri = "rocketmonkey/#{@escaped_suite_prefix.downcase}/wipreport/zombie/index.html"

    html_file_name, fileHtml = create_html_report_output_file(
        "#{File.basename(@csv_input_filename, ".*") + "ZombieWip.html"}")

    # Generate document head
    generate_report_document_head_html(fileHtml, @suite_prefix, false, false)

    # Generate body
    generate_report_document_body_start_html(fileHtml, @report_sub_title, "Report")

    # Generate report title area table with rocket monkey image, title and current time (one row, two columns)
    generate_report_title_area_html(fileHtml, false, "<font color='brown'> [Zombie Deployments]</font>")

    # Assume we have zombie deployments
    monkey_mood_image = @pissed_off_monkey_image

    # Generate Report Body
    jenkinsFullURL = "http://#{@jenkins_ip_address}:8080/" + "view/All/job/Z_"

    # Go get all the deployments
    deployment_job_array = []
    deployment_array = Deployment.find_all

    # Now pull out only those with a matching prefix
    deployment_array.each do |d|
      if d.nickname.to_s =~ /^#{@suite_prefix}.*/
        job_name = d.nickname.split(/-/)
        deployment_job_array << [job_name[0], jenkinsFullURL + job_name[0] + "/build?delay=0sec"]
      end
    end

    if deployment_job_array.length > 0
      # Get rid of MCI duplicates
      deployment_job_array.uniq!

      # Sort the array by job name
      deployment_job_array.sort! { |a, b| a[0] <=> b[0] }

      # Generate matrix-based job table
      fileHtml.puts "<object><table rules='rows' border='0' align='center' cellpadding = \"2\" cellspacing=\"0\" summary='none'>"

      # Generate title row
      fileHtml.puts "<tr>"
      generate_table_header_cell(fileHtml, "<br>Destroy")
      generate_table_header_cell(fileHtml, "Test<br>State")
      generate_table_header_cell(fileHtml, "Destroyer<br>State")
      generate_table_header_cell(fileHtml, "<br>Deployment")
      if @show_job_numbers
        generate_table_header_cell(fileHtml, "Job<br>Number")
      end
      generate_table_header_cell(fileHtml, "<br>Notes")
      fileHtml.puts "</tr>"

      # Iterate over all the deployments and generate table cells for them
      deployment_job_array.each do |element|
        deployment_name = element[0]
        jenkins_start_job_href = element[1]
        fileHtml.puts "<tr>"
        test_image, test_link_to_log, tooltip, destroyer_image, destroyer_link_to_log, notes, z_tooltip, job_number =
            get_deployment_states(deployment_name)
        generate_table_cell_image(fileHtml, @test_action_start_job_image, test_image, test_link_to_log,
                                  tooltip, destroyer_image, destroyer_link_to_log,
                                  deployment_name, jenkins_start_job_href, notes, z_tooltip, job_number)
        fileHtml.puts "</tr>"
      end

      fileHtml.puts "</table></object>"
    else
      fileHtml.puts "<center><h2>No Zombie Deployments Found</h2></center>"
      monkey_mood_image = @happy_monkey_image
    end

    # Add link to the sibling jobs report
    fileHtml.puts "<object><p><center>"
    jobs_report_uri = "rocketmonkey/#{@escaped_suite_prefix.downcase}/wipreport/index.html"
    fileHtml.puts "<a href='#{@amazon_url_prefix}/#{jobs_report_uri}' target=\"_blank\">Click here to view the Jobs Report</a>"
    fileHtml.puts "</center></object>"

    # Generate footer
    generate_report_footer_html(fileHtml, @suite_prefix, monkey_mood_image, false, false)

    # Close the file
    fileHtml.close()

    # Reformat the the html file contents
    reformat_html(html_file_name)

    # Upload the report to S3
    upload_report_to_s3(html_file_name, report_uri)

    # Display the report URL
    puts "Your report is available at #{@amazon_url_prefix}/#{report_uri}"

    # Remove the generated local file unless the user wants to keep it (fyi: useful for testing)
    File.delete html_file_name if not @leave
  end
end
