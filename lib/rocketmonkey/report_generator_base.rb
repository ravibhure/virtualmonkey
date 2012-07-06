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
require 'fog'
require 'tzinfo'
require 'cgi'
require 'tempfile'
# TBD: Need to finish up reformatting the html code but tidy is making semantic changes to the original code
#require 'tidy'

# RocketMonkey requires
require 'rocketmonkey_base'
require 'report_images'
require 'report_css'


########################################################################################################################
# ReportGeneratorBase "abstract" class
#
# This class has all the basic, reusable behavior for generating Rocket Monkey HTML reports.
########################################################################################################################
class ReportGeneratorBase < RocketMonkeyBase
  include ReportImages
  include ReportCss

  ######################################################################################################################
  # instance method: initialize
  ######################################################################################################################
  def initialize(version, csv_input_filename, refresh_rate_in_seconds, snapshot, leave,
      suppress_variable_data, truncate_troops, cloud_filter, generate_actions)
    super(version, suppress_variable_data, csv_input_filename, refresh_rate_in_seconds, truncate_troops, nil)

    # Initialize the ReportImages module
    initialize_images(snapshot)

    # Initialize the ReportCss module
    initialize_css()

    # Clean up the input path and make sure it has the trailing '/'
    # Here in the report generator we use what was the @output_file_path in the JenkinsJobGenerator
    # as the input file path. This came from the yaml file.
    @edited_input_file_path = edit_path(@output_file_path)

    @leave = leave
    @failure_report_regular_expressions = @config[:failure_report_regular_expressions]
    cloud_filter ||= ""
    @cloud_filter = cloud_filter.split(/ /)
    @cloud_filter.each { |element|
      raise "Cloud-Region #{element} not found in cloud_ids map in yaml file." if !@cloud_ids[element]
    }
    @generate_actions = generate_actions

    # Used for suppressing things like dates, times, computer names, etc. that vary from run-to-run and would break
    # the automated tests.
    @variable_data_suppressed = "[variable data suppressed]"

    # Set table cell font size
    @td_font_size = 2

    # Disable annoying [WARN] about bucket names
    Fog::Logger[:warning] = nil

    # Get the computer name and the date/time and random number for report name uniqueness if this is a snapshot report
    if @suppress_variable_data
      @computer_name = @pst_time_string = @variable_data_suppressed
      @date_time_random_number = "2012/05/16/15-21-59-18280945"
    else
      # Get the computer/server name
      @computer_name = `uname -n`.chop

      # Get the date and time and convert it to the PST timezone
      TZInfo::Country.get('US').zone_identifiers
      timezone = TZInfo::Timezone.get('America/Los_Angeles')
      pst_time = timezone.utc_to_local(Time.new.utc)
      @pst_time_string = "#{pst_time}".sub('UTC ', 'PST ')
      @date_time_random_number = pst_time.strftime(File.join("%Y", "%m", "%d", "%H-%M-%S-#{rand(100000000)}")) \
        if snapshot
    end

    @report_title = CGI.escapeHTML("#{@parsed_job_definition[@report_title_prefix_row][0].strip}")

    # Get the suite prefix from the first element
    @suite_prefix = @parsed_job_definition[@cloud_row][@server_template_column].strip

    # Escape the suite prefix
    @escaped_suite_prefix = URI.escape @suite_prefix

    @amazon_url_prefix = "http://s3.amazonaws.com/virtual_monkey"

    # No matches string used for regular expressions when there's no match found'
    @no_match_string = "[No Matches]"
  end



  ######################################################################################################################
  # instance method: upload_report_to_s3
  #
  # Based on the supplied inputs this function will upload the report to Amazon's S3
  ######################################################################################################################
  def upload_report_to_s3(file_name, uri)
    s3 = Fog::Storage.new(:provider => "AWS")
    file = File.open(file_name)
    s3.put_object("virtual_monkey", uri, file.read, {'x-amz-acl' => 'public-read', 'Content-Type' => 'html'})
    file.close()
  end



  ######################################################################################################################
  # instance method: generate_report_document_head_html
  #
  # Based on the supplied inputs this function will generate the report document head html
  ######################################################################################################################
  def generate_report_document_head_html(fileHtml, suite_prefix, generate_refresh_tag, destroyers)
    # Generate document head
    fileHtml.puts "<!DOCTYPE HTML SYSTEM>"
    fileHtml.puts "<html lang=\"en\">"
    fileHtml.puts "<head>"
    fileHtml.puts "<meta http-equiv=\"Content-Type\" content=\"text/html;charset=utf-8\">"
    if generate_refresh_tag
      fileHtml.puts "<meta http-equiv=\"refresh\" content=\"#{@refresh_rate_in_seconds}\">"
    end
    fileHtml.puts "<title>#{destroyers ? "Z_" : ""}#{CGI.escapeHTML(suite_prefix)}</title>"
    fileHtml.puts "<link rel=\"icon\" href=\"#{@happy_monkey_image}\" type=\"image/png\">"
    fileHtml.puts @style_sheet
    fileHtml.puts "</head>"
  end



  ######################################################################################################################
  # instance method: generate_report_document_body_start_html
  #
  # Based on the supplied inputs this function will generate the report document head html
  ######################################################################################################################
  def generate_report_document_body_start_html(fileHtml, report_title, report_title_postfix)
    # Generate body
    fileHtml.puts "<body>"
    fileHtml.puts "<div id=\"header\">"
    fileHtml.puts "<div id=\"logo\"><a href=\"http://my.rightscale.com/\" target=\"_blank\"><img src=\"#{@right_scale_logo_image}\" alt=\"rightscale logo\"></a>"
    fileHtml.puts "<span id=\"vmonk\">Rocket Monkey #{report_title} #{report_title_postfix}</span>"
    fileHtml.puts "</div>"
    fileHtml.puts "</div>"
    fileHtml.puts "<div id=\"report\">"
    fileHtml.puts "<font size=#{@td_font_size} face=\"sans-serif\" color='black'>"
  end



  ######################################################################################################################
  # instance method: generate_report_title_area_html
  #
  # Based on the supplied inputs this function will generate the report title area html
  ######################################################################################################################
  def generate_report_title_area_html(fileHtml, mail_failure_report, report_sub_title)
    if !mail_failure_report
      # Generate report title area table with rocket monkey image, title and current time (one row, two columns)
      fileHtml.puts "<object><table border='0' align='center' cellpadding = \"4\" cellspacing=\"0\" summary='none'>"
      fileHtml.puts "<tr><td><img src=\"#{@rocket_monkey_image}\" alt=\"monkey image\"></td>"
      fileHtml.puts "<td align='left'>"
    end
    fileHtml.puts "<h2>#{@report_title}#{report_sub_title}"
    if @cloud_filter.length > 0
      fileHtml.puts " #{@cloud_filter.inspect}</h2>"
    else
      fileHtml.puts "</h2>"
    end
    fileHtml.puts "<h3>#{@pst_time_string}</h3>"
    if !mail_failure_report
      fileHtml.puts "</td>"
      fileHtml.puts "</table></object>"
    end
  end



  ######################################################################################################################
  # instance method: generate_report_footer_html
  #
  # Based on the supplied inputs this function will generate the report footer html
  ######################################################################################################################
  def generate_report_footer_html(fileHtml, suite_prefix, monkey_mood_image, mail_failure_report, refresh_page)
    footer_string_1 = "Suite #{suite_prefix} - Account: #{@rightscale_account}, Chain: #{@chain}, Threshold: #{@threshold}"

    # Generate footer
    if mail_failure_report
      fileHtml.puts "<br>#{footer_string_1}<p>"
    else
      footer_string_2 = "Generated #{@pst_time_string} from #{@computer_name}. Powered by <a href='http://#{@jenkins_ip_address}:8080' target=\"_blank\">Jenkins</a>."
      footer_string_3 = "#{refresh_page ? "Page refreshes every #{@refresh_rate_in_seconds} seconds. " : ""}Copyright (c) 2010-2012 RightScale Inc. #{@version}"
      fileHtml.puts "</font></div><br><br>"
      fileHtml.puts "<div id=\"footer\">"
      fileHtml.puts "<span id=\"vmonkfooter\">#{footer_string_1}</span>"
      fileHtml.puts "<div id=\"monkey\">"
      fileHtml.puts ""
      fileHtml.puts "#{footer_string_2}<img src=\"#{monkey_mood_image}\" alt=\"monkey image\">"
      fileHtml.puts "<p>#{footer_string_3}"
      fileHtml.puts "</div>"
      fileHtml.puts "</div>"
      fileHtml.puts "</body>"
      fileHtml.puts "</html>"
    end
  end



  ######################################################################################################################
  # instance method: nbsp
  #
  # Based on the supplied inputs this function will return the escaped html space character
  # the specified number of times
  ######################################################################################################################
  def nbsp(repeat_times)
    return "&nbsp;" * repeat_times
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
  # instance method: create_html_report_output_file
  #
  # Based on the supplied inputs this function will create and open the html report file and return the file name and
  # file object. Note that this method will create a temporary file if @leave is false
  ######################################################################################################################
  def create_html_report_output_file(filename)
    if @leave
      html_file_name = filename
      fileHtml = File.new(html_file_name, "w")
    else
      fileHtml = Tempfile.new("rm_", "./")
      html_file_name = fileHtml.path()
    end
    puts "Temporary local html report file: \"#{html_file_name}\""
    return html_file_name, fileHtml
  end



  ######################################################################################################################
  # instance method: get_log_file_information
  #
  # Based on the supplied inputs this function will return the last line from the Jenkins console log if it exists
  # or and empty string if it doesn't. It also returns a link to that same log and the log as a string if it exists
  # or nil if it doesn't.
  ######################################################################################################################
  def get_log_file_information(current_build_log, path_to_current_jenkins_job, currentBuildNumber)
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
        link_to_log = "#{path_to_current_jenkins_job}/#{currentBuildNumber}/console"
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
  # instance method: look_for_first_regular_expression_match
  #
  # Based on the supplied inputs this function will search for a matching regular expression. If failure_report_array
  # is not nil, the resulting values will be pushed onto it.
  ######################################################################################################################
  def look_for_first_regular_expression_match(deployment_name, log_as_string, failure_report_array)
    # Since we have a failure we need to loop through the failure regular expressions and look for a single
    # match
    failure_match = false
    failure_results = []
    description = ""
    reference_href = ""
    server_template_error = true
    @failure_report_regular_expressions.each { |key, value|
      failure_results = log_as_string.scan(/#{key}/)
      if failure_results.length > 0
        description = value[0]
        reference_href = value[1]
        server_template_error = value[2]
        if failure_report_array != nil
          failure_report_array.push [deployment_name, failure_results, description, reference_href,
                                    server_template_error]
        end
        failure_match = true
        break
      end
    }
    return failure_match, failure_results, description, reference_href, server_template_error
  end


  ######################################################################################################################
  # instance method: reformat_html
  #
  # Based on the supplied inputs this function will reformat the supplied file in place.
  ######################################################################################################################
  def reformat_html(html_file)
    # TODO: Need to finish up reformatting the html code but tidy is making semantic changes to the original code
=begin
    begin
      Tidy.path = '/usr/lib/libtidy-0.99.so.0'
    rescue LoadError
      Tidy.path = '/usr/lib/libtidy.A.dylib'
    end
    html = IO.read(html_file)
    cleaned_up_html = Tidy.open(:show_warnings=>true) do |tidy|
      tidy.options.wrap = 0
      tidy.options.indent = 'auto'
      tidy.options.indent_attributes = false
      tidy.options.indent_spaces = 4
      tidy.options.vertical_space = false
      tidy.options.output_html = true
      tidy.options.char_encoding = 'utf8'

      cleaned_up_html = tidy.clean(html)
      puts tidy.errors
      puts tidy.diagnostics

      cleaned_up_html
    end
    File.open(html_file, 'w') {|f| f.write(cleaned_up_html) }
=end
  end
end
