module VirtualMonkey
  module Command
    def self.load_config_file
      if @@options[:prefix] and not @@options[:config_file] and @@command =~ /run|destroy/
        # Try loading from deployment tag
        deployments = VirtualMonkey::Manager::DeploymentSet.from_name(@@options[:prefix])
        if deployments.unanimous? { |d| d.get_info_tags["self"]["troop"] }
          @@options[:config_file] = deployments.first.get_info_tags["self"]["troop"]
        else
          raise "FATAL: Inconsistent 'info:troop=...' tags on deployments"
        end
      end
      raise "FATAL: --config_file is required!" unless @@options[:config_file]
      config_file = File.expand_path(@@options[:config_file])
      config = JSON::parse(IO.read(config_file))

      # Find Project that troop file is a part of
      @@selected_project = VirtualMonkey::Manager::Collateral.get_project_from_file(config_file)

      # Build Prefix
      @@options[:prefix] += "-" if @@options[:prefix]
      @@options[:prefix] = "" unless @@options[:prefix]
      @@options[:prefix] += config['prefix']

      # Find Common Inputs
      @@options[:common_inputs] = config['common_inputs'].map do |cipath|
        File.join(@@selected_project.paths["common_inputs"], cipath)
      end

      # Load feature files & get runner class
      @@options[:feature] = load_features(config)
      @@options[:runner] ||= get_runner_class

      # Set the terminate option?
      @@options[:terminate] = true if @@command =~ /troop|destroy/

      # Load cloud variables
      @@options[:clouds] = load_clouds(config) unless @@options[:clouds] and @@options[:clouds].length > 0

      # Get server_template_ids
      @@options[:server_template_ids] = config['server_template_ids']
      if (@@options[:revisions] ||= []).empty?
        @@options[:revisions] = [0] * config['server_template_ids'].length
      else
        rev_len, st_len = @@options[:revisions].length, config['server_template_ids'].length
        if rev_len != st_len
          raise "FATAL: #{rev_len} revisions specified. This troop is configured for #{st_len} servers."
        end
        pp config['server_template_ids'].zip(@@options[:revisions]).map { |stid, rev|
          {ServerTemplate.find(stid.to_i).nickname => "[rev #{rev}]"}
        }.to_h
        if not @@options[:yes] and tty?
          unless ask("Are these the correct revisions that should be used?", lambda { |ans| ans =~ /^[yY]/ })
            error "Aborting on user input."
          end
        end
      end
      # TODO - Blocked on API 1.5 Revision History
      #st_revision_map = config['server_template_ids'].zip(@@options[:revisions]).to_h
      #@@options[:server_template_ids] = []
      #st_revision_map.each { |st_id|
      #  ServerTemplate.find_by(:nickname) { |n| n == ServerTemplate.find(st_id) }
      #}
    end

    def self.load_clouds(config)
      # TODO Multicloud Deployments
      return config['clouds'] if config['clouds']
      VirtualMonkey::Toolbox::get_available_clouds.map { |hsh| hsh["cloud_id"].to_i }
    end

    # Encapsulates the logic for selecting a subset of deployments
    def self.select_only_logic(message)
      @@do_these ||= @@dm.deployments
      if @@options[:only]
        [@@options[:only]].flatten.compact.each do |filter|
          @@do_these = @@do_these.select { |d| d.nickname =~ /#{filter}/ }
        end
      end
      all_clouds = VirtualMonkey::Toolbox::get_available_clouds.map { |hsh| hsh["cloud_id"].to_i }
      (all_clouds - @@options[:clouds]).each { |cid|
        @@do_these.reject! { |d| d.nickname =~ /-cloud_#{cid}-/ }
      }
      unless @@options[:no_resume] or @@command =~ /destroy|audit/
        temp = @@do_these.select do |d|
          files_to_check = @@options[:feature] + [VirtualMonkey::Manager::Grinder.combo_feature_name(@@options[:feature])]
          files_to_check.any? { |feature|
            File.exist?(File.join(VirtualMonkey::TEST_STATE_DIR, d.nickname, File.basename(feature)))
          }
        end
        @@do_these = temp if temp.length > 0
      end

      raise "No deployments matched!" unless @@do_these.length > 0
      if @@options[:verbose]
        pp @@do_these.map { |d| { d.nickname => d.servers.map { |s| s.state } } }
      else
        pp @@do_these.map { |d| d.nickname }
      end
      if not @@options[:yes] and not @@command == "troop" and tty?
        unless ask("#{message} these #{@@do_these.size} deployments (y/n)?", lambda { |ans| ans =~ /^[yY]/ })
          error "Aborting on user input."
        end
      end
    end

    # Encapsulates the logic for loading the necessary variables to create a set of deployments
    def self.create_logic
      error "Need Internal Testing API access to use this command." unless VirtualMonkey::Toolbox::api0_1?
      if @@options[:clouds]
        @@dm.load_clouds(@@options[:clouds])
#      elsif @@options[:cloud_variables]
#        @@options[:cloud_variables].each { |cvpath| @@dm.load_cloud_variables(cvpath) }
      else
        raise "Usage Error! Need --clouds"
      end
      @@options[:common_inputs].each { |cipath| @@dm.load_common_inputs(cipath) }
      @@dm.generate_variations(@@options)
    end

    # Encapsulates the logic for launching and monitoring a set of asynchronous processes that run grinder
    # with a test case. Included is the logic for optionally destroying "successful" servers or
    # running "successful" servers through the log auditor/trainer.
    def self.run_logic
      error "Need Internal Testing API access to use this command." unless VirtualMonkey::Toolbox::api0_1?
      @@options[:runner] ||= get_runner_class
      raise "FATAL: Could not determine runner class" unless @@options[:runner]

      # Ensure that we don't kill babies by trying to run EM within itself
      @@already_in_em = EM.reactor_running?

      evented_code = proc do
        @@gm ||= VirtualMonkey::Manager::Grinder.new(@@options)
        @@dm ||= VirtualMonkey::Manager::DeploymentSet.new(@@options)
        @@options[:runner] ||= get_runner_class
        select_only_logic("Run tests on")

        @@gm.run_tests(@@do_these, @@options[:feature], @@options[:tests])
        @@remaining_jobs = @@gm.jobs.dup

        if @@already_in_em
          begin
            sleep 10
            @@gm.watch_and_report
            break if @@gm.all_done?

            if @@options[:terminate] and not (@@options[:list_trainer] or @@options[:qa])
              @@remaining_jobs.each do |job|
                if job.status == 0
                  destroy_job_logic(job)
                end
              end
            end
          rescue Interrupt, NameError, ArgumentError, TypeError => e
            raise
          rescue Exception => e
            warn "WARNING: Got \"#{e.message}\" from #{e.backtrace.first}"
          end while true
        else
          watch = EM.add_periodic_timer(10) {
            begin
              @@gm.watch_and_report
              watch.cancel if @@gm.all_done?

              if @@options[:terminate] and not (@@options[:list_trainer] or @@options[:qa])
#   TODO: Daemons           destroy_job_set_logic(@@remaining_jobs.select { |job| job.status == 0 })
                @@remaining_jobs.each do |job|
                  if job.status == 0
                    destroy_job_logic(job)
                  end
                end
              end
=begin
              # TODO
              if @@options[:list_trainer] or @@options[:qa]
                @@remaining_jobs.each do |job|
                  if job.status == 0
                    audit_log_deployment_logic(job.deployment, :interactive)
                    destroy_job_logic(job) if @@options[:terminate]
                  end
                end
              end
=end
            rescue Interrupt, NameError, ArgumentError, TypeError => e
              raise
            rescue Exception => e
              warn "WARNING: Got \"#{e.message}\" from #{e.backtrace.first}"
            end
          }
        end
      end
      (@@already_in_em ? evented_code[] : EM.run(&evented_code))
      unless @@gm.jobs.unanimous? { |job| job.status == 0 } and @@gm.jobs.first.status == 0
        error "Some jobs failed. Inspect the results at the given URL"
      end
    end

    # Encapsulates the logic for running through the log auditor/trainer on a single deployment
    def self.audit_log_deployment_logic(deployment, interactive = false)
      @@options[:runner] ||= get_runner_class
      raise "FATAL: Could not determine runner class" unless @@options[:runner]
      runner = @@options[:runner].new(deployment.nickname)
      puts runner.run_logger_audit(interactive, @@options[:qa])
    end

    # Encapsulates the logic for destroying the deployment from a single job
    def self.destroy_job_logic(job)
      @@options[:runner] ||= get_runner_class
      raise "FATAL: Could not determine runner class" unless @@options[:runner]
      runner = @@options[:runner].new(job.deployment.nickname)
      puts "Destroying successful deployment: #{runner.deployment.nickname}"

      # Before Destroy Hooks? (Only executes in the troop command)
      retry_block { before_destroy_logic(runner) } unless @@options[:keep] or @@command =~ /run|clone/

      # Call stop_all
      retry_block { runner.stop_all(false) }

      # After Destroy Hooks? (Only executes in the troop command)
      # TODO use threads to wait for servers to stop before destroying deployment
      unless @@options[:keep] or @@command =~ /run|clone/
        retry_block { runner.deployment.destroy }
        retry_block { after_destroy_logic(runner) }
        cleanup_state_dir(runner.deployment)
      end
      @@remaining_jobs.delete(job)
    end

=begin
    # Encapsulates the logic for destroying the deployments from a set of jobs
    def self.destroy_job_set_logic(job_set)
      # TODO: Daemons
      @@options[:runner] ||= get_runner_class
      raise "FATAL: Could not determine runner class" unless @@options[:runner]
      runner_hsh = {}
      job_set.each do |job|
        deploy = job.deployment
        runner_hsh[deploy.nickname] = @@options[:runner].new(deploy.nickname)
        runner = runner_hsh[deploy.nickname]

        # Before Destroy Hooks?
        unless @@options[:keep] or @@command =~ /run|clone/
          retry_block { before_destroy_logic(runner) } unless @@options[:keep]
          retry_block { runner.stop_all(false) }
        end
      end

      unless @@options[:keep]
        job_set.each do |job|
          deploy = job.deployment
          unless runner_hsh[deploy.nickname]
            runner_hsh[deploy.nickname] = @@options[:runner].new(deploy.nickname)
          end
          runner = runner_hsh[deploy.nickname]
          retry_block do
            deploy.servers_no_reload.each { |s|
              s.wait_for_state("stopped", ::VirtualMonkey::config[:stopped_timeout])
            }
          end
          retry_block { deploy.destroy }
          # After Destroy Hooks?
          retry_block { after_destroy_logic(runner) }
          cleanup_state_dir(deploy)
          @@remaining_jobs.delete(job)
        end
      end
    end
=end

    # Encapsulates the logic for destroying all matched deployments
    def self.destroy_all_logic
      error "Need Internal Testing API access to use this command." unless VirtualMonkey::Toolbox::api0_1?
      @@options[:runner] ||= get_runner_class
      raise "FATAL: Could not determine runner class" unless @@options[:runner]
      @@do_these ||= @@dm.deployments
      runner_hsh = {}
      @@do_these.each do |deploy|
        runner_hsh[deploy.nickname] = @@options[:runner].new(deploy.nickname)
        runner = runner_hsh[deploy.nickname]

        # Before Destroy Hooks?
        retry_block { before_destroy_logic(runner) } unless @@options[:keep]
        retry_block { runner.stop_all(false) }
      end

      unless @@options[:keep]
        @@do_these.each do |deploy|
          unless runner_hsh[deploy.nickname]
            runner_hsh[deploy.nickname] = @@options[:runner].new(deploy.nickname)
          end
          runner = runner_hsh[deploy.nickname]
          retry_block do
            deploy.servers_no_reload.each { |s|
              s.wait_for_state("stopped", ::VirtualMonkey::config[:stopped_timeout])
            }
          end
          retry_block { deploy.destroy }
          # After Destroy Hooks?
          retry_block { after_destroy_logic(runner) }
          cleanup_state_dir(deploy)
        end
      end
    end

    def self.cleanup_state_dir(deploy)
      retry_block do
        state_dir = File.join(VirtualMonkey::TEST_STATE_DIR, deploy.nickname)
        if File.directory?(state_dir)
          puts "Deleting state files for #{deploy.nickname}..."
          Dir.new(state_dir).each do |state_file|
            if File.extname(state_file) =~ /((rb)|(feature))/
              File.delete(File.join(state_dir, state_file))
            end
          end
          FileUtils.rm_rf(state_dir)
        end
      end
    end

    # Encapsulates the logic for running the before_destroy hooks for a particular runner
    def self.before_destroy_logic(runner)
      if @@options[:runner].respond_to?(:before_destroy)
        @@options[:runner].ancestors.select { |a| a.respond_to?(:before_destroy) }.each do |ancestor|
          if not ancestor.before_destroy.empty?
            puts "Executing before_destroy hooks..."
            ancestor.before_destroy.each { |fn|
              retry_block { (fn.is_a?(Proc) ? runner.instance_eval(&fn) : runner.__send__(fn)) }
            }
            puts "Finished executing before_destroy hooks."
          end
        end
      else
        warn "#{@@options[:runner]} doesn't extend VirtualMonkey::RunnerCore::CommandHooks"
      end
    end

    # Encapsulates the logic for running the after_destroy hooks for a particular runner
    def self.after_destroy_logic(runner)
      if @@options[:runner].respond_to?(:after_destroy)
        @@options[:runner].ancestors.select { |a| a.respond_to?(:after_destroy) }.each do |ancestor|
          if not ancestor.after_destroy.empty?
            puts "Executing after_destroy hooks..."
            ancestor.after_destroy.each { |fn|
              retry_block { (fn.is_a?(Proc) ? runner.instance_eval(&fn) : runner.__send__(fn)) }
            }
            puts "Finished executing after_destroy hooks."
          end
        end
      else
        warn "#{@@options[:runner]} doesn't extend VirtualMonkey::RunnerCore::CommandHooks"
      end
    end

    # Encapsulates the logic for detecting what runner is used in a test case file
    def self.get_runner_class #returns class string
      return @@options[:runner] if @@options[:runner]
      features = [@@options[:feature]].flatten
      test_cases = features.map { |feature| VirtualMonkey::TestCase.new(feature, @@options) }
      unless test_cases.unanimous? { |tc| tc.options[:runner] }
        raise ":runner options MUST match for multiple feature files"
      end
      unless test_cases.unanimous? { |tc| tc.options[:allow_meta_monkey] }
        raise ":allow_meta_monkey options MUST match for multiple feature files"
      end
      @@options[:runner] = test_cases.first.options[:runner]
      unless @@options[:runner].respond_to?(:assert_integrity!)
        warn "#{@@options[:runner]} doesn't extend VirtualMonkey::RunnerCore::CommandHooks"
        @@options[:runner].extend(VirtualMonkey::RunnerCore::CommandHooks)
      end
      @@options[:runner].assert_integrity!
      return @@options[:runner]
    end

    def self.load_features(config)
      features = [config['feature']].flatten.map do |feature|
        File.join(@@selected_project.paths["features"], feature)
      end
      test_cases = features.map { |feature| VirtualMonkey::TestCase.new(feature, @@options) }
      unless test_cases.unanimous? { |tc| tc.options[:runner] }
        raise ":runner options MUST match for multiple feature files"
      end
      unless test_cases.unanimous? { |tc| tc.options[:allow_meta_monkey] }
        raise ":allow_meta_monkey options MUST match for multiple feature files"
      end
      @@options[:allow_meta_monkey] = test_cases.first.options[:allow_meta_monkey]
      @@options[:runner] = test_cases.first.options[:runner]
      @@options[:feature] = features
    end

    def self.reconstruct_command_line(as=:String)
      if as == :String
        cmd_line = "#{@@command}"
      elsif as == :Array
        cmd_line = ["#{@@command}"]
      end
      command_flags = @@options.keys.map { |k| k.to_s =~ /^(.*)_given$/; $1 }.compact
      command_flags.map! { |k| k.to_sym }
      command_flags.each { |flag|
        if @@options["#{flag}_given".to_sym]
          actual_flag = "--#{flag.to_s.gsub(/_/, "-")}"
          if as == :String
            cmd_line += " #{actual_flag}"
            unless @@options[flag].is_a?(TrueClass) || @@options[flag].is_a?(FalseClass)
              cmd_line += " #{[@@options[flag]].flatten.map { |arg| arg.inspect }.join(" ")}"
            end
          elsif as == :Array
            cmd_line << "#{actual_flag}"
            unless @@options[flag].is_a?(TrueClass) || @@options[flag].is_a?(FalseClass)
              cmd_line += [@@options[flag]].flatten.map { |arg| "#{arg}" }
            end
          end
        end
      }
      return cmd_line
    end

    def self.retry_block(max_retries=VirtualMonkey::config[:max_retries], &block)
      begin
        yield()
      rescue Interrupt, NameError, ArgumentError, TypeError => e
        raise
      rescue StandardError, Timeout::Error => e
        warn "WARNING: Got \"#{e.message}\" from: #{e.backtrace.join("\n")}"
        raise if @@options[:force]
        sleep 5
        max_retries -= 1
        (max_retries > 0) ? (retry) : (raise)
      end
    end

    def self.countdown(secs)
      begin
        Array(1..secs).reverse.each do |i|
          if i <= (secs / 4)
            puts "#{i}...".apply_color(:red)
          elsif i <= (secs / 2)
            puts "#{i}...".apply_color(:yellow)
          else
            puts "#{i}...".apply_color(:green)
          end
          sleep 1
        end
        return true
      rescue Interrupt
        return false
      end
    end

    def self.selected_project
      @@selected_project ||= nil
    end

    def self.selected_project=(proj)
      proj = nil unless proj.is_a?(VirtualMonkey::CollateralProject)
      @@selected_project = proj || selected_project
    end

    ##################################
    # Onboarding/File-Creation Logic #
    ##################################
    def self.interactive_select_project_logic
      @@selected_project = VirtualMonkey::Manager::Collateral[@@options[:project]]
      @@selected_project ||= case VirtualMonkey::Manager::Collateral::Projects.size
      when 0 then error "No collateral projects available locally. Please run 'monkey collateral --help'"
      when 1 then VirtualMonkey::Manager::Collateral::Projects.first
      else
        proj_name = choose do |menu|
          menu.prompt = "Which project should be used?"
          menu.index = :number
          menu.choices(*(VirtualMonkey::Manager::Collateral::Projects.map { |proj| proj.name }))
        end
        VirtualMonkey::Manager::Collateral[proj_name]
      end
    end

    def self.build_scenario_names(underscore_name = " ")
      assert_tty
      if underscore_name != " "
        if ask("Is \"#{underscore_name.gsub(/ |\./,"_")}\" an acceptable name for this scenario (y/n)?", lambda { |ans| ans =~ /^[yY]/ })
          underscore_name.gsub!(/ |\./,"_")
        else
          underscore_name = " "
        end
      end

      while underscore_name.gsub!(/ |\./,"")
        underscore_name = ask("What is the name for this runner? (Please use underscores instead of spaces and periods), eg. 'mysql', 'php_chef', etc.)")
      end
      @@underscore_name = underscore_name.downcase
      @@camel_case_name = @@underscore_name.camelcase
      @@common_inputs_file = File.join(@@selected_project.paths["common_inputs"], "#{@@underscore_name}.json")
      @@feature_file = File.join(@@selected_project.paths["features"], "#{@@underscore_name}.rb")
      @@mixin_file = File.join(@@selected_project.paths["mixins"], "#{@@underscore_name}.rb")
      @@runner_file = File.join(@@selected_project.paths["runners"], "#{@@underscore_name}_runner.rb")
      @@troop_file = File.join(@@selected_project.paths["troops"], "#{@@underscore_name}.json")

      @@script_table = []
    end

    def self.build_script_array(st_ary)
      st_ary.uniq_by { |st| st.href }.each { |st|
        script_array = []
        op_execs = st.executables.select { |rs| rs.apply == "operational" }
        op_exec_names = op_execs.map { |rs| rs.recipe ? rs.recipe : rs.right_script["name"] }
        op_exec_names.each { |rs_name|
          @@script_table << [(@@script_table.length + 1), rs_name, st]
        }
      }
    end

    def self.build_troop_config(deployment = nil)
      assert_tty

      @@troop_config = {}
      @@troop_config[:prefix] = "#{@@underscore_name.upcase}_TROOP"
      @@st_table = []
      @@st_inputs = {}

      if deployment
        # Model Deployment Given
        st_ary = []
        deployment.servers_no_reload.each { |s|
          st = ServerTemplate.find(s.server_template_href.split(/\//).last.to_i)
          st_ary << st
          @@st_table << [s, st]
          if VirtualMonkey::Toolbox::api1_5?
            @@st_inputs[st.rd_id] = McServerTemplate.find(st.rs_id.to_i).get_inputs
          end
        }
        @@troop_config[:server_template_ids] = st_ary.map { |st| st.rs_id.to_s }
      else
        # Interactively Build
        correct = false
        until correct
          st_ary = []
          @@troop_config[:server_template_ids] = ask("What Server Template ids would you like to use to create the deployments (comma delimited)?").split(",")
          @@troop_config[:server_template_ids].each { |st|
            st.strip!
            st = ServerTemplate.find(st.to_i)
            st_ary << st
            @@st_table << [s, st]
            if VirtualMonkey::Toolbox::api1_5?
              @@st_inputs[st.rd_id] = McServerTemplate.find(st.rs_id.to_i).get_inputs
            end
          }
          puts st_ary.map { |st| st.nickname }.join("\n")
          correct = ask("Are these the ServerTemplates that you wish to use with this runner? (y/n)", lambda { |ans| ans =~ /^[yY]/ })
        end

        puts "Available Clouds for this Account (Note that your MCI's may not support all of these):"
        VirtualMonkey::Toolbox::get_available_clouds().each { |cloud| puts "#{cloud['cloud_id']}: #{cloud['name']}" }
        list_of_clouds = ask("Enter a comma-delimited list of cloud_ids to use:").split(",")
        @@troop_config[:clouds] = list_of_clouds.map { |c| c.to_i }
      end

      build_script_array(st_ary)
      @@st_ary = st_ary

      @@troop_config[:common_inputs] = File.basename(@@common_inputs_file)
      @@troop_config[:feature] = File.basename(@@feature_file)
    end

    def self.write_common_inputs_file(input_hash={"EXAMPLE_INPUT" => "text:value"})
      say("Creating example common inputs file...")
      write_out = input_hash.to_json( :indent => "  ",
                                      :object_nl => "\n",
                                      :array_nl => "\n" )
      File.open(@@common_inputs_file, "w") { |f| f.write(write_out) }
    end

    def self.write_feature_file
      say("Creating feature file...")
      contents =<<EOS
set :runner, VirtualMonkey::Runner::#{@@camel_case_name}

hard_reset do
  stop_all
end

before do
  launch_all
  wait_for_all("operational")
end

test "check_monitoring" do
  check_monitoring
end
EOS
      # Add Script Tests
      @@script_table.each { |index,script,st|
        contents +=<<EOS
###{"#" * script.length}##
# #{script} #
###{"#" * script.length}##

before "script_#{index}" do
end

test "script_#{index}" do
  run_script_on_set("script_#{index}", server_templates.detect { |st| st.nickname =~ #{Regexp.new(Regexp.escape(st.nickname)).inspect} }, true, {})
end

after "script_#{index}" do
end

EOS
      }
      contents +=<<EOS
after do
  # Cleanup
end
EOS
      File.open(@@feature_file, "w") { |f| f.write(contents) }
    end

    def self.write_troop_file
      say("Creating troop config...")
      write_out = @@troop_config.to_json( :indent => "  ",
                                          :object_nl => "\n",
                                          :array_nl => "\n" )
      File.open(@@troop_file, "w") { |f| f.write(write_out) }
    end

    def self.write_mixin_file
      say("Creating mixin file...")
      mixin_tpl =<<EOS
module VirtualMonkey
  module Mixin
    module #{@@camel_case_name}
      extend VirtualMonkey::RunnerCore::CommandHooks
EOS
      # Lookup Scripts
      mixin_tpl += <<EOS
      # Every instance method included in the runner class that has
      # "lookup_scripts" in its name is called when the Class is instantiated.
      # These functions help to create a hash table of RightScripts and/or
      # Chef Recipes that can be called on a given Server in the deployment.
      # By default, the functions that are used to create this hash table
      # allow every referenced Executable to be run on every server in the
      # deployment, but they can be restricted to only certain ServerTemplates
      # in the deployment.
      def #{@@underscore_name}_lookup_scripts
EOS
      st_ary = @@script_table.map { |index,script,st| st }.uniq_by { |st| st.href }
      st_ary.each { |st_ref|
        st_script_table = @@script_table.select { |index,script,st| st.href == st_ref.href }
        st_ver = (st_ref.is_head_version ? "[HEAD]" : "[rev #{st_ref.version}]")
        comment_string = "# Load Scripts from '#{st_ref.nickname}' #{st_ver} #"
        mixin_tpl += "        #{"#" * comment_string.length}\n"
        mixin_tpl += "        #{comment_string}\n"
        mixin_tpl += "        #{"#" * comment_string.length}\n"
        mixin_tpl += "        scripts = [\n"
        script_array = st_script_table.map { |index,script,st|
          "                   ['script_#{index}', #{Regexp.new(Regexp.escape(script)).inspect}]"
        }
        mixin_tpl += "#{script_array.join(",\n")}\n"
        mixin_tpl += "                  ]\n"
        mixin_tpl += "        st_ref = @server_templates.detect { |st| st.nickname =~ #{Regexp.new(Regexp.escape(st_ref.nickname)).inspect} }\n"
        mixin_tpl += "        load_script_table(st_ref, scripts, st_ref)\n\n"
      }
      mixin_tpl += "      end\n"

=begin
      # Sample RunScript
      unless script_array.empty?
        mixin_tpl += <<EOS
EOS
      end
=end
      # Exception Handle
      mixin_tpl += <<EOS

      # Every instance method included in the runner class that has
      # "exception_handle" in its name is called when an unhandled exception
      # is raised through a behavior (without a verification block). These
      # functions create a library of dynamic exception handling for common
      # scenarios. Exception_handle methods should return true if they have
      # handled the exception, or return false otherwise.
      def #{@@underscore_name}_exception_handle(e)
        if e.message =~ /INSERT YOUR RETRY-ABLE ERROR HERE/
          warn "Got 'RETRY-ABLE ERROR'. Retrying..."
          sleep 30
          return true # Exception Handled
        elsif e.message =~ /INSERT YOUR IGNORE-ABLE ERROR HERE/
          warn "Got 'IGNORE-ABLE ERROR'. Continuing tests..."
          continue_test
          return true # Exception Handled
        else
          return false # Exception Not Handled
        end
      end
EOS

      # Black, White, Need lists
      MessageCheck::LISTS.each { |list|
        regex_ary = { MessageCheck::WHITELIST => ["harmless", "ignore"],
                      MessageCheck::BLACKLIST => ["exception", "error"],
                      MessageCheck::NEEDLIST => ["this should be here", "required line"] }
        mixin_tpl += <<EOS

      # Every instance method included in the runner class that has
      # "#{list}" in its name is called when the Class is instantiated.
      # These functions add entries to the #{list} for log auditing.
      # The function must return an array of length-3 arrays with the fields
      # as follows:
      #
      # [ "/path/to/log/file", "server_template_name_regex", "matching_regex" ]
      def #{@@underscore_name}_#{list}
        [
          #["/var/log/messages", "#{@@st_ary.first.nickname}", "#{regex_ary[list].first}"],
          #["/var/log/messages", "#{@@st_ary.last.nickname}", "#{regex_ary[list].last}"]
        ]
      end
EOS
      }

      mixin_tpl += <<EOS
    end
  end
end
EOS
      File.open(@@mixin_file, "w") { |f| f.write(mixin_tpl) }
    end

    def self.write_runner_file(add_set_input_fn = nil)
      say("Creating runner file...")
      runner_tpl =<<EOS
module VirtualMonkey
  module Runner
    class #{@@camel_case_name}
      extend VirtualMonkey::RunnerCore::CommandHooks
      include VirtualMonkey::RunnerCore::DeploymentBase
      include VirtualMonkey::Mixin::#{@@camel_case_name}

      # Write a meaningful description of what this Runner tests
      description ""

      ########################
      # Monkey Command Hooks #
      ########################

      # Uncomment the next line to enable the before_create hook. NOTE: Unlike the other hooks,
      # this hook is executed BEFORE A DEPLOYMENT EXISTS, so any code placed in here will not be
      # able to access typical Runner methods and attributes.
      # before_create { puts "Happens before 'monkey create' creates a deployment" }

      # Uncomment the next line to enable the before_destroy hook
      # before_destroy { puts "Happens before 'monkey destroy' destroys a deployment" }

      # Uncomment the next line to enable the after_create hook
      # after_create { puts "Happens after 'monkey create' creates a deployment" }

      # Uncomment the next line to enable the after_destroy hook
      # after_destroy { puts "Happens after 'monkey destroy' destroys a deployment" }

      ###########################################
      # Override any functions from mixins here #
      ###########################################

EOS
      if add_set_input_fn
        # input_table should be built as:
        # {
        #   120567: [
        #     {"INPUT_A": "VALUE_A", "INPUT_B": "VALUE_B"},
        #     {"INPUT_A": "VALUE_A", "INPUT_B": "VALUE_B"},
        #     {"INPUT_A": "VALUE_A", "INPUT_B": "VALUE_B"}
        #   ],
        #   121843: [
        #     {"INPUT_A": "VALUE_A", "INPUT_B": "VALUE_B"}
        #   ]
        # }
        input_ref = {}
        @@st_table.each { |s,st|
          next unless @@individual_server_inputs[s.rs_id.to_i]
          @@individual_server_inputs[s.rs_id.to_i].reject! { |input,value|
            value == "text:" || @@common_inputs[input] == value
          }
          @@individual_server_inputs[s.rs_id.to_i].each { |input,value|
            if @@st_inputs[st.rs_id.to_i][input] == value
              @@individual_server_inputs[s.rs_id.to_i].delete(input)
            end
          }
          input_ref[st.rs_id.to_i] ||= []
          input_ref[st.rs_id.to_i] << @@individual_server_inputs[s.rs_id]
        }
        unless input_ref.empty?
          runner_tpl += "      def set_inputs\n"
          input_ref.each { |st_id,ary|
            st = @@st_table.select { |s,st| st.rs_id.to_i == st_id }.first.last
            runner_tpl += "        server_array = select_set(@server_templates.detect { |st| st.nickname =~ #{Regexp.new(Regexp.escape(st.nickname)).inspect} })\n"
            ary.each_with_index { |input_hsh,idx|
              runner_tpl += "        server_array[#{idx}].set_inputs(#{input_hsh.inspect})\n"
            }
            runner_tpl += "\n"
          }
          runner_tpl += "      end\n"
        end
      end
      runner_tpl += <<EOS
    end
  end
end
EOS
      File.open(@@runner_file, "w") { |f| f.write(runner_tpl) }
    end
  end
end
