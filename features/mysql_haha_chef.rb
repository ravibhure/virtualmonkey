set :runner, VirtualMonkey::Runner::MysqlChefHA

#terminates servers if there are any running
hard_reset do
  stop_all
end

before do
  mysql_lookup_scripts
  set_variation_lineage
  set_variation_container
  setup_dns("dnsmadeeasy_new") # dnsmadeeasy
  set_variation_dnschoice("text:DNSMadeEasy") # set variation choice
  launch_all
  wait_for_all("operational")
  disable_db_reconverge
  run_script("setup_block_device", s_one)
  make_master(s_one)#TODO this just tags the master
  create_monkey_table(s_one)
  probe(s_one, "touch /mnt/storage/monkey_was_here")
  run_script("do_backup", s_one)
  check_master(s_one)
  wait_for_snapshots
  # Now we have a backup that can be used to restore masters and slave
  # This server is not a real master.  To create a real master the
  # restore_and_become_master recipe needs to be run on a new instance
  # This one should be re-launched be additional tests are run on it
  #
end

test "backup_master" do
  run_script("do_backup", s_one)
end


#test "create_slave_from_master_backup" do
#  run_script("do_init_slave", s_two)
#end

#test "create_master_from_master_backup" do
#  run_script("do_restore_and_become_master",s_one)
#end
#
#test "backup_slave" do
#  run_script("setup_block_device", s_two)
#  probe(s_one, "touch /mnt/storage/monkey_was_here")
#  run_script("do_backup", s_two)
#  wait_for_snapshots
#end

#test "create_master_from_slave_backup" do
##  run_script("do_restore_and_become_master",s_one)
#end

#test "promote_slave_to_master" do
##  run_script("do_promote_to_master",s_one)
#end

# TODO: WTF?!
#before 'reboot' do
#  do_force_reset
#  run_script("setup_block_device", s_one)
#end

#test "reboot" do
#  check_mysql_monitoring
#  run_reboot_operations
#  check_monitoring
#  check_mysql_monitoring
#end

#after do
#  cleanup_volumes
#  cleanup_snapshots
#end

#test "default" do
#  run_chef_promotion_operations
#  run_chef_checks
#  check_monitoring
#  check_mysql_monitoring
#  run_HA_reboot_operations
#end

