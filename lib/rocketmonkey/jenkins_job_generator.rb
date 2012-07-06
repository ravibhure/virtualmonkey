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
require 'builder'
require 'fileutils'

# RocketMonkey requires
require 'rocketmonkey_base'


########################################################################################################################
# JenkinsJobGenerator class #
########################################################################################################################
class JenkinsJobGenerator < RocketMonkeyBase

  ######################################################################################################################
  # instance method: initialize
  ######################################################################################################################
  def initialize(version, csv_input_filename, refresh_rate_in_seconds, force, generate_tabs, truncate_troops,
      failure_report_run_time)
    super(version, false, csv_input_filename, refresh_rate_in_seconds, truncate_troops, failure_report_run_time)

    @force = force
    @generate_tabs = generate_tabs
  end



  ######################################################################################################################
  # instance method: generate_jenkins_list_view_as_xml
  #
  # Based on the supplied inputs this function will generate a Jenkins List View element
  # in the XML format Jenkins expects.
  ######################################################################################################################
  def generate_jenkins_list_view_as_xml(output_file, name, regex, generate_comparator_reference)
    # Generate the XML
    xml_output = ""
    xml = Builder::XmlMarkup.new(:target => xml_output, :indent => 2)

    xml.listView {
      xml << "<owner class=\"hudson\" reference=\"../../..\"/>\n"
      xml.name name
      xml.filterExecutors false
      xml.filterQueue false
      xml << "<properties class=\"hudson.model.View$PropertyList\"/>\n"
      xml << "<jobNames class=\"tree-set\">\n"
      if generate_comparator_reference
        xml << "<comparator class=\"hudson.util.CaseInsensitiveComparator\" reference=\"../../../listView/jobNames/comparator\"/>\n"
      else
        xml << "<comparator class=\"hudson.util.CaseInsensitiveComparator\"/>\n"
      end
      xml << "</jobNames>\n"
      xml.jobFilters
      xml.columns {
        xml << "<hudson.views.StatusColumn/>\n"
        xml << "<hudson.views.BuildButtonColumn/>\n"
        xml << "<hudson.views.JobColumn/>\n"
        xml << "<hudson.views.LastSuccessColumn/>\n"
        xml << "<hudson.views.LastFailureColumn/>\n"
        xml << "<hudson.views.LastDurationColumn/>\n"
        xml << "<hudson.views.WeatherColumn/>\n"
      }
      xml.includeRegex regex
    }
    output_file.puts(xml_output)
  end



  ######################################################################################################################
  # instance method: update_jenkins_master_config
  #
  # Based on the supplied inputs this function will generate the Jenkins RM-Cloud-Image tabs and the RM-Util
  # tab in the XML format Jenkins expects.
  ######################################################################################################################
  def update_jenkins_master_config()
    # Clean up the output path and make sure it has the trailing '/' and go up a level to where the master
    # config XML file is.
    edited_output_file_path = edit_path(@output_file_path) + "../"

    input_file_name = "#{edited_output_file_path}config.xml.bak"
    output_file_name = "#{edited_output_file_path}config.xml"

    # Rename config.xml to config.xml.bak
    File.rename(output_file_name, input_file_name)

    # Open config.xml.bak in read mode
    input_file = File.open(input_file_name)

    # Open config.xml in write mode
    output_file = File.open(output_file_name, "w")

    # Copy everything until right after the </hudson.model.AllView> element
    while (line = input_file.gets)
      # Write the line out to config.xml
      output_file.puts(line)

      # If the line contains the </hudson.model.AllView> element, break of of this loop
      break if line =~ /[\s]*<\/hudson.model.AllView\>/
    end

    if @generate_tabs
      # Generate all new (suite, cloud, image) List View xml elements based on the input spreadsheet to the new
      # config.xml. Get the suite prefix from the first element.
      suite_prefix = @parsed_job_definition[@cloud_row][@server_template_column].strip

      # Generate the Rocket Monkey RM-Utils Jenkins tab
      generate_jenkins_list_view_as_xml(output_file, "RM-Utils", "#{suite_prefix}_000_*.*", false)

      for j in @start_column..@parsed_job_definition[@cloud_row].length - 1

        # Strip off all leading and trailing spaces
        element = @parsed_job_definition[@cloud_row][j].strip

        # Parse out the cloud variables
        split_cloud_region_image_array, raw_cloud_name, cloud_lookup_name, cloud_name, region_name, image_name \
          = get_cloud_variables(j)

        # Check to see if the column has been completely disabled
        if is_cloud_column_enabled?(split_cloud_region_image_array)
          # Only generate the list view if this column is enabled
          generate_jenkins_list_view_as_xml(output_file, "RM-#{cloud_name}-#{image_name}",
                                            "[Z_]*#{suite_prefix}_#{cloud_name}_#{image_name}*.*", true)
        end
      end
    end

    # Skip past any previous <listView> elements and then write out the remaining elements
    skip_old_list_views = @generate_tabs
    while (line = input_file.gets)
      if !skip_old_list_views
        output_file.puts(line)
      else
        # If the line contains the closing </Views> element, write out the line and set skip_old_list_views
        # to false to ensure we copy the rest of the remaining config file over.
        if line =~ /[\s]*<\/views>/
          output_file.puts(line)
          skip_old_list_views = false
        end
      end
    end

    # All done, close the files
    input_file.close
    output_file.close
  end



  ######################################################################################################################
  # instance method: format_mci_override
  #
  # Based on the supplied inputs this function will return the correctly formatted MCI override href.
  ######################################################################################################################
  def format_mci_override(mci_override)
    return "-m \"http://my.rightscale.com/api/acct/#{@rightscale_account}/multi_cloud_images/#{mci_override}\""
  end



  ######################################################################################################################
  # instance method: generate_jenkins_virtual_monkey_jobs_as_xml
  #
  # Based on the supplied inputs this function will generate a Virtual Monkey Jenkins job and its associated destroyer
  # job in the XML format Jenkins expects.
  ######################################################################################################################
  def generate_jenkins_virtual_monkey_jobs_as_xml(suite_name, cloud_name, cloud_id, image, cloud_timeout, job_number,
      troop, element_filename, element_file_array, mci_override, next_job_number, next_troop, test_name,
      test_name_override, restrict_to_jenkins_instance, image_regex, cloud_chain_override, cloud_threshold_override,
      cloud_resume_override)
    full_troop_file_name = @troop_path + troop.split(/__/)[0] + ".json"
    output_folder_name = suite_name + "_#{job_number}" + "_" + troop

    # Handle any entries in the element_file_array
    specific_tests_to_run = ""
    mci_override ||= ""

    if mci_override != ""
      mci_override = format_mci_override(mci_override)
    end

    # If the test name was included in the row name, set specific_tests_to_run to that name
    if test_name_override
      specific_tests_to_run = "-t \"#{test_name}\""
    end

    for i in 0..element_file_array.length - 1
      element_file_array_entry = element_file_array[i].chomp.strip
      if element_file_array_entry[0, 1] == "#"
        # Skip this comment line
      elsif element_file_array_entry[0..2].upcase == "-T " && element_file_array_entry.length > 5
        if test_name_override
          warn "Test name \"#{test_name}\" was specified in row \"#{troop}\" so \"#{element_file_array_entry}\" found in file \"#{element_filename}\" ignored.\a"
        else
          specific_tests_to_run += (specific_tests_to_run.length > 0 ? " " : "") + element_file_array_entry
        end
      elsif element_file_array_entry[0..2].upcase == "-M " && element_file_array_entry.length > 4
        if mci_override.length > 0
          raise "Multiple MCI Override (-m) entries found \"#{element_file_array_entry}\" in \"#{element_filename}\""
        end
        mci_override = format_mci_override(element_file_array_entry[3..element_file_array_entry.length - 1])
      else
        raise "Invalid element file entry found \"#{element_file_array_entry}\" in \"#{element_filename}\""
      end
    end

    if cloud_timeout != nil
      timeout_command_line_flags = "-u \"booting_timeout=#{cloud_timeout}\" \"completed_timeout=#{cloud_timeout}\" \"default_timeout=#{cloud_timeout}\" \"error_timeout=#{cloud_timeout}\" \"failed_timeout=#{cloud_timeout}\" \"inactive_timeout=#{cloud_timeout}\" \"operational_timeout=#{cloud_timeout}\" \"snapshot_timeout=#{cloud_timeout}\" \"stopped_timeout=#{cloud_timeout}\" \"terminated_timeout=#{cloud_timeout}\""
    else
      timeout_command_line_flags = ""
    end

    # If we have a cloud-based chain override, use it instead of the default chain
    if cloud_chain_override != nil
      chain = cloud_chain_override
    else
      chain = @chain
    end

    # If we have a cloud-based threshold override, use it instead of the default threshold
    if cloud_threshold_override != nil
      threshold = cloud_threshold_override
    else
      threshold = @threshold
    end

    # If we have a cloud-based resume override, use it instead of the default resume value
    if cloud_resume_override != nil
      resume = cloud_resume_override
    else
      resume = @resume
    end

    # Generate main job XML
    xml_output = ""
    xml = Builder::XmlMarkup.new(:target => xml_output, :indent => 2)
    xml.instruct! :xml, :version => "1.0", :encoding => "UTF-8"

    xml.project {
      xml.actions
      xml.description {}
      xml.keepDependencies false
      xml.properties
      xml << "  <"
      xml.text! "scm class" "=\"hudson.scm.NullSCM\""
      xml << "/>\n"
      if restrict_to_jenkins_instance != nil
        xml.assignedNode restrict_to_jenkins_instance
        xml.canRoam false
      else
        xml.canRoam true
      end
      xml.disabled false
      xml.blockBuildWhenDownstreamBuilding false
      xml.blockBuildWhenUpstreamBuilding false
      xml.triggers(:class => "vector")
      xml.concurrentBuild false
      xml.builders {
        xml << "    <"
        xml.text! "hudson.tasks.Shell"
        xml << ">\n"
        xml.command {
          xml.text! "cat /dev/null > ~/.ssh/known_hosts
cd #{@virtual_monkey_path}
cat #{full_troop_file_name}
bin/monkey create -f #{full_troop_file_name} -x #{output_folder_name} -i #{cloud_id} -o #{image_regex != nil ? image_regex : image} #{mci_override} --yes
bin/monkey run -f #{full_troop_file_name} -x #{output_folder_name} #{specific_tests_to_run}#{resume ? "" : " -r" } #{timeout_command_line_flags} -v --yes\n"
        }
        xml << "    <"
        xml.text! "/hudson.tasks.Shell"
        xml << ">\n"
      }

      xml.publishers {
        xml << "    <"
        xml.text! "hudson.tasks.BuildTrigger"
        xml << ">\n"
        destroyer_job_name = "Z_" + "#{output_folder_name}"
        if chain == "job_to_destroyer"
          xml.childProjects destroyer_job_name
        elsif chain == "job_to_destroyer_and_next_job"
          if next_troop != nil
            next_job_name = suite_name + "_#{next_job_number}" + "_" + next_troop
            xml.childProjects destroyer_job_name + "," + "#{next_job_name}"
          else
            xml.childProjects destroyer_job_name
          end
        elsif chain == "job_to_destroyer_then_to_next_job"
          xml.childProjects destroyer_job_name
        else
          raise "Invalid chain value found \"#{chain}\""
        end
        xml.threshold {
          if threshold == "only_if_build_succeeds"
            xml.name "SUCCESS"
            xml.ordinal "0"
            xml.color "BLUE"
          elsif threshold == "even_if_build_is_unstable"
            xml.name "UNSTABLE"
            xml.ordinal "1"
            xml.color "YELLOW"
          elsif threshold == "even_if_the_build_fails"
            xml.name "FAILURE"
            xml.ordinal "2"
            xml.color "RED"
          else
            raise "Invalid threshold value found \"#{threshold}\""
          end
        }
        xml << "    <"
        xml.text! "/hudson.tasks.BuildTrigger"
        xml << ">\n"
      }
      xml.buildWrappers
    }

    # Clean up the output path and make sure it has the trailing '/'
    edited_output_file_path = edit_path(@output_file_path)

    # Create the complete target folder path
    FileUtils.mkpath "#{edited_output_file_path + output_folder_name}"

    # Write out the generated XML to that target folder
    File.open(edited_output_file_path + output_folder_name + "/config.xml", 'w') { |f| f.write(xml_output) }

    # Generate child project (destroy) job XML
    xml_output = ""
    xml = Builder::XmlMarkup.new(:target => xml_output, :indent => 2)
    xml.instruct! :xml, :version => "1.0", :encoding => "UTF-8"

    xml.project {
      xml.actions
      xml.description {}
      xml.keepDependencies false
      xml.properties
      xml << "  <"
      xml.text! "scm class" "=\"hudson.scm.NullSCM\""
      xml << "/>\n"
      if restrict_to_jenkins_instance != nil
        xml.assignedNode restrict_to_jenkins_instance
        xml.canRoam false
      else
        xml.canRoam true
      end
      xml.disabled false
      xml.blockBuildWhenDownstreamBuilding false
      xml.blockBuildWhenUpstreamBuilding false
      xml.triggers(:class => "vector")
      xml.concurrentBuild false
      xml.builders {
        xml << "    <"
        xml.text! "hudson.tasks.Shell"
        xml << ">\n"
        xml.command {
          if @force
            xml.text! "cd #{@virtual_monkey_path}
bin/monkey destroy -f #{full_troop_file_name} -x #{output_folder_name} --force --yes\n"
          else
            xml.text! "cd #{@virtual_monkey_path}
bin/monkey destroy -f #{full_troop_file_name} -x #{output_folder_name} --yes\n"
          end
        }
        xml << "    <"
        xml.text! "/hudson.tasks.Shell"
        xml << ">\n"
      }
      xml.publishers {
        if chain == "job_to_destroyer_then_to_next_job" && next_troop != nil
          xml << "    <"
          xml.text! "hudson.tasks.BuildTrigger"
          xml << ">\n"
          next_job_name = suite_name + "_#{next_job_number}" + "_" + next_troop
          xml.childProjects "#{next_job_name}"
          xml.threshold {
            if threshold == "only_if_build_succeeds"
              xml.name "SUCCESS"
              xml.ordinal "0"
              xml.color "BLUE"
            end
          }
          xml << "    <"
          xml.text! "/hudson.tasks.BuildTrigger"
          xml << ">\n"
        end
      }
      xml.buildWrappers
    }

    z_output_folder_name = "Z_" + output_folder_name

    # Create the complete target folder path
    FileUtils.mkpath "#{edited_output_file_path + z_output_folder_name}"

    # Write out the generated XML to that target folder
    File.open(edited_output_file_path + z_output_folder_name + "/config.xml", 'w') { |f| f.write(xml_output) }
  end



  ######################################################################################################################
  # instance method: generate_jenkins_zombie_report_job_as_xml
  #
  # Based on the supplied inputs this function will generate either the
  # WIP, Snapshot or Email Snapshot Report Jenkins job in the XML format Jenkins expects.
  ######################################################################################################################
  def generate_jenkins_zombie_report_job_as_xml(suite_prefix)

    # Clean up the output path and make sure it has the trailing '/'
    edited_output_file_path = edit_path(@output_file_path)

    # Create the complete target folder path
    output_folder_name = "#{suite_prefix}_000_Generate_Zombie_Deployments_HTML_Report"
    FileUtils.mkpath "#{edited_output_file_path + output_folder_name}"

    # Generate the Jenkins XML
    xml_output = ""
    xml = Builder::XmlMarkup.new(:target => xml_output, :indent => 2)
    xml.instruct! :xml, :version => "1.0", :encoding => "UTF-8"

    xml.project {
      xml.actions
      xml.description {}
      xml.keepDependencies false
      xml.properties
      xml << "  <"
      xml.text! "scm class" "=\"hudson.scm.NullSCM\""
      xml << "/>\n"
      xml.assignedNode "master"
      xml.canRoam false
      xml.disabled false
      xml.blockBuildWhenDownstreamBuilding false
      xml.blockBuildWhenUpstreamBuilding false
      xml.triggers(:class => "vector") {
        xml << "    <"
        xml.text! "hudson.triggers.TimerTrigger"
        xml << ">\n"
        xml.spec "* * * * *"
        xml << "    <"
        xml.text! "/hudson.triggers.TimerTrigger"
        xml << ">\n"
      }
      xml.concurrentBuild false
      xml.builders {
        xml << "    <"
        xml.text! "hudson.tasks.Shell"
        xml << ">\n"
        xml.command {
        xml.text! "cd #{@virtual_monkey_path}lib/rocketmonkey
./rocketmonkey --generate-reports --zombie --input #{@csv_input_filename}\n"
        }
        xml << "    <"
        xml.text! "/hudson.tasks.Shell"
        xml << ">\n"
      }
      xml.publishers
      xml.buildWrappers
    }

    # Write out the generated XML to that target folder
    File.open(edited_output_file_path + output_folder_name + "/config.xml", 'w') { |f| f.write(xml_output) }
  end


  ######################################################################################################################
  # instance method: generate_jenkins_report_job_as_xml
  #
  # Based on the supplied inputs this function will generate either the
  # WIP, Snapshot or Email Snapshot Report Jenkins job in the XML format Jenkins expects.
  ######################################################################################################################
  def generate_jenkins_report_job_as_xml(suite_prefix, snapshot, mail_failure_report)

    # Clean up the output path and make sure it has the trailing '/'
    edited_output_file_path = edit_path(@output_file_path)

    # Create the complete target folder path
    if snapshot
      output_folder_name =
          "#{suite_prefix}_000_Generate_#{mail_failure_report ? "And_Email_Failures_" : ""}Snapshot_HTML_Report"
    else
      output_folder_name = "#{suite_prefix}_000_Generate_WIP_HTML_Report"
    end
    FileUtils.mkpath "#{edited_output_file_path + output_folder_name}"

    # Generate the Jenkins XML
    xml_output = ""
    xml = Builder::XmlMarkup.new(:target => xml_output, :indent => 2)
    xml.instruct! :xml, :version => "1.0", :encoding => "UTF-8"

    xml.project {
      xml.actions
      xml.description {}
      xml.keepDependencies false
      xml.properties
      xml << "  <"
      xml.text! "scm class" "=\"hudson.scm.NullSCM\""
      xml << "/>\n"
      xml.assignedNode "master"
      xml.canRoam false
      xml.disabled false
      xml.blockBuildWhenDownstreamBuilding false
      xml.blockBuildWhenUpstreamBuilding false
      if !snapshot
        xml.triggers(:class => "vector") {
          xml << "    <"
          xml.text! "hudson.triggers.TimerTrigger"
          xml << ">\n"
          xml.spec "* * * * *"
          xml << "    <"
          xml.text! "/hudson.triggers.TimerTrigger"
          xml << ">\n"
        }
      elsif mail_failure_report && @failure_report_run_time != nil
        xml.triggers(:class => "vector") {
          xml << "    <"
          xml.text! "hudson.triggers.TimerTrigger"
          xml << ">\n"
          xml.spec @failure_report_run_time
          xml << "    <"
          xml.text! "/hudson.triggers.TimerTrigger"
          xml << ">\n"
        }
      else
        xml.triggers(:class => "vector")
      end
      xml.concurrentBuild false
      xml.builders {
        xml << "    <"
        xml.text! "hudson.tasks.Shell"
        xml << ">\n"
        xml.command {
          if snapshot
            xml.text! "cd #{@virtual_monkey_path}lib/rocketmonkey
./rocketmonkey --generate-reports --input #{@csv_input_filename} --snapshot --refresh-rate #{@refresh_rate_in_seconds} --truncate-troops #{@truncate_troops}#{mail_failure_report ? " --mail-failure-report" : ""}\n"
          else
            xml.text! "cd #{@virtual_monkey_path}lib/rocketmonkey
./rocketmonkey --generate-reports --input #{@csv_input_filename} --refresh-rate #{@refresh_rate_in_seconds} --truncate-troops #{@truncate_troops}
./rocketmonkey --generate-reports --input #{@csv_input_filename} --refresh-rate #{@refresh_rate_in_seconds} --truncate-troops #{@truncate_troops} --generate-actions
./rocketmonkey --generate-reports --input #{@csv_input_filename} --refresh-rate #{@refresh_rate_in_seconds} --truncate-troops #{@truncate_troops} --destroyers
./rocketmonkey --generate-reports --input #{@csv_input_filename} --refresh-rate #{@refresh_rate_in_seconds} --truncate-troops #{@truncate_troops} --destroyers --generate-actions\n"
          end
        }
        xml << "    <"
        xml.text! "/hudson.tasks.Shell"
        xml << ">\n"
      }
      xml.publishers
      xml.buildWrappers
    }

    # Write out the generated XML to that target folder
    File.open(edited_output_file_path + output_folder_name + "/config.xml", 'w') { |f| f.write(xml_output) }
  end



  ######################################################################################################################
  # instance method: generate_jenkins_chain_and_threshold_job_as_xml
  #
  # Based on the supplied inputs this function will generate Chain and Threshold Jenkins job in the XML format Jenkins
  # expects.
  ######################################################################################################################
  def generate_jenkins_chain_and_threshold_job_as_xml(suite_prefix)

    # Clean up the output path and make sure it has the trailing '/'
    edited_output_file_path = edit_path(@output_file_path)

    # Create the complete target folder path
    output_folder_name = "#{suite_prefix}_000_Reload_Jobs_With_New_Chain_And_Threshold_Options"

    FileUtils.mkpath "#{edited_output_file_path + output_folder_name}"

    # Generate the Jenkins XML
    xml_output = ""
    xml = Builder::XmlMarkup.new(:target => xml_output, :indent => 2)
    xml.instruct! :xml, :version => "1.0", :encoding => "UTF-8"

    xml.project {
      xml.actions
      xml.description {}
      xml.keepDependencies false
      xml.properties {
        xml << "  <"
        xml.text! "hudson.model.ParametersDefinitionProperty"
        xml << ">\n"
        xml.parameterDefinitions {

          xml << "  <"
          xml.text! "hudson.model.ChoiceParameterDefinition"
          xml << ">\n"
          xml.name "CHAIN"
          xml.description {}
          xml << "  <"
          xml.text! "choices class=\"java.util.Arrays$ArrayList\""
          xml << ">\n"
          xml << "  <"
          xml.text! "a class=\"string-array\""
          xml << ">\n"
          xml.string "job_to_destroyer"
          xml.string "job_to_destroyer_and_next_job"
          xml.string "job_to_destroyer_then_to_next_job"
          xml << "  <"
          xml.text! "/a"
          xml << ">\n"
          xml << "  <"
          xml.text! "/choices"
          xml << ">\n"
          xml << "  <"
          xml.text! "/hudson.model.ChoiceParameterDefinition"
          xml << ">\n"

          xml << "  <"
          xml.text! "hudson.model.ChoiceParameterDefinition"
          xml << ">\n"
          xml.name "THRESHOLD"
          xml.description {}
          xml << "  <"
          xml.text! "choices class=\"java.util.Arrays$ArrayList\""
          xml << ">\n"
          xml << "  <"
          xml.text! "a class=\"string-array\""
          xml << ">\n"
          xml.string "only_if_build_succeeds"
          xml.string "even_if_build_is_unstable"
          xml.string "even_if_the_build_fails"
          xml << "  <"
          xml.text! "/a"
          xml << ">\n"
          xml << "  <"
          xml.text! "/choices"
          xml << ">\n"
          xml << "  <"
          xml.text! "/hudson.model.ChoiceParameterDefinition"
          xml << ">\n"
        }
        xml << "  <"
        xml.text! "/hudson.model.ParametersDefinitionProperty"
        xml << ">\n"
      }

      xml << "  <"
      xml.text! "scm class" "=\"hudson.scm.NullSCM\""
      xml << "/>\n"
      xml.assignedNode "master"
      xml.canRoam false
      xml.disabled false
      xml.blockBuildWhenDownstreamBuilding false
      xml.blockBuildWhenUpstreamBuilding false
      xml.triggers(:class => "vector")
      xml.concurrentBuild false
      xml.builders {
        xml << "    <"
        xml.text! "hudson.tasks.Shell"
        xml << ">\n"
        xml.command {
          xml << "cd #{@virtual_monkey_path}lib/rocketmonkey
sed -i \"/^:chain:/ s/:chain:.*/:chain: $CHAIN/\" .rocketmonkey.yaml
sed -i \"/^:threshold:/ s/:threshold.*/:threshold: $THRESHOLD/\" .rocketmonkey.yaml
./rocketmonkey --generate-jenkins-files --input #{@csv_input_filename} --tabs --refresh-rate #{@refresh_rate_in_seconds} --truncate-troops #{@truncate_troops}#{@force ? " --force" : ""}\n"
        }
        xml << "    <"
        xml.text! "/hudson.tasks.Shell"
        xml << ">\n"
      }
      xml.publishers
      xml.buildWrappers
    }

    # Write out the generated XML to that target folder
    File.open(edited_output_file_path + output_folder_name + "/config.xml", 'w') { |f| f.write(xml_output) }
  end



  ######################################################################################################################
  # instance method: get_mci_override
  #
  # Based on the supplied inputs this function will return the matching mci MCI override value or raise an exception.
  #
  # The CSV columns are:
  #   Friendly Name(String), MCI(Integer),  Head(Integer), Target(Integer), Revision(Integer),  Notes(String)
  ######################################################################################################################
  def get_mci_override(path_to_mci_override_file, parsed_mci_override_array, friendly_name, revision)
    for i in 0..parsed_mci_override_array.length - 1
      if friendly_name == parsed_mci_override_array[i][0] && revision == parsed_mci_override_array[i][4]
        target = parsed_mci_override_array[i][3]
        return target if Integer(target) > 0
        return parsed_mci_override_array[i][2] # head
      end
    end
    raise "Can't find an MCI override match for #{friendly_name}, #{revision} in #{path_to_mci_override_file}"
  end



  ######################################################################################################################
  # instance method: generate_jenkins_jobs
  #
  # Based on the supplied inputs this function will generate all the Jenkins jobs in XML format Jenkins expects
  ######################################################################################################################
  def generate_jenkins_jobs
    # Get the suite prefix from the first element
    suite_prefix = @parsed_job_definition[@cloud_row][@server_template_column].strip

    # Array to check for troop name uniqueness
    troop_array = []

    # Traverse rows
    for i in @start_row..@parsed_job_definition.length - 1

      # The row "j" header has the troop name so get that
      troop_name = @parsed_job_definition[i][@troop_column]

      # Ensure troop name uniqueness
      if troop_array.include?(troop_name)
        raise "Duplicate troop name \"#{troop_name}\" found at row: #{i+1} in #{@csv_input_filename}"
      else
        troop_array.push(troop_name)
      end

      # Traverse columns
      for j in @start_column..@parsed_job_definition[i].length - 1

        element = @parsed_job_definition[i][j]

        # Strip off all leading and trailing spaces
        element.strip! if element != nil

        # Only generate the XML job if this is a normal job element
        if is_job_element?(element)

          # if a file reference is found read that file into an array
          element_filename = nil
          element_file_array = []
          mci_override = nil
          if element != nil
            if element[0..1].upcase == "F:"
              # Handle normal file reference element
              element_filename = element.split(":")[1]

              # Get path to CSV file and use that as the path to the element file
              path_to_element_filename = File.expand_path(File.dirname(@csv_input_filename)) + "/#{element_filename}"

              file = File.open(path_to_element_filename)
              element_file_array = file.readlines
              file.close
              raise "Empty element file \"#{element_filename}\" found at row: #{i + 1}, column: #{j + 1} in #{@csv_input_filename}" unless element_file_array.length > 0
            elsif element[0..1].upcase == "M:"
              # Handle normal file reference element
              friendly_name, revision = element.split("/")
              friendly_name = friendly_name[2..-1]

              raise "Missing mci_override_file_name definition in yaml file" if @mci_override_file_name == nil

              # Get path to CSV file and use that as the path to the element file
              path_to_mci_override_file = File.expand_path(File.dirname(@csv_input_filename)) + "/#{@mci_override_file_name}"

              # Parse the MCI Override CSV file into a 2-dimensional array and then derive the correct mci override
              # value
              mci_override = get_mci_override(path_to_mci_override_file, CSV.read(path_to_mci_override_file),
                                              friendly_name, revision)
            end
          end

          # Parse out the cloud variables
          split_cloud_region_image_array, raw_cloud_name, cloud_lookup_name, cloud_name, region_name, image_name =
              get_cloud_variables(j)

          # Now handle the optional <key>:<value> pairs - there may be any number of them and if there
          # are duplicate keys, the last one encountered wins.
          cloud_timeout = restrict_to_jenkins_instance = image_regex = nil
          cloud_chain_override = cloud_threshold_override = cloud_resume_override = nil
          column_enabled = "TRUE"
          for split_column_parameters_index in 3..split_cloud_region_image_array.length - 1
            split_column_parameters_array = split_cloud_region_image_array[split_column_parameters_index].split(/:/)

            # Enforce <key>:<value> semantics
            if split_column_parameters_array.length != 2
              raise "Invalid format for optional column parameter found in \"#{split_cloud_region_image_array[split_column_parameters_index]}\", should be in the form <key>:<value> at row: #{i + 1}, column: #{j + 1} in #{@csv_input_filename}"
            end

            if split_column_parameters_array[0].upcase == "TIMEOUT"
              cloud_timeout = split_column_parameters_array[1].strip
            elsif split_column_parameters_array[0].upcase == "RESTRICT"
              restrict_to_jenkins_instance = split_column_parameters_array[1].strip
            elsif split_column_parameters_array[0].upcase == "IMAGE-REGEX"
              image_regex = split_column_parameters_array[1].strip
            elsif split_column_parameters_array[0].upcase == "ENABLED"
              column_enabled = split_column_parameters_array[1].strip
            elsif split_column_parameters_array[0].upcase == "CHAIN"
              cloud_chain_override = split_column_parameters_array[1].strip.downcase
            elsif split_column_parameters_array[0].upcase == "THRESHOLD"
              cloud_threshold_override = split_column_parameters_array[1].strip.downcase
            elsif split_column_parameters_array[0].upcase == "RESUME"
              cloud_resume_override = split_column_parameters_array[1].strip.downcase
            else
              raise "Invalid column parameter key \"#{split_column_parameters_array[0]}\" found at row: #{i + 1}, column: #{j + 1} in #{@csv_input_filename}"
            end
          end

          # Get cloud ID from the lookup name
          cloud_id = get_cloud_id(cloud_lookup_name)

          # Build the complete suite name
          suite_name = suite_prefix + "_#{cloud_name}" + "_" + image_name

          # Handle optional <troop name>__<test name> case
          test_name = ""
          test_name_override = false
          split_troop_test_array = troop_name.split(/__/)
          if split_troop_test_array.length > 1
            test_name_override = true
            test_name = split_troop_test_array[1]
          end

          if column_enabled.upcase == "TRUE"
            # Compute a unique job number and build the complete XML output file name
            job_number = get_job_order_number_as_string(i)
            next_job_number, next_troop = get_next_job(i, j)

            # Generate the XML job for this element
            generate_jenkins_virtual_monkey_jobs_as_xml(suite_name, cloud_name, cloud_id, image_name, cloud_timeout,
                                                        job_number, troop_name, element_filename, element_file_array,
                                                        mci_override, next_job_number, next_troop, test_name,
                                                        test_name_override, restrict_to_jenkins_instance, image_regex,
                                                        cloud_chain_override, cloud_threshold_override,
                                                        cloud_resume_override)
          elsif column_enabled.upcase == "FALSE"
            # OK - will be used later in the report
          else
            raise "Invalid ENABLED column parameter value \"#{split_column_parameters_array[1]}\" found at row: #{i + 1}, column: #{j + 1} in #{@csv_input_filename}"
          end
        elsif is_ns_nsy_dis_element?(element)
          # OK - will be used later in the report
        else
          raise_invalid_element_exception(element, i, j)
        end
      end
    end

    # Generate the WIP report Jenkins job
    generate_jenkins_report_job_as_xml(suite_prefix, false, false)

    # Generate the snapshot report Jenkins job
    generate_jenkins_report_job_as_xml(suite_prefix, true, false)

    # Generate the email snapshot report Jenkins job
    generate_jenkins_report_job_as_xml(suite_prefix, true, true)

    # Generate the chain and threshold Jenkins job
    generate_jenkins_chain_and_threshold_job_as_xml(suite_prefix)

    # Generate the Zombie Deployments report Jenkins job
    generate_jenkins_zombie_report_job_as_xml(suite_prefix)

    # Generate "RS-<cloud>-<region>-<image>" column tabs in Jenkins
    update_jenkins_master_config()
  end
end
