module VirtualMonkey
  module Command
    # monkey destroy --tag unique_tag
    add_command("destroy", [:config_file, :only, :keep, :prefix, :yes, :timeouts, :clouds, :verbose, :force]) do

      # Handle any command line timeout overrides specified
      self.override_timeouts

      load_config_file
      @@dm = VirtualMonkey::Manager::DeploymentSet.new(@@options)
      select_only_logic("Really destroy")
      if @@options[:force]
        begin
          destroy_all_logic
        rescue Interrupt
          raise
        rescue Exception => e
          warn "WARNING: got \"#{e.message}\", forcing destruction of deployments."
          @@do_these.each { |deploy|
            deploy.servers_no_reload.each { |s| s.stop if s.state =~ /operational|booting/ }
            deploy.destroy
          }
        end
      else
        destroy_all_logic
      end
    end
  end
end
