require 'rubygems'
require 'erb'
require 'fog'
require 'eventmachine'
require 'right_popen'

module VirtualMonkey
  class GrinderJob
    attr_accessor :status, :output, :logfile, :deployment, :rest_log, :other_logs, :no_resume, :verbose, :err_log
    # Metadata is a hash containing the following fields:
    #   user => { "email" => `git config user.email`.chomp,
    #             "name" => `git config user.name`.chomp }
    #   multicloudimage => { "name" => MultiCloudImage.name,
    #                        "href" => MultiCloudImage.href,
    #                        "os" => "CentOS|Ubuntu|Windows",
    #                        "os_version" => "5.4|5.6|10.04|2008R2|2003",
    #                        "arch" => "i386|x64",
    #                        "rightlink" => "5.6.32|5.7.14",
    #                        "rev" => 14,
    #                        "id" => 41732 }
    #   servertemplates => [{ "name" => ServerTemplate.nickname,
    #                         "href" => ServerTemplate.href,
    #                         "id" => 432672,
    #                         "rev" => 10 },
    #                       ...]
    #   cloud => { "name" => Cloud.name,
    #              "id" => Cloud.cloud_id }
    #   feature => ["base.rb", ...]
    #   instancetype => { "href" => InstanceType.href,
    #                     "name" => InstanceType.name }
    #   datacenter => { "name" => Datacenter.name,
    #                   "href" => Datacenter.href }
    #   troop => "base.json"
    #   report => nil until finished
    #   tags => ["sprint28", "regression", ...] (From @@options[:report_tags])
    #   time => VirtualMonkey::Manager::Grinder.log_started
    #   status => "pending|running|failed|passed" (or, manually, "blocked" or "willnotdo")
    attr_accessor :metadata

    def link_to_rightscale
      deployment.href.gsub(/api\//,"") + "#auditentries"
    end

    # stdout hook for popen3
    def on_read_stdout(data)
      data_ary = data.split("\n")
      data_ary.each_index do |i|
        data_ary[i] = timestamp + data_ary[i]
        $stdout.syswrite("<#{deploy_id}>#{data_ary[i]}\n".uncolorize) if @verbose
      end
      File.open(@logfile, "a") { |f| f.write("#{data_ary.join("\n")}\n".uncolorize) }
    end

    # stderr hook for popen3
    def on_read_stderr(data)
      data_ary = data.split("\n")
      data_ary.each_index do |i|
        data_ary[i] = timestamp + data_ary[i]
        $stdout.syswrite("<#{deploy_id}>#{data_ary[i]}\n".apply_color(:uncolorize, :yellow))
      end
      File.open(@logfile, "a") { |f| f.write("#{data_ary.join("\n")}\n".uncolorize) }
      File.open(@err_log, "a") { |f| f.write("#{data_ary.join("\n")}\n".uncolorize) }
    end

    def timestamp
      t = Time.now
      "#{t.strftime("[%m/%d/%Y %H:%M:%S.")}%06d] " % t.usec
    end

    def deploy_id
      @id = deployment.rs_id
    end

    # on_exit hook for popen3
    def on_exit(status)
      @status = status.exitstatus
    end

    # Launch an asynchronous process
    def run(cmd)
      RightScale.popen3(:command        => cmd,
                        :target         => self,
                        :environment    => {"AWS_ACCESS_KEY_ID" => Fog.credentials[:aws_access_key_id],
                                            "AWS_SECRET_ACCESS_KEY" => Fog.credentials[:aws_secret_access_key],
                                            "REST_CONNECTION_LOG" => @rest_log,
                                            "MONKEY_NO_DEBUG" => "true",
                                            "MONKEY_LOG_BASE_DIR" => File.dirname(@rest_log)},
                        :stdout_handler => :on_read_stdout,
                        :stderr_handler => :on_read_stderr,
                        :exit_handler   => :on_exit)
    end
  end
end

module VirtualMonkey
  module Manager
    class Grinder
      attr_accessor :jobs
      attr_accessor :options

      def self.combo_feature_name(features)
        project = VirtualMonkey::Manager::Collateral::get_project_from_file(features.first)
        name = features.map { |feature| File.basename(feature, ".rb") }.join("_") + ".combo.rb"
        File.join(project.paths["features"], name)
      end

      # Runs a grinder test on a single Deployment
      # * deployment<~String> the nickname of the deployment
      # * feature<~String> the feature filename
      def build_job(deployment, feature, test_ary, other_logs = [])
        new_job = VirtualMonkey::GrinderJob.new
        new_job.logfile = File.join(@log_dir, "#{deployment.nickname}.log")
        new_job.err_log = File.join(@log_dir, "#{deployment.nickname}.stderr.log")
        new_job.rest_log = File.join(@log_dir, "#{deployment.nickname}.rest_connection.log")
        new_job.other_logs = other_logs.map { |log|
          File.join(@log_dir, "#{deployment.nickname}.#{File.basename(log)}")
        }
        new_job.deployment = deployment
        new_job.verbose = true if @options[:verbose]
        grinder_bin = File.join(VirtualMonkey::BIN_DIR, "grinder")
        cmd = "\"#{grinder_bin}\" -f \"#{feature}\" -d \"#{deployment.nickname}\" -t "
        test_ary.each { |test| cmd += " \"#{test}\" " }
        cmd += " -r " if @options[:no_resume]

        if @options[:report_metadata]
          # Build Job Metadata
          puts "\nBuilding Job Metadata...\n\n"
          new_job.metadata = VirtualMonkey::Metadata::get_report_metadata(deployment, feature, @options, @started_at)
        end
        new_job.metadata ||= {}

        [new_job, cmd]
      end

      def run_test(deployment, feature, test_ary, other_logs = [])
        new_job, cmd = build_job(deployment, feature, test_ary, other_logs)
        @jobs << new_job

        cmd += " -g "
        puts "running #{cmd}"
        new_job.run(cmd)
      end

      def exec_test(deployment, feature, test_ary, other_logs = [])
        if VirtualMonkey::config[:grinder_subprocess] == "allow_same_process" && tty?
          new_job, cmd = build_job(deployment, feature, test_ary, other_logs)
          warn "\n========== Loading Grinder into current process! =========="
          warn "\nSince you only have one deployment, it would probably be of more use to run the developer tool"
          warn "Grinder directly. The command:\n\n#{cmd}\n\nwill replace the current process."
          warn "\nPress Ctrl-C in the next 15 seconds to run Grinder in a subprocess rather than this one."
          exec(cmd) if VirtualMonkey::Command::countdown(15)
        end
        run_test(deployment, feature, test_ary, other_logs)
      end

      def initialize(opts={})
        @options = opts
        begin
          @started_at = Marshal.load(Base64.decode64(opts[:started_at]))
        rescue
        ensure
          @started_at ||= Time.now
        end
        @jobs = []
        @passed = []
        @failed = []
        @running = []
        dirname = @started_at.strftime(File.join("%Y", "%m", "%d", "%H-%M-%S"))
        @log_dir = File.join(VirtualMonkey::ROOTDIR, "log", dirname)
        @log_started = dirname
        FileUtils.mkdir_p(@log_dir)
        @feature_dir = File.join(VirtualMonkey::ROOTDIR, 'features')
      end

      # runs a feature on an array of deployments
      # * deployments<~Array> array of strings containing the nicknames of the deployments
      # * feature_name<~String> the feature filename
      #
      # Analyzes the configuration of the monkey, configuration of the features files,
      # the set of tests to run and the available deployments.
      def run_tests(deploys, features, set=[])

        # proc to handle reporting throttling blocked status
        report_blocked_status = proc do |ret,d,feature,options,started_at|
          # Handle reporting back "blocked" status
          data = {
            "annotation" => ret,
            "status" => "blocked"
          }
          # Update SimpleDB
          meta_data = ::VirtualMonkey::Metadata.get_report_metadata(d, feature, options, started_at)
          meta_data.deep_merge! data
          report = ::VirtualMonkey::API::Report.new.deep_merge meta_data
          ::VirtualMonkey::API::Report.update_sdb report
          warn ret
        end

        # Validate that we can divide up teature tests amung deployments
        features = [features].flatten
        warn_msg = {}
        unless set.nil? || set.empty?
          features.reject! do |feature|
            my_keys = VirtualMonkey::TestCase.new(feature, @options).get_keys
            warn_msg[feature] = my_keys
            my_keys &= set
            my_keys -= @options[:exclude_tests] unless @options[:exclude_tests].nil? || @options[:exclude_tests].empty?
            my_keys.empty?
          end
        end

        if features.empty?
          warn warn_msg.pretty_inspect
          error "No features match #{set.inspect}! (Did you mispell a test name?)"
        end

        # Divide up the features and tests amung the deployments
        test_cases = features.map_to_h { |feature| VirtualMonkey::TestCase.new(feature, @options) }
        deployment_hsh = {}
        if VirtualMonkey::config[:feature_mixins] == "parallel" or features.length < 2
          raise "Need more deployments than feature files" unless deploys.length >= features.length
          dep_clone = deploys.dup
          deps_per_feature = (deploys.length.to_f / features.length.to_f).floor
          deployment_hsh = features.map_to_h { |f|
            dep_clone.shuffle!
            dep_clone.slice!(0,deps_per_feature)
          }
        else
          combo_feature = VirtualMonkey::Manager::Grinder.combo_feature_name(features)
          File.open(combo_feature, "w") { |f|
            f.write(features.map { |feature| "mixin_feature '#{feature}', :hard_reset" }.join("\n"))
          }
          test_cases[combo_feature] = VirtualMonkey::TestCase.new(combo_feature, @options)
          deployment_hsh = { combo_feature => deploys }
        end

        if deploys.size == 1 && VirtualMonkey::Command::last_command_line !~ /^troop/ && !@options[:report_metadata]
          # handle a single deployment
          feature = deployment_hsh.first.first
          d = deployment_hsh.first.last.last
          total_keys = test_cases[feature].get_keys
          total_keys &= set unless set.nil? || set.empty?
          total_keys -= @options[:exclude_tests] unless @options[:exclude_tests].nil? || @options[:exclude_tests].empty?
          deployment_tests = [total_keys]

          if VirtualMonkey::config[:test_ordering] == "random"
            deployment_tests = [total_keys].map { |ary| ary.shuffle }
          end

          if @options[:report_metadata]
            # Using the mappings of deployments to tests we will make sure the deployment can be run.
            # Create a new runner instance for the feature's test case
            runner = test_cases[feature].options[:runner].new(d.nickname)

            # Call the before_run code for the runner and if it fails bail out
            if ret = before_run_logic(runner)
              # Handle reporting back "blocked" status
              report_blocked_status[ret, d, feature, @options, @started_at]
              exit 1
            end
          end

          exec_test(d, feature, deployment_tests[0], test_cases[feature].options[:additional_logs])

        else # multiple deployments handled here
          deployment_hsh.each { |feature,deploy_ary|
            total_keys = test_cases[feature].get_keys
            total_keys &= set unless set.nil? || set.empty?
            total_keys -= @options[:exclude_tests] unless @options[:exclude_tests].nil? || @options[:exclude_tests].empty?

            if @options[:report_metadata]
              # Using the mappings of deployments to tests we will make sure the deployment can be run
              #
              # Create a new runner instance for the feature's test case
              deploy_ary.reject! do |d|
                runner = test_cases[feature].options[:runner].new(d.nickname)
                ret = before_run_logic(runner)
                # Call the before_run code for the runner and if it fails bail out
                if ret
                  # Handle reporting back "blocked" status
                  report_blocked_status[ret, d, feature, @options, @started_at]
                end
                ret
              end

              exit 1 if deploy_ary.empty?
            end

            # Pick which tests are assigned to which deployments
            unless VirtualMonkey::config[:test_permutation] == "distributive"
              deployment_tests = [total_keys] * deploy_ary.length
            else
              keys_per_dep = (total_keys.length.to_f / deploy_ary.length.to_f).ceil

              deployment_tests = []
              (keys_per_dep * deploy_ary.length).times { |i|
                di = i % deploy_ary.length
                deployment_tests[di] ||= []
                deployment_tests[di] << total_keys[i % total_keys.length]
              }
            end

            # Pick the order in which the tests will execute (per deployment)
            deployment_tests.map! { |ary| ary.shuffle } unless VirtualMonkey::config[:test_ordering] == "strict"

            # Execute the tests
            deploy_ary.each_with_index { |d,i|
              run_test(d, feature, deployment_tests[i], test_cases[feature].options[:additional_logs])
            }
          }
        end
      end

      # Encapsulates the logic for executing the before_run hooks for a particular runner
      def before_run_logic(runner)
        if runner.class.respond_to?(:before_run)
          runner.class.ancestors.select { |a| a.respond_to?(:before_run) }.each do |ancestor|
            if not ancestor.before_run.empty?
              puts "Executing before_run hooks..."
              ancestor.before_run.each { |fn|
                ret = false
                begin
                  ret = (fn.is_a?(Proc) ? runner.instance_eval(&fn) : runner.__send__(fn))
                rescue Exception => e
                  warn "WARNING: Got \"#{e.message}\" from #{e.backtrace.join("\n")}"
                end
                return ret if ret
              }
              puts "Finished executing before_run hooks."
            end
          end
        else
          warn "#{runner.class} doesn't extend VirtualMonkey::RunnerCore::CommandHooks"
          return true
        end
        return false
      end

      # Print status of jobs. Also watches for jobs that had exit statuses other than 0 or 1
      def watch_and_report
        old_passed,  @passed  = @passed,  @jobs.select { |s| s.status == 0 }
        old_failed,  @failed  = @failed,  @jobs.select { |s| s.status != 0 && s.status != nil }
        old_running, @running = @running, @jobs.select { |s| s.status == nil }

        passed_string = " #{@passed.size} features passed. "
        passed_string = passed_string.apply_color(:green) if @passed.size > 0

        failed_string = " #{@failed.size} features failed. "
        failed_string = failed_string.apply_color(:red) if @failed.size > 0

        running_string = " #{@running.size} features running "
        running_string = running_string.apply_color(:cyan) if @running.size > 0
        running_string += "for #{Time.duration(Time.now - @started_at)}"

        puts(passed_string + failed_string + running_string)
        status_change_hook if old_passed != @passed || old_failed != @failed
      end

      def status_change_hook
        begin
          generate_reports
        rescue Interrupt => e
          raise
        rescue Exception => e
          warn "#{e}\n#{e.backtrace.join("\n")}"
        ensure
          if all_done?
            puts "monkey done."
            EM.stop
          end
        end
      end

      def all_done?
        running = @jobs.select { |s| s.status == nil }
        running.size == 0 && @jobs.size > 0
      end

      # Generates monkey reports and uploads to S3
      def generate_reports
        report_url = ""
        if @options[:report_metadata]
          report_uid = VirtualMonkey::API::Report.create({
            "jobs" => @jobs,
            "log_started" => @log_started,
            "report_metadata" => @options[:report_metadata],
          }).first
          report_url = VirtualMonkey::API::Report.get(report_uid)["report_page"]
        else
          report_url = VirtualMonkey::API::Report.update_s3(@jobs, @log_started)
        end
        puts "\n    New results available at #{report_url}\n\n"
      end
    end
  end
end
