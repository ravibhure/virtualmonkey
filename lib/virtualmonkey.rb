require 'yaml'

module VirtualMonkey
  ROOTDIR = File.expand_path(File.join(File.dirname(__FILE__), ".."))
  GENERATED_CLOUD_VAR_DIR = File.join(ROOTDIR, "cloud_variables")
  TEST_STATE_DIR = File.join(ROOTDIR, "test_states")

  LOG_DIR = File.join(ROOTDIR, "log")
  BIN_DIR = File.join(ROOTDIR, "bin")
  LIB_DIR = File.join(ROOTDIR, "lib", "virtualmonkey")

  COMMAND_DIR = File.join(LIB_DIR, "command")
  MANAGER_DIR = File.join(LIB_DIR, "manager")
  UTILITY_DIR = File.join(LIB_DIR, "utility")
  RUNNER_CORE_DIR = File.join(LIB_DIR, "runner_core")
  PROJECT_TEMPLATE_DIR = File.join(LIB_DIR, "collateral_template")

  WEB_APP_DIR = File.join(ROOTDIR, "lib", "spidermonkey")

  REGRESSION_TEST_DIR = File.join(ROOTDIR, "test")
  COLLATERAL_TEST_DIR = File.join(ROOTDIR, "collateral")

  @@rest_yaml = File.join(File.expand_path("~"), ".rest_connection", "rest_api_config.yaml")
  @@rest_yaml = File.join("", "etc", "rest_connection", "rest_api_config.yaml") unless File.exists?(@@rest_yaml)
  REST_YAML = @@rest_yaml

  branch = (`git branch 2> /dev/null | grep \\*`.chomp =~ /\* ([^ ]+)/; $1) || "master"
  VERSION = (`cat "#{File.join(ROOTDIR, "VERSION")}"`.chomp + (branch == "master" ? "" : " #{branch.upcase}"))

  ROOT_CONFIG = File.join(VirtualMonkey::ROOTDIR, ".config.yaml")
  USER_CONFIG = File.join(File.expand_path("~"), ".virtualmonkey", "config.yaml")
  SYS_CONFIG = File.join("", "etc", "virtualmonkey", "config.yaml")

  def self.config
    @@virtual_monkey_config = {}
    [VirtualMonkey::SYS_CONFIG, VirtualMonkey::USER_CONFIG, VirtualMonkey::ROOT_CONFIG].each do |config_file|
      if File.exists?(config_file)
        @@virtual_monkey_config.merge!(YAML::load(IO.read(config_file)) || {})
        if VirtualMonkey.const_defined?("Command")
          config_ok = @@virtual_monkey_config.reduce(true) do |bool,ary|
            bool && VirtualMonkey::Command::check_variable_value(ary[0], ary[1])
          end
          warn "WARNING: #{config_file} contains an invalid variable or value" unless config_ok
        end
      end
    end
    @@virtual_monkey_config
  end
end

require 'colorize'
require 'patches.rb'

def progress_require(file, progress=nil)
  if VirtualMonkey::config[:load_progress] != "hide" && tty?
    @current_progress ||= nil
    if ENV['ENTRY_COMMAND'] == "monkey" && progress && progress != @current_progress
      STDOUT.print "\nloading #{progress}"
    end
    @current_progress = progress || @current_progress
  end
  STDOUT.flush

  ret = require file

  if VirtualMonkey::config[:load_progress] != "hide" && tty?
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

progress_require('spidermonkey.rb', 'spidermonkey')
puts "\n"
VirtualMonkey::config # Verify config files
