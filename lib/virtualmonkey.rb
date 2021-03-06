require 'yaml'

#
# Virtual Monkey Main Module
#

module VirtualMonkey
  @@virtualMonkeyConfigFilesLoaded = false

  ROOTDIR = File.expand_path(File.join(File.dirname(__FILE__), "..")).freeze
  GENERATED_CLOUD_VAR_DIR = File.join(ROOTDIR, "cloud_variables").freeze
  TEST_STATE_DIR = File.join(ROOTDIR, "test_states").freeze

  LOG_DIR = File.join(ROOTDIR, "log").freeze
  BIN_DIR = File.join(ROOTDIR, "bin").freeze
  LIB_DIR = File.join(ROOTDIR, "lib", "virtualmonkey").freeze

  COMMAND_DIR = File.join(LIB_DIR, "command").freeze
  MANAGER_DIR = File.join(LIB_DIR, "manager").freeze
  UTILITY_DIR = File.join(LIB_DIR, "utility").freeze
  RUNNER_CORE_DIR = File.join(LIB_DIR, "runner_core").freeze
  PROJECT_TEMPLATE_DIR = File.join(LIB_DIR, "collateral_template").freeze

  WEB_APP_DIR = File.join(ROOTDIR, "lib", "spidermonkey").freeze

  REGRESSION_TEST_DIR = File.join(ROOTDIR, "test").freeze
  COLLATERAL_TEST_DIR = File.join(ROOTDIR, "collateral").freeze

  @@rest_yaml = File.join(File.expand_path("~"), ".rest_connection", "rest_api_config.yaml")
  @@rest_yaml = File.join("", "etc", "rest_connection", "rest_api_config.yaml") unless File.exists?(@@rest_yaml)
  REST_YAML = @@rest_yaml

  VERSION = lambda {
    branch = (`git branch 2> /dev/null | grep \\*`.chomp =~ /\* ([^ ]+)/ && $1) || "master"
    (`cat "#{File.join(ROOTDIR, "VERSION")}"`.chomp + (branch == "master" ? "" : ", branch \"#{branch}\""))
  }.call

  puts "Virtual Monkey Automated Test Framework"
  puts "Copyright (c) 2010-2012 RightScale Inc"
  puts "Version #{VERSION}"
  puts

  unless const_defined?("RUNNING_AS_GEM")
    RUNNING_AS_GEM = lambda {
      gem_dirs = `gem environment | grep -A9999 "GEM PATHS" | grep -B9999 "GEM CONFIGURATION"`.chomp.split("\n")
      gem_dirs = gem_dirs.map { |s| s =~ /(#{File::SEPARATOR}.*)/ && $1 }.compact
      gem_dirs.detect { |s| File.dirname(__FILE__) =~ Regexp.new(s) && $1 } && true || false
    }
  end

  ROOT_CONFIG = File.join(VirtualMonkey::ROOTDIR, ".config.yaml").freeze
  USER_CONFIG = File.join(File.expand_path("~"), ".virtualmonkey", ".config.yaml").freeze
  SYS_CONFIG = File.join("", "etc", "virtualmonkey", ".config.yaml").freeze

  # Method to display current timeout value
  # * prefix<~String> optional prefix string
  def self.display_timeouts( prefix )
    puts "#{prefix} timeout values are set to:"
    puts "      booting_timeout: #{::VirtualMonkey::config[:booting_timeout]}"
    puts "    completed_timeout: #{::VirtualMonkey::config[:completed_timeout]}"
    puts "      default_timeout: #{::VirtualMonkey::config[:default_timeout]}"
    puts "        error_timeout: #{::VirtualMonkey::config[:error_timeout]}"
    puts "       failed_timeout: #{::VirtualMonkey::config[:failed_timeout]}"
    puts "     inactive_timeout: #{::VirtualMonkey::config[:inactive_timeout]}"
    puts "  operational_timeout: #{::VirtualMonkey::config[:operational_timeout]}"
    puts "     snapshot_timeout: #{::VirtualMonkey::config[:snapshot_timeout]}"
    puts "      stopped_timeout: #{::VirtualMonkey::config[:stopped_timeout]}"
    puts "   terminated_timeout: #{::VirtualMonkey::config[:terminated_timeout]}"
    puts ""
  end

  def self.config
    if not @@virtualMonkeyConfigFilesLoaded
      @@virtual_monkey_config = {}
      puts "Attempting to load any available config files..."
      [VirtualMonkey::SYS_CONFIG, VirtualMonkey::USER_CONFIG, VirtualMonkey::ROOT_CONFIG].each do |config_file|
        if File.exists?(config_file)
          puts "found \"#{config_file}\" loading..."
          begin
              @@virtual_monkey_config.merge!(YAML::load(IO.read(config_file)) || {})
          rescue Errno::EBADF, IOError
            retry
          end
          if VirtualMonkey.const_defined?("Command")
            config_ok = @@virtual_monkey_config.reduce(true) do |bool,ary|
              bool && VirtualMonkey::Command::check_variable_value(ary[0], ary[1])
            end
            warn "WARNING: #{config_file} contains an invalid variable or value" unless config_ok
          end
        end
      end
    end
    if VirtualMonkey.const_defined?("Command") && VirtualMonkey::Command.const_defined?("ConfigVariables")
      VirtualMonkey::Command::ConfigVariables.each do |var,hsh|
        @@virtual_monkey_config[var.to_sym] ||= hsh["default"]
      end
    end
    @@virtualMonkeyConfigFilesLoaded = true
    @@virtual_monkey_config
  end
end

require 'colorize'
require 'patches.rb'

def progress_require(file, progress=nil)
  if ::VirtualMonkey::config[:load_progress] != "hide" && tty?
    @current_progress ||= nil
    if ENV['ENTRY_COMMAND'] == "monkey" && progress && progress != @current_progress
      STDOUT.print "\nloading #{progress}"
    end
    @current_progress = progress || @current_progress
  end
  STDOUT.flush

  ret = require file

  if ::VirtualMonkey::config[:load_progress] != "hide" && tty?
    if ENV['ENTRY_COMMAND'] == "monkey" && ret
      STDOUT.print "."
    end
  end
  STDOUT.flush
  ret
end

def automatic_require(full_path, progress=nil)
  some_not_included = true
  files = Dir.glob(File.join(File.expand_path(full_path), "**"))
  retry_loop = 0
  last_err = nil
  while some_not_included and retry_loop <= (files.size ** 2) do
    begin
      some_not_included = false
      for f in files do
        val = progress_require(f.chomp(".rb"), progress) if f =~ /\.rb$/
        some_not_included ||= val
      end
    rescue NameError => e
      last_err = e
      raise unless "#{e}" =~ /uninitialized constant/i
      some_not_included = true
      files.push(files.shift)
    end
    retry_loop += 1
  end
  if some_not_included
    warn "Couldn't auto-include all files in #{File.expand_path(full_path)}"
    raise last_err
  end
end

progress_require('rubygems', 'dependencies')
progress_require('rest_connection')
progress_require('right_popen')
progress_require('fog')
if Fog::VERSION !~ /^0\./ # New functionality in 1.0.0
  Fog::Logger[:warning] = nil # Disable annoying [WARN] about bucket names
end

progress_require('fileutils')
progress_require('parse_tree')
progress_require('parse_tree_extensions')
progress_require('ruby2ruby')

progress_require('virtualmonkey/runner_core', 'virtualmonkey')
progress_require('virtualmonkey/test_case_dsl')

progress_require('virtualmonkey/manager', 'managers')
progress_require('virtualmonkey/utility', 'utilities')
progress_require('virtualmonkey/command', 'commands')

progress_require('spidermonkey', 'spidermonkey')
puts "\n"
VirtualMonkey::config # Verify config files

# Display timeouts
VirtualMonkey::display_timeouts "All available config files now loaded, new"

