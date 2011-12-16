module VirtualMonkey
  module Command
    # Config commands
    CommandFlags.merge!("environment" => EnvironmentPresets.keys)
    def self.environment(*args)
      self.init(*args)
      @@command = "environment"

      unless class_variable_defined?("@@environment_help_message")
        @@environment_help_message = "  monkey #{@@command} [options...]\n\n "
        @@environment_help_message += @@available_commands[@@command.to_sym] + "\n"
        @@environment_help_message += pretty_help_message(EnvironmentPresets)
      end

      @@last_command_line = "#{@@command} #{ARGV.join(" ")}"
      # Save last_command_line
      environment_command_string = @@last_command_line

      # Print Help?
      if ARGV.empty? or not (ARGV & ['--help', '-h', 'help']).empty?
        puts "\n#{@@environment_help_message}\n\n"
        exit(0)
      end

      if EnvironmentPresets.keys.include?(ARGV[0])
        EnvironmentPresets[ARGV[0]]["values"].each do |variable,value|
          config("set #{variable} #{value}")
        end
      else
        error "FATAL: '#{ARGV[0]}' is an invalid preset.\n\n#{@@environment_help_message}\n"
      end

      # Restore last_command_line
      @@last_command_line = environment_command_string

      puts ("Command 'monkey #{@@last_command_line}' finished successfully.").apply_color(:green)
      reset()
    end
  end
end
