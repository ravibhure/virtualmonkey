module VirtualMonkey
  module Command
    # monkey clone --deployment name --feature testcase.rb --breakpoint 4 --copies 7
    add_command("clone", [:deployment, :config_file, :n_copies, :yes, :verbose, :terminate,
                          :tests, :exclude_tests, :started_at]) do
      deployments = Deployment.find_by_nickname_speed(@@options[:deployment])
      if deployments.length > 1
        raise "FATAL: Ambiguous Regex; more than one deployment matched /#{@@options[:deployment]}/"
      elsif deployments.length < 1
        raise "FATAL: Ambiguous Regex; no deployment matched /#{@@options[:deployment]}/"
      end
      origin = deployments.first
      info_tags = origin.get_info_tags["self"]
      @@do_these ||= []
      # clone deployment
      for i in 1 .. @@options[:n_copies]
        new_deploy = origin.clone
        new_deploy.reload
        new_deploy.nickname = "#{origin.nickname}-clone-#{i}"
        new_deploy.set_info_tags(info_tags) unless info_tags.empty?
        new_deploy.save
        @@do_these << new_deploy
      end

      # run to breakpoint
      run_logic if @@options[:config_file]
    end
  end
end
