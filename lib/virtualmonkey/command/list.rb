module VirtualMonkey
  module Command
    # bin/monkey list -x
    add_command("list", [:prefix, :verbose, :yes, :config_file, :only, :clouds], [], :flagless) do
      load_config_file if @@options[:config_file]
      @@options[:prefix] ||= "*"
      deployments = VirtualMonkey::Manager::DeploymentSet.list(@@options.merge(:command => "list"))
      if @@options[:verbose]
        pp deployments.map { |d| { d.nickname => d.servers.map { |s| s.state } } }
      else
        pp deployments.map { |d| d.nickname }
      end
      puts "Found #{deployments.length} deployment#{deployments.one? ? nil : "s"} with " +
           "#{deployments.reduce(0) { |sum,d| sum + d.servers_no_reload.length } } servers."
    end
  end
end
