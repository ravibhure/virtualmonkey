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

# RocketMonkey requires
require 'report_generator_base'
require 'report_images'
require 'report_css'


########################################################################################################################
# ReportGenerator class
########################################################################################################################
class ReportGenerator < ReportGeneratorBase

  ######################################################################################################################
  # instance method: initialize
  ######################################################################################################################
  def initialize(version, csv_input_filename, refresh_rate_in_seconds, snapshot, leave,
      suppress_variable_data, destroyers, truncate_troops, cloud_filter, generate_actions, mail_failure_report)
    super(version, csv_input_filename, refresh_rate_in_seconds, snapshot, leave,
          suppress_variable_data, truncate_troops, cloud_filter, generate_actions)

    @snapshot = snapshot
    @destroyers = destroyers
    @mail_failure_report = mail_failure_report
    @destroyer_sub_title = @destroyers ? "<font color='red'> [DESTROYERS]</font>" : ""
    @report_sub_title = "#{destroyers ? "[DESTROYERS] " : ""}#{snapshot ? "Snapshot" : "Work-In-Progress"}"
  end



  ######################################################################################################################
  # instance method: generate_table_cell
  ######################################################################################################################
  def generate_table_cell(fileHtml, bgcolor, font_color, contents, monkey_result)
    if monkey_result.length > 0
      fileHtml.puts "<td bgcolor='#{bgcolor}'><center>"
      fileHtml.puts "<font color='#{font_color}' size = #{@td_font_size}><a href='#{monkey_result}' target=\"_blank\">#{contents}</a></font>"
      fileHtml.puts "</center></td>"
    else
      fileHtml.puts "<td bgcolor='#{bgcolor}'><center>"
      fileHtml.puts "<font color='#{font_color}' size = #{@td_font_size}>#{contents}</font>"
      fileHtml.puts "</center></td>"
    end
  end



  ######################################################################################################################
  # instance method: generate_table_cell_image
  ######################################################################################################################
  def generate_table_cell_image(fileHtml, image_name, monkey_result, title, action_image_name, action_href, generate_actions)
    action_html = " <a href=\"#{action_href}\"><img src=\"#{action_image_name}\" alt=\"image\"></a>"
    if monkey_result.length > 0
      fileHtml.puts "<td><center>"
      fileHtml.puts "<a href=\"#{monkey_result}\" target=\"_blank\"><img src=\"#{image_name}\" alt=\"image\"#{title.length > 0 ? " title='#{CGI.escapeHTML(title)}'" : ""}></a>"
      if generate_actions && action_image_name != nil && action_href != nil
        fileHtml.puts action_html
      end
      fileHtml.puts "</center></td>"
    else
      fileHtml.puts "<td><center>"
      fileHtml.puts "<img src=\"#{image_name}\" alt=\"image\">"
      if generate_actions && action_image_name != nil && action_href != nil
        fileHtml.puts action_html
      end
      fileHtml.puts "</center></td>"
    end
  end



  ######################################################################################################################
  # instance method: generate_statistics_table_row
  ######################################################################################################################
  def generate_statistics_table_row(fileHtml, image_name, title, count, percentage)
    fileHtml.puts "<tr>"
    if image_name != nil
      generate_table_cell_image fileHtml, image_name, "", "", nil, nil, @generate_actions
    else
      fileHtml.puts "<td>&nbsp;</td>"
    end
    if (title =~ /Failed/ || title == "Aborted") && count > 0
      font = "<font color='red' size = '#{@td_font_size}'>"
    else
      font = "<font size = '#{@td_font_size}'>"
    end
    fileHtml.puts "<td>&nbsp;</td>"
    fileHtml.puts "<td align='left'>#{font}#{title}</font><td>"
    fileHtml.puts "<td>"
    fileHtml.puts "<td align='right'>#{font}#{count}</font>"
    fileHtml.puts "</td>"
    fileHtml.puts "<td>&nbsp;</td>"
    fileHtml.puts "<td>"
    fileHtml.puts "<td align='right'>#{font}#{percentage}</font>"
    fileHtml.puts "</td>"
    fileHtml.puts "</tr>"
  end



  ######################################################################################################################
  # instance method: generate_statistics_table
  #
  # Based on the supplied inputs this function will generate the statistics table as html
  ######################################################################################################################
  def generate_statistics_table(fileHtml, has_not_run_count, running_count,
      success_count, other_failure_count, server_template_failure_count, aborted_count, not_supported_count,
      not_supported_yet_count, disabled_count, question_count)
    # Generate stats table
    total_count = success_count + other_failure_count + server_template_failure_count + aborted_count + running_count +
        has_not_run_count + question_count
    fileHtml.puts "<object><p><table border=\"0\" align=\"center\" cellpadding = \"0\" cellspacing=\"0\" summary='none'>"
    fileHtml.puts "<caption><b>Test Statistics</b></caption>"
    generate_statistics_table_row fileHtml, @test_has_not_run_yet_image, "Not Run", has_not_run_count,
                                  "#{sprintf('%03.2f', (has_not_run_count.to_f / total_count.to_f) * 100.0)}%"
    generate_statistics_table_row fileHtml, @test_running_image, "Running", running_count,
                                  "#{sprintf('%03.2f', (running_count.to_f / total_count.to_f) * 100.0)}%"
    generate_statistics_table_row fileHtml, @test_passed_image, "Passed", success_count,
                                  "#{sprintf('%03.2f', (success_count.to_f / total_count.to_f) * 100.0)}%"
    generate_statistics_table_row fileHtml, @server_template_test_failed_image, "Server Template Failed",
                                  server_template_failure_count,
                                  "#{sprintf('%03.2f', (server_template_failure_count.to_f / total_count.to_f) * 100.0)}%"
    generate_statistics_table_row fileHtml, @other_test_failed_image, "Other Failed", other_failure_count,
                                  "#{sprintf('%03.2f', (other_failure_count.to_f / total_count.to_f) * 100.0)}%"
    generate_statistics_table_row fileHtml, @test_aborted_image, "Aborted", aborted_count,
                                  "#{sprintf('%03.2f', (aborted_count.to_f / total_count.to_f) * 100.0)}%"
    generate_statistics_table_row fileHtml, @test_not_supported_image, "Not Supported", not_supported_count,
                                  "&nbsp;"
    generate_statistics_table_row fileHtml, @test_not_supported_yet_image, "Not Supported Yet", not_supported_yet_count,
                                  "&nbsp;"
    generate_statistics_table_row fileHtml, @test_disabled_image, "Disabled", disabled_count, "&nbsp;"

    if question_count > 0
      generate_statistics_table_row fileHtml, @test_question_image, "Missing Jenkins config.xml", disabled_count,
                                  "#{sprintf('%03.2f', (question_count.to_f / total_count.to_f) * 100.0)}%"
    end

    generate_statistics_table_row fileHtml, nil, "Total", total_count + not_supported_count + not_supported_yet_count +
        disabled_count, "100.00%"
    fileHtml.puts "</table></object>"
  end



  ######################################################################################################################
  # instance method: generate_failures_summary_report_details
  #
  # Based on the supplied inputs this function will generate the failures summary report details in html
  ######################################################################################################################
  def generate_failures_summary_report_details(fileHtml, failure_report_array, deployment_error_link_map,
      mail_failure_report)
    fileHtml.puts "<object>" if !mail_failure_report
    if failure_report_array.length == 0
      fileHtml.puts "<h2>#{nbsp(2)}All Tests Passed</h2>"
    else
      # Report on failures sorted by matched expression
      fileHtml.puts "<h2>#{nbsp(2)}Results Grouped by Matched Expression</h2>"
    end

    group_title = ""
    for i in 0..failure_report_array.length - 1
      # Display the group title if there is a report break
      if group_title != failure_report_array[i][1]
        fileHtml.puts "<p>" if i != 0
        fileHtml.puts "<h3>#{nbsp(7)}<img src=\"#{failure_report_array[i][4] ? @server_template_test_failed_image : @other_test_failed_image}\" alt=\"image\">#{CGI.escapeHTML(failure_report_array[i][1][0].strip)}"

        # If there is a description display it and if there is a link make the description link to it
        description = failure_report_array[i][2].strip
        link = failure_report_array[i][3].strip
        if description != ""
          if link != ""
            fileHtml.puts "#{nbsp(1)}<a href='#{link}' target=\"_blank\"><font color = 'brown'>[<u>#{description}</u>]</font></a>"
          else
            fileHtml.puts "#{nbsp(1)}<font color = 'brown'>[#{description}]</font>"
          end
        end

        fileHtml.puts "</h3>\n"

        group_title = failure_report_array[i][1]
      end

      # Display the matched regex
      fileHtml.puts ""
      fileHtml.puts "<font size = #{@td_font_size}>#{nbsp(12)}<a href='#{deployment_error_link_map[failure_report_array[i][0]]}' target=\"_blank\">#{failure_report_array[i][0]}</a></font><br>"
    end

    # Display the regular expressions
    fileHtml.puts "<br>"
    fileHtml.puts "<h2>#{nbsp(2)}Regular Expressions Used</h2>"
    @failure_report_regular_expressions.sort.each { |key, value|
      fileHtml.puts "<font size = #{@td_font_size}>#{nbsp(6)}#{CGI.escapeHTML(key)}</font><br>\n"
    }

    fileHtml.puts "</object>" if !mail_failure_report
  end



  ######################################################################################################################
  # instance method: generate_reports
  #
  # Based on the supplied inputs this function will generate the Jenkins reports in html format
  ######################################################################################################################
  def generate_reports()
    # Initialize the failure_report_array
    failure_report_array = []

    if @snapshot
      report_uri = "rocketmonkey/#{@destroyers ? "Z_" : ""}#{@escaped_suite_prefix.downcase}/#{@date_time_random_number}/#{@generate_actions ? "action/" : ""}index.html"
      jobs_report_uri = "rocketmonkey/#{@escaped_suite_prefix.downcase}/#{@date_time_random_number}/#{@generate_actions ? "action/" : ""}index.html"
      destroyers_report_uri = "rocketmonkey/Z_#{@escaped_suite_prefix.downcase}/#{@date_time_random_number}/#{@generate_actions ? "action/" : ""}index.html"
      failure_report_uri = "rocketmonkey/#{@destroyers ? "Z_" : ""}#{@escaped_suite_prefix.downcase}/#{@date_time_random_number}/failures.html"
    else
      report_uri = "rocketmonkey/#{@destroyers ? "Z_" : ""}#{@escaped_suite_prefix.downcase}/wipreport/#{@generate_actions ? "action/" : ""}index.html"
      jobs_report_uri = "rocketmonkey/#{@escaped_suite_prefix.downcase}/wipreport/#{@generate_actions ? "action/" : ""}index.html"
      destroyers_report_uri = "rocketmonkey/Z_#{@escaped_suite_prefix.downcase}/wipreport/#{@generate_actions ? "action/" : ""}index.html"
      failure_report_uri = "rocketmonkey/#{@destroyers ? "Z_" : ""}#{@escaped_suite_prefix.downcase}/wipreport/failures.html"
    end

    #
    # Generate main report (can be Snapshot or WIP and within that jobs or destroyers)
    #
    html_file_name, fileHtml = create_html_report_output_file(
        "#{@destroyers ? "Z_" : ""}#{File.basename(@csv_input_filename, ".*") + "#{@snapshot ? "Snapshot" : "Wip"}#{@generate_actions ? "Action" : ""}.html"}")

    # Generate document head
    generate_report_document_head_html(fileHtml, @suite_prefix, !@snapshot && !@generate_actions, @destroyers)

    # Generate body
    generate_report_document_body_start_html(fileHtml, @report_sub_title, "Report")

    # Generate report title area table with rocket monkey image, title and current time (one row, two columns)
    generate_report_title_area_html(fileHtml, false, @destroyer_sub_title)

    # Generate matrix-based job table
    fileHtml.puts "<object><table rules='rows' border='0' align='center' cellpadding = \"2\" cellspacing=\"0\" summary='none'>"

    # Generate the header row with titles
    fileHtml.puts "<tr><th bgcolor = '#CCCC99'><font size = #{@td_font_size}><br>Server<br>Template</font></th><th bgcolor = '#CCCC99'><font size = #{@td_font_size}><br><br>Troop</font>#{@show_job_numbers ? "<th bgcolor = '#CCCC99'><font size = #{@td_font_size}><br>Job<br>Number</font></th>" : ""}"
    for j in @start_column..@parsed_job_definition[@cloud_row].length - 1
      # Split out the cloud, region and image which are all separated by newlines
      split_cloud_region_image_array, raw_cloud_name, cloud_lookup_name, cloud_name, region_name, image_name \
        = get_cloud_variables(j)

      # Skip this column if this cloud/region should be filtered
      if !cloud_in_filter?(cloud_lookup_name)
        next
      end

      # Check for cloud chain and threshold overrides so we can flag the column header with a color that stands out.
      cloud_chain_or_threshold_override = false
      for split_column_parameters_index in 3..split_cloud_region_image_array.length - 1
        split_column_parameters_array = split_cloud_region_image_array[split_column_parameters_index].split(/:/)

        # Enforce <key>:<value> semantics
        if split_column_parameters_array.length != 2
          raise "Invalid format for optional column parameter found in \"#{split_cloud_region_image_array[split_column_parameters_index]}\", should be in the form <key>:<value> at row: #{i + 1}, column: #{j + 1} in #{@csv_input_filename}"
        end

        if split_column_parameters_array[0].upcase == "CHAIN"
          cloud_chain_or_threshold_override = true
        elsif split_column_parameters_array[0].upcase == "THRESHOLD"
          cloud_chain_or_threshold_override = true
        end
      end

      if cloud_chain_or_threshold_override
        bg_color = "#66CC66"
      else
        bg_color = "#CCCC99"
      end
      fileHtml.puts "<th bgcolor = '#{bg_color}'><font size = #{@td_font_size}>#{raw_cloud_name}<br>#{region_name}<br>#{image_name}</font></th>"
    end
    fileHtml.puts "</tr>"

    # Initialize statistics report counters
    has_not_run_count = success_count = other_failure_count = server_template_failure_count = aborted_count = 0
    running_count = not_supported_count = not_supported_yet_count = disabled_count = question_count = 0

    # Default the monkey image to all tests passed (happy)
    monkey_mood_image = @happy_monkey_image

    # Setup deployment_error_link_map to hold deployment link to error report pairs used for the failure summary report.
    deployment_error_link_map = {}

    # Traverse rows
    for i in @start_row..@parsed_job_definition.length - 1

      # Parse out the server template name(s)
      raw_server_template_list = @parsed_job_definition[i][@server_template_column]
      raise "Server template name not found in row #{i} in #{@csv_input_filename}" if raw_server_template_list == nil
      server_template_names = raw_server_template_list.split(/\n/)
      edited_server_template = ""
      for ii in 0..server_template_names.length - 1
        edited_server_template += (edited_server_template.length > 0 ? "<br>" + server_template_names[ii] :
            server_template_names[ii])
      end

      # Compute a unique job number
      job_number = get_job_order_number_as_string(i)

      # Truncate the troop name if needed
      if @truncate_troops > -1 && @parsed_job_definition[i][@troop_column].length > @truncate_troops
        show_ellipses = true
      else
        show_ellipses = false
      end
      edited_troop_name = @truncate_troops < 0 ? @parsed_job_definition[i][@troop_column] : @parsed_job_definition[i][@troop_column][0..@truncate_troops - 1] + (show_ellipses ? "..." : "")
      fileHtml.puts "<tr><td bgcolor = '#FFFFCC'><font size = #{@td_font_size}><b>#{edited_server_template}</b></font><td bgcolor = '#FFFFCC'><font size = #{@td_font_size}#{show_ellipses ? " title='#{CGI.escapeHTML(@parsed_job_definition[i][@troop_column])}'" : ""}><b>#{CGI.escapeHTML(edited_troop_name)}</b></font>"
      if @show_job_numbers
        fileHtml.puts "<td align = 'center' bgcolor = '#FFFFCC'><font size = #{@td_font_size}><b>#{job_number}</b></font>"
      end
      fileHtml.puts "</td>"

      # Traverse columns
      for j in @start_column..@parsed_job_definition[i].length - 1

        element = @parsed_job_definition[i][j]

        # Strip off all leading and trailing spaces
        element.strip! if element != nil

        # Parse out the cloud variables
        split_cloud_region_image_array, raw_cloud_name, cloud_lookup_name, cloud_name, region_name, image_name \
          = get_cloud_variables(j)

        # Check to see if the column has been completely disabled
        if cloud_in_filter?(cloud_lookup_name) && !is_cloud_column_enabled?(split_cloud_region_image_array)
          # Show cell for "Not Supported" and skip the rest of the processing for this element
          generate_table_cell_image fileHtml, @test_disabled_image, "", "", nil, nil, @generate_actions
          disabled_count += 1
          next
        end

        # Only generate the report cell if this is a normal job element
        if is_job_element?(element)

          # Get cloud ID from the lookup name
          cloud_id = get_cloud_id(cloud_lookup_name)

          # Skip this element if this cloud/region should be filtered
          if !cloud_in_filter?(cloud_lookup_name)
            next
          end

          # The row "i" header has the troop name so get that
          troop_name = @parsed_job_definition[i][@troop_column]

          # Assemble the input folder name
          suite_name = @suite_prefix + "_#{cloud_name}" + "_" + image_name
          deployment_name = "#{@destroyers ? "Z_" : ""}" + suite_name + "_#{job_number}" + "_" + troop_name
          input_folder_path = @edited_input_file_path + deployment_name

          # Validate the Jenkins job for this element
          if !validate_jenkins_folder(input_folder_path)
            generate_table_cell_image fileHtml, @test_question_image, "", "", nil, nil, false
            question_count += 1
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

          # Save path to current Jenkins job
          path_to_current_jenkins_job = "http://#{@jenkins_ip_address}:8080/job/#{deployment_name}"

          # Parse the log file if it exists to save off the information
          last_line, link_to_log, log_as_string = get_log_file_information(current_build_log,
                                                                           path_to_current_jenkins_job,
                                                                           currentBuildNumber)

          # Save off the deployment and error report link to be used later to generate the
          # failure summary report.
          deployment_error_link_map[deployment_name] = link_to_log

          # if generate we need to actions, then build the action hrefs
          if @generate_actions
            action_start_job_href = "#{path_to_current_jenkins_job}/build?delay=0sec"
            action_stop_job_href = "#{path_to_current_jenkins_job}/#{currentBuildNumber}/stop"
          else
            action_start_job_href = nil
            action_stop_job_href = nil
          end

          # Now work through the known build scenarios and if we don't find any of those in the log file we are "running"
          if last_line == ""
            generate_table_cell_image fileHtml, @test_has_not_run_yet_image, "", "", @test_action_start_job_image,
                                      action_start_job_href, @generate_actions
            has_not_run_count += 1

          elsif last_line == "Finished: SUCCESS"
            generate_table_cell_image fileHtml, @test_passed_image, link_to_log, "", @test_action_start_job_image,
                                      action_start_job_href, @generate_actions
            success_count += 1

          elsif last_line == "Finished: FAILURE"
            monkey_mood_image = @pissed_off_monkey_image


            # Since we have a failure we need to loop through the failure regular expressions and look for the first
            # match
            failure_match, failure_results, description, reference_href, server_template_error =
                look_for_first_regular_expression_match(deployment_name, log_as_string, failure_report_array)

            if !failure_match
              failure_report_array.push [deployment_name, [@no_match_string], description, reference_href,
                                         server_template_error]
            end

            generate_table_cell_image fileHtml, server_template_error ? @server_template_test_failed_image : @other_test_failed_image,
                                      link_to_log,
                                      (failure_match ? (description.length > 0 ? description : failure_results[0]) : @no_match_string),
                                      @test_action_start_job_image, action_start_job_href, @generate_actions
            if server_template_error
              server_template_failure_count += 1
            else
              other_failure_count += 1
            end

          elsif last_line == "Finished: ABORTED"
            generate_table_cell_image fileHtml, @test_aborted_image, link_to_log, "", @test_action_start_job_image,
                                      action_start_job_href, @generate_actions
            monkey_mood_image = @pissed_off_monkey_image
            aborted_count += 1

          else
            # "Running"
            generate_table_cell_image fileHtml, @test_running_image, link_to_log, "", @test_action_stop_job_image,
                                      action_stop_job_href, @generate_actions
            running_count += 1
          end

        elsif is_not_supported_element?(element)
          # Only include this element if this cloud/region is not filtered
          if cloud_in_filter?(cloud_lookup_name)
            # Show cell for "Not Supported"
            generate_table_cell_image fileHtml, @test_not_supported_image, "", "", nil, nil, @generate_actions
            not_supported_count += 1
          end

        elsif is_not_supported_yet_element?(element)
          # Only include this element if this cloud/region is not filtered
          if cloud_in_filter?(cloud_lookup_name)
            # Show cell for "Not Supported"
            generate_table_cell_image fileHtml, @test_not_supported_yet_image, "", "", nil, nil, @generate_actions
            not_supported_yet_count += 1
          end

        elsif is_disabled_element?(element)
          # Only include this element if this cloud/region is not filtered
          if cloud_in_filter?(cloud_lookup_name)
            # Show cell for "Not Supported"
            generate_table_cell_image fileHtml, @test_disabled_image, "", "", nil, nil, @generate_actions
            disabled_count += 1
          end

        else
          raise_invalid_element_exception(element, i, j)
        end
      end
      fileHtml.puts "</tr>"
    end
    fileHtml.puts "</table></object>"

    # Add links to the sibling report (jobs or destroyers) if we aren't generating a snapshot.
    if !@snapshot
      fileHtml.puts "<object><p><center>"
      if !@destroyers
        fileHtml.puts "<a href='#{@amazon_url_prefix}/#{destroyers_report_uri}' target=\"_blank\">Click here to view the Destroyers Report</a>"
      else
        fileHtml.puts "<a href='#{@amazon_url_prefix}/#{jobs_report_uri}' target=\"_blank\">Click here to view the Jobs Report</a>"
      end
      fileHtml.puts "</center></object>"
    end

    # Add link to the sibling report (failure summary report) if there are any failures.
    if other_failure_count + server_template_failure_count > 0
      fileHtml.puts "<object><p><center>"
      fileHtml.puts "<a href='#{@amazon_url_prefix}/#{failure_report_uri}' target=\"_blank\">Click here to view the Failures Summary Report</a>"
      fileHtml.puts "</center></object>"
    end

    if @snapshot
      # Generate stats table
      generate_statistics_table(fileHtml, has_not_run_count, running_count,
                                success_count, other_failure_count, server_template_failure_count,
                                aborted_count, not_supported_count, not_supported_yet_count, disabled_count,
                                question_count)
    elsif @show_wip_statistics_table
      # Generate stats table
      generate_statistics_table(fileHtml, has_not_run_count, running_count,
                                success_count, other_failure_count, server_template_failure_count,
                                aborted_count, not_supported_count, not_supported_yet_count, disabled_count,
                                question_count)
    end

    # Generate footer
    generate_report_footer_html(fileHtml, @suite_prefix, monkey_mood_image, false, !@snapshot && !@generate_actions)

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

    #
    # Now generate the failure summary report (can be Snapshot or WIP and within that jobs or destroyers)
    #
    html_file_name, fileHtml = create_html_report_output_file("#{@destroyers ? "Z_" : ""}failures_summary_#{@snapshot ? "snapshot" : "WIP"}#{@generate_actions ? "Action" : ""}_report.html")

    # Generate document head
    generate_report_document_head_html(fileHtml, @suite_prefix, !@snapshot && !@generate_actions, @destroyers)

    # Generate body
    generate_report_document_body_start_html(fileHtml, @report_sub_title, "Failure Summary Report")

    # Generate report title area table with rocket monkey image, title and current time (one row, two columns)
    generate_report_title_area_html(fileHtml, false, @destroyer_sub_title)

    # Generate stats table
    generate_statistics_table(fileHtml, has_not_run_count, running_count,
                              success_count, other_failure_count, server_template_failure_count,
                              aborted_count, not_supported_count, not_supported_yet_count, disabled_count,
                              question_count)

    # Sort the failure report array by matched expression and then deployment
    failure_report_array.sort! { |a, b| (a[1] <=> b[1]).nonzero? || (a[0] <=> b[0]) }

    # Generate the failures summary report details
    generate_failures_summary_report_details(fileHtml, failure_report_array, deployment_error_link_map, false)

    # Generate footer
    generate_report_footer_html(fileHtml, @suite_prefix, monkey_mood_image, false, !@snapshot && !@generate_actions)

    # Close the file
    fileHtml.close()

    # Reformat the the html file contents
    reformat_html(html_file_name)

    # Upload the report to S3
    upload_report_to_s3(html_file_name, failure_report_uri)

    # Display the report URL
    puts "Your failures summary report is available at #{@amazon_url_prefix}/#{failure_report_uri}"

    # Remove the generated local file unless the user wants to keep it (fyi: useful for testing)
    File.delete html_file_name if not @leave


    #
    # Generate email if desired
    #

    # email and email the failures summary report if desired
    if @mail_failure_report
      html_file_name, fileHtml = create_html_report_output_file("#{@destroyers ? "Z_" : ""}email_failures_summary_#{@snapshot ? "snapshot" : "WIP"}_report.html")

      # Generate a title and related information
      generate_report_title_area_html(fileHtml, true, @destroyer_sub_title)

      # Generate a link to the jobs report
      fileHtml.puts "<p><a href='#{@amazon_url_prefix}/#{jobs_report_uri}' target=\"_blank\">Click here to view the Associated Jobs Report</a></p>"

      # Generate stats table
      generate_statistics_table(fileHtml, has_not_run_count, running_count,
                                success_count, other_failure_count, server_template_failure_count,
                                aborted_count, not_supported_count, not_supported_yet_count, disabled_count,
                                question_count)

      # Generate the failures summary report details
      generate_failures_summary_report_details(fileHtml, failure_report_array, deployment_error_link_map, true)

      # Generate footer
      generate_report_footer_html(fileHtml, @suite_prefix, monkey_mood_image, true, !@snapshot && !@generate_actions)

      # Close the file
      fileHtml.close()

      # Reformat the the html file contents
      reformat_html(html_file_name)

      # Now send the email
      email_from = @email_from
      email_to = @email_to
      report_title = "#{@report_title} #{@destroyers ? "[DESTROYERS] " : ""}#{@snapshot ? "Snapshot" : "Work-In-Progress"} Test Results"
      mail = Mail.new do
        from email_from
        to email_to
        subject report_title

        html_part do
          content_type 'text/html; charset=UTF-8'
          body "#{File.open(html_file_name, 'rb') { |f| f.read }}"
        end
      end
      mail.delivery_method :sendmail
      mail.deliver!

      # Remove the generated local file unless the user wants to keep it (fyi: useful for testing)
      File.delete html_file_name if not @leave
    end
  end
end
