module VirtualMonkey
  module Command
    def self.qa(*args)
      self.init(*args)
      @@command = ARGV.shift
      if @@available_qa_commands[@@command.to_sym]
        VirtualMonkey::Command.__send__("qa_#{@@command}")
      elsif @@command == "-h" or @@command == "--help"
        VirtualMonkey::Command.help
      else
        error "Invalid command #{@@command}\n\n#{@@usage_msg}"
      end
    end

    def self.qa_audit_logs(*args)
      self.qa_init(*args)
      #CommandFlags = [:prefix, :only, :config_file]
      @@options = Trollop::options do
        eval(VirtualMonkey::Command::use_options)
      end

      raise "--config_file is required" unless @@options[:config_file]
      load_config_file

      @@dm = VirtualMonkey::Manager::DeploymentSet.new(@@options)
      select_only_logic("Train lists on")

      @@do_these.each { |d| audit_log_deployment_logic(d, @@options[:list_trainer]) }
    end
  end
end
