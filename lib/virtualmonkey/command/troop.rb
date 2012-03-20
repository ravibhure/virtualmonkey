module VirtualMonkey
  module Command
    # This command does all the steps create/run/conditionaly destroy
    add_command("troop", [:config_file, :no_spot, :prefix, :use_mci, :verbose, :yes, :one_deploy, :keep,
                          :clouds, :only, :tests, :timeouts, :no_resume, :revisions, :report_tags, :report_metadata,
                          :exclude_tests, :started_at]) do

      # Handle any command line timeout overrides specified
      self.override_timeouts

      # Execute Main
      load_config_file

      # CREATE PHASE
      @@dm = VirtualMonkey::Manager::DeploymentSet.new(@@options)
      unless @@dm.deployments.size > 0
        create_logic
      else
        warn "Existing deployments matching --prefix #{@@options[:prefix]} found. Skipping deployment creation."
      end

      run_logic
    end
  end
end
