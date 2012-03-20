require 'eventmachine'
module VirtualMonkey
  module Command
    # TODO trollop supports Chronic for human readable dates. use with run command for delayed run?
    # monkey run --feature --tag --only <regex to match on deploy nickname>
    add_command("run", [:config_file, :prefix, :only, :yes, :verbose, :tests, :timeouts, :keep, :terminate, :clouds,
                        :no_resume, :report_tags, :report_metadata, :exclude_tests, :started_at]) do

      # Handle any command line timeout overrides specified
      self.override_timeouts

      load_config_file
      run_logic
    end
  end
end
