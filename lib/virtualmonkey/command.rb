#!/usr/bin/env ruby
require 'rubygems'
require 'trollop'
require 'highline/import'
require 'uri'
require 'pp'

module VirtualMonkey
  module Command
    AvailableCommands = {
      :api_check                  => %q{Verify API version connectivity},
      :clone                      => %q{Clone a deployment n times and run though feature tests},
      :collateral                 => %q{Manage test collateral repositories using git},
      :config                     => %q{Get and set advanced variables that control VirtualMonkey behavior},
      :create                     => %q{Create MCI and Cloud permutation Deployments for a set of ServerTemplates},
      :destroy                    => %q{Destroy a set of Deployments},
      :destroy_ssh_keys           => %q{Destroy VirtualMonkey-generated SSH Keys},
      :environment                => %q{Sets the monkey config variables to presets for certain usage patterns},
      :generate_ssh_keys          => %q{Generate SSH Key files per Cloud and stores their hrefs in ssh_keys.json},
      :import_deployment          => %q{Import an existing Deployment and create a new testing scenario for it},
      :list                       => %q{List the full Deployment nicknames and Server statuses for a set of Deployments},
      :new_troop_config           => %q{Interactively create a new Troop Config JSON File},
      :new_runner                 => %q{Interactively create a new testing scenario and all necessary files},
      :populate_all_cloud_vars    => %q{Populates ssh_keys.json, datacenters.json, instance_types.json, and security_groups.json for all clouds},
      :populate_datacenters       => %q{Populates datacenters.json with API 1.5 hrefs per Cloud},
      :populate_instance_types    => %q{Populates instance_types.json with API 1.5 hrefs per Cloud},
      :populate_security_groups   => %q{Populates security_groups.json with appropriate hrefs per Cloud},
      :run                        => %q{Execute a set of feature tests across a set of Deployments in parallel},
      :troop                      => %q{Calls "create", "run", and "destroy" for a given troop config file},
      :update_inputs              => %q{Updates the inputs and editable server parameters for a set of Deployments},
      :version                    => %q{Displays version and exits},
      :help                       => %q{Displays usage information}
    }

    NonInteractiveCommands = AvailableCommands.reject { |cmd,desc|
      [:new_troop_config, :new_runner, :import_deployment].include?(cmd)
    }

    AvailableQACommands = {
      :alpha      => "",
      :beta       => "",
      :ga         => "",
      :log_audit  => "",
      :port_scan  => "",
      :version    => "Displays version and exits",
      :help       => "Displays usage information"
    }

    Flags = {
      :terminate        => {:opts => {:short => '-a',  :type => :boolean},
                            :desc => 'Terminate if tests successfully complete. (No destroy)'},
      :common_inputs    => {:opts => {:short => '-c',  :type => :strings},
                            :desc => 'Input JSON files to be set at Deployment AND Server levels'},
      :deployment       => {:opts => {:short => '-d',  :type => :string},
                            :desc => 'regex string to use for matching deployment'},
      :exclude_tests    => {:opts => {:short => '-e',  :type => :strings},
                            :desc => 'List of test names to exclude from running across Deployments'},
      :config_file      => {:opts => {:short => '-f',  :type => :string},
                            :desc => 'Troop Config JSON File'},
      :clouds           => {:opts => {:short => '-i',  :type => :integers},
                            :desc => 'Space-separated list of cloud_ids to use'},
      :keep             => {:opts => {:short => '-k',  :type => :boolean},
                            :desc => 'Do not delete servers or deployments after terminating'},
      :use_mci          => {:opts => {:short => '-m',  :type => :string,   :multi => true},
                            :desc => 'List of MCI hrefs to substitute for the ST-attached MCIs'},
      :n_copies         => {:opts => {:short => '-n',  :type => :integer,  :default => 1},
                            :desc => 'Number of clones to make'},
      :only             => {:opts => {:short => '-o',  :type => :string,   :multi => true},
                            :desc => 'Regex string to use for subselection matching on MCIs'},
      :no_spot          => {:opts => {:short => :none, :type => :boolean,  :default => true},
                            :desc => 'do not use spot instances'},
      :no_resume        => {:opts => {:short => '-r',  :type => :boolean},
                            :desc => 'Do not use trace info to resume a previous test'},
      :tests            => {:opts => {:short => '-t',  :type => :strings},
                            :desc => 'List of test names to run across Deployments (default is all)'},
      :verbose          => {:opts => {:short => '-v',  :type => :boolean},
                            :desc => 'Print all output to STDOUT as well as the log files'},
      :revisions        => {:opts => {:short => '-w',  :type => :integers},
                            :desc => 'Specify a list of revision numbers for templates (0 = HEAD)'},
      :prefix           => {:opts => {:short => '-x',  :type => :string},
                            :desc => 'Prefix of the Deployments'},
      :yes              => {:opts => {:short => '-y',  :type => :boolean},
                            :desc => 'Turn off confirmation'},
      :one_deploy       => {:opts => {:short => '-z',  :type => :boolean},
                            :desc => 'Load all variations of a single ST into one Deployment'},

      # Capital Letters
      :force            => {:opts => {:short => '-F',  :type => :boolean},
                            :desc => 'Forces command to attempt to continue even if an exception is raised'},
      :overwrite        => {:opts => {:short => '-O',  :type => :boolean},
                            :desc => 'Replace existing resources with fresh ones'},
      :report_metadata  => {:opts => {:short => '-R',  :type => :boolean},
                            :desc => 'Report metadata to SimpleDB'},
      :report_tags      => {:opts => {:short => '-T',  :type => :strings},
                            :desc => 'Additional tags to help database sorting (e.g. -T sprint28)'},
      :project          => {:opts => {:short => '-P',  :type => :string},
                            :desc => 'Specify which collateral project to use'},

      # Additional Options
      :security_group_name  => {:opts => {:short => :none,  :type => :string},
                                :desc => 'Populate the file with this security group'},
      :ssh_keys             => {:opts => {:short => :none,  :type => :string},
                                :desc => 'Takes a JSON object of cloud ids mapped to ssh_key ids. (e.g. {1: 123456, 2: 789012})'},
      :api_version          => {:opts => {:short => '-a',   :type => :float},
                                :desc => 'Check to see if the monkey has RightScale API access'},
      :started_at           => {:opts => {:short => :none,  :type => :string},
                                :desc => 'Override started_at variable (requires base64-encoded, marshalled Time object)'},
    }

    EnvironmentPresets = {
      "development" => {"desc" => "ServerTemplate Developers need to work efficiently. These " +
                                  "presets are designed to encourage small, independent tests " +
                                  "that can be run in any order. Developers should also primarily " +
                                  "use the grinder tool, to enable inline debugging.",
                        "values" => {
                          "environment"         => "development",
                          "test_permutation"    => "distributive",
                          "test_ordering"       => "random",
                          "grinder_subprocess"  => "allow_same_process",
                          "enable_log_auditor"  => true,
                          "max_retries"         => 3,
                        }
      },
      "testing"     => {"desc" => "ServerTemplate Testers need to be thorough, and must produce " +
                                  "reports. These presets are designed to make runs repeatable, " +
                                  "accountable, and--most importantly--thorough.",
                        "values" => {
                          "environment"         => "testing",
                          "test_permutation"    => "exhaustive",
                          "test_ordering"       => "strict",
                          "grinder_subprocess"  => "force_subprocess",
                          "enable_log_auditor"  => false,
                          "max_retries"         => 10,
                        }
      },
      "sixsigma"    => {"desc" => "SixSigma is a concept from manufacturing meant to minimize " +
                                  "the rate of defects to 3.4 per million. Due to the nature of " +
                                  "distributed systems, it is highly unlikely that this testing " +
                                  "mode will ever pass, but it can be useful in identifying problems.",
                        "values" => {
                          "environment"         => "sixsigma",
                          "test_permutation"    => "exhaustive",
                          "test_ordering"       => "random",
                          "grinder_subprocess"  => "force_subprocess",
                          "enable_log_auditor"  => true,
                          "max_retries"         => 5,
                        }
      }
    }

    ConfigOptions = {
      "set"     => {"desc"  => "Set a configurable variable",
                    "usage" => "'monkey config (-s|--set|set) <name> <value>'"},

      "edit"    => {"desc"  => "Open config file in your git editor",
                    "usage" => "'monkey config (-e|--edit|edit)'"},

      "unset"   => {"desc"  => "Unset a configurable variable",
                    "usage" => "'monkey config (-u|--unset|unset) <name>'"},

      "list"    => {"desc"  => "List current config variables",
                    "usage" => "'monkey config (-l|--list|list)'"},

      "catalog" => {"desc"  => "List all possible configurable variables",
                    "usage" => "'monkey config (-c|--catalog|catalog)'"},

      "get"     => {"desc"  => "Get the value of one variable",
                    "usage" => "'monkey config (-g|--get|get) <name>'"},

      "help"    => {"desc"  => "Print this help message",
                    "usage" => "'monkey config (-h|--help|help)'"}
    }

    ConfigVariables = {
      "test_permutation"    => {"desc"    => "Controls how individual test cases in a feature file get assigned per deployment",
                                "default" => "exhaustive",
                                "values"  => ["distributive", "exhaustive"]},

      "test_ordering"       => {"desc"    => "Controls how individual test cases in a feature file are ordered for execution",
                                "default" => "strict",
                                "values"  => ["random", "strict"]},

      "feature_mixins"      => {"desc"    => "Controls how multiple features are distributed amongst available deployments",
                                "default" => "spanning",
                                "values"  => ["spanning", "parallel"]},

      "load_progress"       => {"desc"    => "Turns on/off the display of load progress info for 'monkey' commands",
                                "default" => "show",
                                "values"  => ["show", "hide"]},

      "colorized_text"      => {"desc"    => "Turns on/off colorized console text",
                                "default" => "show",
                                "values"  => ["show", "hide"]},

      "max_jobs"            => {"desc"    => "Controls how many simultaneous jobs can be started through the SpiderMonkey Web App",
                                "default" => 2,
                                "values"  => Integer},

      "max_retries"         => {"desc"    => "Controls how many retries to attempt in a scope stack before giving up",
                                "default" => 10,
                                "values"  => Integer},

      "default_timeout"     => {"desc"    => "Controls the default timeout for server actions",
                                "default" => (20*60),
                                "values"  => Integer},

      "enable_log_auditor"  => {"desc"    => "Enables log auditing for logfiles defined in lists/*.json",
                                "default" => "false",
                                "values"  => [false, true]},

      "environment"         => {"desc"    => "Allows different behaviors in runners based on the environment",
                                "default" => "testing",
                                "values"  => EnvironmentPresets.keys},

      "grinder_subprocess"  => {"desc"    => "Turns on/off the ability of Grinder to load into the current process",
                                "default" => "force_subprocess",
                                "values"  => ["allow_same_process", "force_subprocess"]},

      "throttling_values"   => {"desc"    => "All throttling values across all clouds",
                                "default" => {},
                                "values"  => Hash},
    }

    CollateralOptions = {
      "clone"     => {"desc"  => "Clone a remote repository into the local collateral",
                      "usage" => "'monkey collateral (-c|--clone|clone) <repository> <project> [--bare] [--depth <i>]'"},

      "init"      => {"desc"  => "Create a new local collateral project",
                      "usage" => "'monkey collateral (-i|--init|init) <project>'"},

      "checkout"  => {"desc"  => "Checkout a branch or paths to the working tree of the specified collateral project",
                      "usage" => "'monkey collateral (-k|--checkout|checkout) <project> <name> [-f|--force]'"},

      "pull"      => {"desc"  => "Fetch from and merge with a local collateral project",
                      "usage" => "'monkey collateral (-p|--pull|pull) <project> [<remote> [<branch>]]'"},

      "list"      => {"desc"  => "List the local collateral projects, origin repositories, and current branches",
                      "usage" => "'monkey collateral (-l|--list|list)'"},

      "delete"    => {"desc"  => "Delete a local collateral project",
                      "usage" => "'monkey collateral (-d|--delete|delete) <project>'"},

      "help"      => {"desc"  => "Print this help message",
                      "usage" => "'monkey collateral (-h|--help|help)'"}
    }

    CommandFlags = {}

    def self.init(*args)
      # Monkey available_commands
      @@available_commands = AvailableCommands
      @@basic_commands = AvailableCommands.reject { |key,val|
        ![:api_check, :collateral, :create, :destroy, :environment,
          :import_deployment, :list, :run, :version, :help].include?(key)
      }

      # QA available_commands
      @@available_qa_commands = AvailableQACommands

      @@flags = Flags

      @@version_string = "VirtualMonkey #{VirtualMonkey::VERSION}"

      # Regular message
      unless class_variable_defined?("@@usage_msg")
        @@usage_msg = "\nAll valid commands for #{@@version_string}:\n\n"
        @@usage_msg += pretty_help_message(@@available_commands)
        @@usage_msg += "\n\nHelp usage: 'monkey help <command>' OR 'monkey <command> --help'\n\n"
        @@usage_msg = word_wrap(@@usage_msg)
      end

      unless class_variable_defined?("@@simple_usage_msg")
        @@simple_usage_msg = "\nBasic commands for #{@@version_string}:\n\n"
        @@simple_usage_msg += pretty_help_message(@@basic_commands)
        @@simple_usage_msg += "\n\nHelp usage: 'monkey help <command>' OR 'monkey <command> --help'\n" +
                              "To see all available virtualmonkey commands: 'monkey help all'\n\n" +
                              "If this is your first time using VirtualMonkey, ensure that you have at least one " +
                              "collateral project checked out by running 'monkey collateral --list'.\n" +
                              "Once you have a collateral project, then run 'monkey import_deployment' to " +
                              "create new collateral based on that example deployment.\n\n"
        @@simple_usage_msg = word_wrap(@@simple_usage_msg)
      end

      # QA Mode message
=begin
      unless class_variable_defined?("@@qa_usage_msg")
        @@qa_usage_msg = "\nValid commands for #{@@version_string} (QA mode):\n\n"
        @@qa_usage_msg += pretty_help_message(@@available_qa_commands)
        @@qa_usage_msg += "\n\nHelp usage: 'qa help <command>' OR 'qa <command> --help'\n\n"
      end
=end

      # Parse any passed args and put them in ARGV if they exist
      if args.length > 1
        ARGV.replace args
      elsif args.length == 1
        ARGV.replace args.first.split(/ /)
      end
    end

    # Reset class variables to nil
    def self.reset
      @@dm = nil
      @@gm = nil
      @@remaining_jobs = nil
      @@do_these = nil
      @@command = nil
      @@st_table = nil
      @@individual_server_inputs = nil
      @@st_inputs = nil
      @@common_inputs = nil
      @@last_command_line = nil
      @@selected_project = nil
    end

    # Parses the initial command string, removing it from ARGV, then runs command.
    def self.go(*args)
      self.init(*args)
      @@command = ARGV.shift || "help"
      if @@available_commands[@@command.to_sym]
        VirtualMonkey::Command.__send__(@@command)
      elsif @@command == "-h" or @@command == "--help"
        VirtualMonkey::Command.help
      else
        warn "Invalid command #{@@command}\n\n#{@@usage_msg}"
        exit(1)
      end
    end

    def self.use_options
      #("text '  monkey #{@@command} [options...]\n\n #{@@available_commands[@@command.to_sym]}';" +
      #CommandFlags["#{@@command}"].map { |op| @@flags[op] }.join(";"))
      ret = "text ' monkey #{@@command} [options...]\n\n #{AvailableCommands[@@command.to_sym]}'; "
      ret += CommandFlags["#{@@command}"].map { |op|
        "opt #{op.to_sym.inspect}, #{Flags[op][:desc].inspect}, #{Flags[op][:opts].inspect}"
      }.join("; ")
      ret
    end

    def self.add_command(command_name, command_flags=[], more_opts=[], flagless=false, &block)
      command_name = command_name.to_s.downcase
      CommandFlags.merge!(command_name => command_flags.sort { |a,b| a.to_s <=> b.to_s })
      self.instance_eval <<EOS
        def #{command_name}(*args)
          self.init(*args)
          @@command = "#{command_name}"
          puts ""
          @@options = Trollop::options do
            eval(VirtualMonkey::Command::use_options)
            #{more_opts.join("; ")}
          end

          @@last_command_line = VirtualMonkey::Command::reconstruct_command_line()
          if @@last_command_line == "#{command_name}"
            ans = "y"
            if #{flagless && true} && tty?
              ans = ask("Do you want to print help for 'monkey #{command_name}' (y/n)?")
            end
            #{command_name}("--help") if ans =~ /^[yY]/
          end

          self.instance_eval(&(#{block.to_ruby}))
          puts ("\nCommand 'monkey " + @@last_command_line + "' finished successfully.").apply_color(:green)
          reset()
        end
EOS
    end

    # Help command
    CommandFlags.merge!("help" => [])
    def self.help(*args)
      self.init(*args)
      case subcommand = ARGV.shift
      when nil then puts @@simple_usage_msg
      when "--all", "-a", "all", "commands", "help", "-h", "--help" then puts @@usage_msg
      else
        ENV['REST_CONNECTION_LOG'] = "/dev/null"
        @@command = subcommand
        VirtualMonkey::Command.__send__(subcommand, "--help")
      end
      reset()
    end

    # Version command
    CommandFlags.merge!("version" => [])
    def self.version(*args)
      self.init(*args)
      puts @@version_string
      reset()
    end

    def self.last_command_line
      @@last_command_line ||= ""
    end

    def self.pretty_help_message(content_hash)
      double_spaced = false
      return "" if content_hash.empty?
      max_key_width = content_hash.keys.map { |k| k.to_s.length }.max
      remaining_width = (tty_width || 80).to_i - (max_key_width + "  :   ".size + 2)
      key_format_string = "  %#{max_key_width}s:   "
      field_format_string = "%-#{remaining_width}s"
      base_format_string = key_format_string + field_format_string
      val_format_string = "#{" " * (max_key_width + 6)}#{field_format_string}"
      sorted_content_ary = content_hash.to_a.sort { |a,b| a.first.to_s <=> b.first.to_s }
      message = []
      case content_hash.values.first
      when Hash
        double_spaced = true
        message = sorted_content_ary.map do |k,v|
          fmt_string_ary = []
          wrapped_ary = []
          if v["desc"]
            fmt_string_ary << base_format_string
            text = v["desc"]
            if text.size <= remaining_width
              wrapped_ary << text
            else
              wrapped_val_ary = word_wrap(text, remaining_width).split("\n")
              fmt_string_ary += [val_format_string] * (wrapped_val_ary.size - 1)
              wrapped_ary += wrapped_val_ary
            end
          end
          v.keys.sort.each { |type|
            text = ""
            case type
            when "desc" then next
            when "values", "origin", "branch" then text = "#{type.titlecase}: #{v[type].inspect}"
            when "usage" then text = "#{type.titlecase}: #{v[type]}"
            end
            if text.size <= remaining_width
              fmt_string_ary << val_format_string
              wrapped_ary << text
            else
              wrapped_val_ary = word_wrap(text, remaining_width).split("\n")
              fmt_string_ary += [val_format_string] * wrapped_val_ary.size
              wrapped_ary += wrapped_val_ary
            end
          }
          unless v["desc"]
            fmt_string_ary.shift
            fmt_string_ary.unshift(field_format_string)
          end
          fmt_string = fmt_string_ary.join("\n")
          fmt_string = key_format_string + fmt_string unless v["desc"]
          fmt_string % ([k] + wrapped_ary)
        end
      else
        message = sorted_content_ary.map do |k,v|
          ret = ""
          v = v.inspect unless String === v
          if v.size <= remaining_width
            ret = base_format_string % [k,v]
          else
            double_spaced = true
            wrapped_ary = word_wrap(v, remaining_width).split("\n")
            fmt_string = ([base_format_string] + ([val_format_string] * (wrapped_ary.size - 1))).join("\n")
            ret = fmt_string % ([k] + wrapped_ary)
          end
          ret
        end
      end
      (double_spaced ? message.join("\n\n") : message.join("\n"))
    end

    def self.word_wrap(txt, width=(tty_width || 80).to_i)
      txt.gsub(/(.{1,#{width}})( +|$\n?)|(.{1,#{width}})/, "\\1\\3\n")
    end

    # Config commands
    CommandFlags.merge!("config" => ConfigOptions.keys)
    def self.config(*args)
      self.init(*args)
      @@command = "config"

      unless class_variable_defined?("@@config_help_message")
        @@config_help_message = "  monkey config [options...]\n\n "
        @@config_help_message += @@available_commands[@@command.to_sym] + "\n"
        @@config_help_message += pretty_help_message(ConfigOptions)
      end

      @@last_command_line = "#{@@command} #{ARGV.join(" ")}"

      # Variable Initialization
      config_file = VirtualMonkey::ROOT_CONFIG
      configuration = VirtualMonkey::config.dup

      # Print Help?
      if ARGV.empty? or not (ARGV & ['--help', '-h', 'help']).empty?
        if ARGV.empty?
          puts pretty_help_message(configuration) unless configuration.empty?
        end
        puts "\n#{@@config_help_message}\n\n"
        exit(0)
      end

      # Subcommands
      improper_argument_error = word_wrap("FATAL: Improper arguments for command '#{ARGV[0]}'.\n\n#{@@config_help_message}\n")

      case ARGV[0]
      when "set", "-s", "--set", "add", "-a", "--add"
        if ARGV.length == 1
          # print catalog
          puts "\n  Available config variables:\n\n#{self.pretty_help_message(ConfigVariables)}\n\n"
        else
          error improper_argument_error if ARGV.length != 3
          if check_variable_value(ARGV[1], ARGV[2])
            configuration[ARGV[1].to_sym] = convert_value(ARGV[2], ConfigVariables[ARGV[1].to_s]["values"])
          else
            error "FATAL: Invalid variable or value. Run 'monkey config catalog' to view available variables."
          end
          File.open(config_file, "w") { |f| f.write(configuration.to_yaml) }
        end

      when "edit", "-e", "--edit"
        assert_tty
        error improper_argument_error if ARGV.length != 1
        editor = `git config --get core.editor`.chomp
        editor = "vim" if editor.empty?
        config_ok = false
        puts "\n  Available config variables:\n\n#{self.pretty_help_message(ConfigVariables)}\n\n"
        ask("Press Enter to edit using #{editor}")
        until config_ok
          exit_status = system("#{editor} '#{config_file}'")
          begin
            temp_config = YAML::load(IO.read(config_file))
            config_ok = temp_config.reduce(exit_status) do |bool,ary|
              bool && check_variable_value(ary[0], ary[1])
            end
            raise "Invalid variable or variable value in config file" unless config_ok
          rescue Exception => e
            warn e.message
            ask("Press enter to continue editing")
          end
        end

      when "unset", "-u", "--unset"
        error improper_argument_error if ARGV.length != 2
        if ConfigVariables.keys.include?(ARGV[1])
          configuration.delete(ARGV[1].to_sym)
        else
          error "FATAL: '#{ARGV[1]}' is an invalid variable.\n  Available config variables:\n\n#{self.pretty_help_message(ConfigVariables)}\n\n"
        end
        File.open(config_file, "w") { |f| f.write(configuration.to_yaml) }

      when "list", "-l", "--list"
        error improper_argument_error if ARGV.length != 1
        message = ""
        if configuration.empty?
          message = "  No variables configured.".apply_color(:yellow)
        else
          message = pretty_help_message(configuration)
        end
        puts "\n  monkey config list\n\n#{message}\n\n"

      when "catalog", "-c", "--catalog"
        error improper_argument_error if ARGV.length != 1
        puts "\n  monkey config catalog\n\n#{self.pretty_help_message(ConfigVariables)}\n\n"

      when "get", "-g", "--get"
        error improper_argument_error if ARGV.length != 2
        if ConfigVariables.keys.include?(ARGV[1])
          puts configuration[ARGV[1]]
        else
          error "FATAL: '#{ARGV[1]}' is an invalid variable.\n  Available config variables:\n\n#{self.pretty_help_message(ConfigVariables)}\n\n"
        end

      else
        error "FATAL: '#{ARGV[0]}' is an invalid command.\n\n#{@@config_help_message}\n"
      end

      puts ("Command 'monkey #{@@last_command_line}' finished successfully.").apply_color(:green)
      reset()
    end

    def self.convert_value(val, values)
      case values
      when Array then return convert_value(val, values.first.class)
      when Class, Module # Integer, String, Symbol, Boolean
        case values.to_s
        when "Integer" then return val.to_i
        when "String" then return val.to_s
        when "Symbol" then return val.to_s.to_sym
        when "Hash" then return val.to_h
        when "TrueClass", "FalseClass" then return val == "true" || val == true
        else
          raise TypeError.new("can't convert #{val.class} into #{values}")
        end
      end
    end

    def self.check_variable_value(var, val)
      key_exists = ConfigVariables.keys.include?("#{var}")
      val_valid = false
      if key_exists
        values = ConfigVariables["#{var}"]["values"]
        if values.is_a?(Array)
          val_valid = values.include?(val)
        elsif values.is_a?(Class) # Integer, String, Symbol, Hash
          val_valid = convert_value(val, values).is_a?(values)
        end
      end
      key_exists && !val_valid.nil?
    end
  end
end

# Auto-require Section
automatic_require(VirtualMonkey::COMMAND_DIR)
