set :runner, VirtualMonkey::Runner::FeApp

hard_reset do
  @runner.stop_all
end

before do
  @runner.set_master_db_dnsname
end

test "default" do
# When I launch the "Front End" servers
  @runner.launch_set("Front End")


  @runner.wait_for_set("Front End", "booting")


  @runner.wait_for_set("Front End", "operational")


  @runner.set_lb_hostname

# When I launch the "App Server" servers
  @runner.launch_set("App Server")


  @runner.wait_for_set("App Server", "booting")


  @runner.wait_for_set("App Server", "operational")


  @runner.cross_connect_frontends


  @runner.run_unified_application_checks(:app_servers)


  @runner.frontend_checks


  @runner.log_rotation_checks


  @runner.run_reboot_operations


  @runner.check_monitoring
#  @runner.run_logger_audit
end
