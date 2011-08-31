module VirtualMonkey
  module Mixin
    module ChefMysql
      include VirtualMonkey::Mixin::DeploymentBase
      include VirtualMonkey::Mixin::EBS
      attr_accessor :scripts_to_run
      attr_accessor :db_ebs_prefix
  
      def mysql_servers
        res = []
        @servers.each do |server|
          st = ServerTemplate.find(resource_id(server.server_template_href))
          if st.nickname =~ /Database Manager/
            res << server
          end
        end
        raise "FATAL: No Database Manager servers found" unless res.length > 0
        res
      end

      # lookup all the RightScripts that we will want to run
      def mysql_lookup_scripts
       scripts = [
                   [ 'setup_block_device', 'db::setup_block_device' ],
                   [ 'do_backup', 'db::do_backup' ],
                   [ 'do_restore', 'db::do_restore' ],
                   [ 'do_backup', 'db::do_backup' ],
                   [ 'do_restore', 'db::do_restore' ],
                   [  'do_backup_schedule_enable', 'db::do_backup_schedule_enable'],
                   ['do_backup_schedule_disable', 'db::do_backup_schedule_disable'],
                   ['do_appservers_allow', 'db::do_appservers_allow'              ],
                   ['do_appservers_deny', 'db::do_appservers_deny'],
                   [ 'do_force_reset', 'db::do_force_reset'   ],
                   ['setup_rule', 'sys_firewall::setup_rule'],
                   ['do_list_rules', 'sys_firewall::do_list_rules'],
                   [ 'do_reconverge_list_enable', 'sys::do_reconverge_list_enable' ],
                   [ 'do_reconverge_list_disable', 'sys::do_reconverge_list_disable' ],
                   [ 'do_force_reset', 'db::do_force_reset' ]
                 ]
        raise "FATAL: Need 1 MySQL servers in the deployment" unless mysql_servers.size >= 1
  
        st = ServerTemplate.find(resource_id(mysql_servers.first.server_template_href))
        load_script_table(st,scripts,st)
      end

      def import_unified_app_sqldump
        load_script('import_dump', RightScript.new('href' => '/api/acct/2901/right_scripts/187123'))
        raise "Did not find script: import_dump" unless script_to_run?('import_dump')
        run_script_on_set('import_dump', mysql_servers, true, { 'DBAPPLICATION_PASSWORD' => 'cred:DBAPPLICATION_PASSWORD', 'DBAPPLICATION_USER' => 'cred:DBAPPLICATION_USER' })
      end

      # sets the lineage for the deployment
      # * kind<~String> can be "chef" or nil
      def set_variation_lineage()
        @lineage = "testlineage#{resource_id(@deployment)}"
  puts "Set variation LINEAGE: #{@lineage}"
        obj_behavior(@deployment, :set_input, 'db/backup/lineage', "text:#{@lineage}")
      end
  
      def set_variation_container
        @container = "testlineage#{resource_id(@deployment)}"
  puts "Set variation CONTAINER: #{@container}"
        obj_behavior(@deployment, :set_input, "block_device/storage_container", "text:#{@container}")
      end
  
      def test_primary_backup
        run_script("setup_block_device", s_one)
        probe(s_one, "touch /mnt/storage/monkey_was_here")
        run_script("do_backup", s_one)
        wait_for_snapshots
        run_script("do_force_reset", s_one)
        run_script("do_restore", s_one)
        probe(s_one, "ls /mnt/storage") do |result, status|
          raise "FATAL: no files found in the backup" if result == nil || result.empty?
          true
        end
      end
  
      def test_secondary_backup
        cid = VirtualMonkey::Toolbox::determine_cloud_id(s_one)
        if cid == 232
          #TODO
        else
          #TODO
        end
      end

      def enable_db_reconverge
        run_script_on_set('do_reconverge_list_enable', mysql_servers)
      end

      def disable_db_reconverge
        run_script_on_set('do_reconverge_list_disable', mysql_servers)
      end

      # Runs a mysql query on specified server.
      # * query<~String> a SQL query string to execute
      # * server<~Server> the server to run the query on 
      def run_query(query, server, &block)
        query_command = "echo -e \"#{query}\"| mysql"
        probe(server, query_command, &block)
      end
  
      # Use the termination script to stop all the servers (this cleans up the volumes)
      def stop_all(wait=true)
        @servers.each { |s| obj_behavior(s, :stop) }
  
       wait_for_all("stopped") if wait
        # unset dns in our local cached copy..
        @servers.each { |s| s.params['dns-name'] = nil } 
      end
  
      # uses SharedDns to find an available set of DNS records and sets them on the deployment
      def setup_dns(domain)
        # TODO should we just use the ID instead of the full href?
        owner=@deployment.href
        @dns = SharedDns.new(domain)
        raise "Unable to reserve DNS" unless @dns.reserve_dns(owner)
        @dns.set_dns_inputs(@deployment)
      end
     
      def setup_block_device
        puts "SETUP_BLOCK_DEVICE"
        run_script("setup_block_device", s_one)
      end
  
      def do_backup
        puts "BACKUP"
        run_script("do_backup", s_one)
      end
  
      def do_restore
        puts "RESTORE"
        run_script("do_restore", s_one)
      end
  
      def do_force_reset
        puts "RESET"
        run_script("do_force_reset", s_one)
      end
  
      # releases records back into the shared DNS pool
      def release_dns
        @dns.release_dns
      end
  
      def release_container
        set_variation_container
        ary = []
        raise "FATAL: could not cleanup because @container was '#{@container}'" unless @container
        s3 = Fog::Storage.new(:provider => 'AWS')
        ary << s3.directories.all.select {|d| d.key =~ /^#{@container}/}
        if Fog.credentials[:rackspace_username] and Fog.credentials[:rackspace_api_key]
          rax = Fog::Storage.new(:provider => 'Rackspace')
          ary << rax.directories.all.select {|d| d.key =~ /^#{@container}/}
        else
          puts "No Rackspace Credentials!"
        end
        ary.each do |con|
          con.each do |dir|
            dir.files.each do |file|
              file.destroy
            end
            dir.destroy
          end
        end
      end  

      def run_reboot_operations
        # set up a database to test after we reboot
        @engines = ['myisam', 'innodb']
        @servers.each do |server|
          run_query("create database monkey_database", server)
          @engines.each do |engine|
            run_query("use monkey_database; create table monkey_table_#{engine} (monkey_column text) engine = #{engine}; insert into monkey_table_#{engine} values ('Hello monkey!')", server)
          end
        end
        # Duplicate code here because we need to wait between the master and the slave time
        #reboot_all(true) # serially_reboot = true
        @servers.each do |s|
          obj_behavior(s, :reboot, true)
          obj_behavior(s, :wait_for_state, "operational")
        end
        wait_for_all("operational")
        run_reboot_checks
      end
  
      # This is where we perform multiple checks on the deployment after a reboot.
      def run_reboot_checks
        # test that the data we created is still there after the reboot
        @servers.each do |server|
          @engines.each do |engine|
            run_query("use monkey_database; select monkey_column from monkey_table_#{engine}", server) do |result, status|
              raise "Database reboot failed, data is missing: #{result}" unless result =~ /Hello monkey!/
              true
            end
          end
        end
        # one simple check we can do is the backup.  Backup can fail if anything is amiss
        @servers.each do |server|
          run_script("do_backup", server)
        end
      end
  
  #    def run_restore_with_timestamp_override
  #      obj_behavior(s_one, :relaunch)
  #      s_one.dns_name = nil
  #      obj_behavior(s_one, :wait_for_operational_with_dns)
  #     run_script('restore', s_one, { "OPT_DB_RESTORE_TIMESTAMP_OVERRIDE" => "text:#{find_snapshot_timestamp}" })
  #    end
  
  # Check for specific MySQL data.
      def check_mysql_monitoring
        mysql_plugins = [
                          {"plugin_name"=>"mysql", "plugin_type"=>"mysql_commands-delete"},
                          {"plugin_name"=>"mysql", "plugin_type"=>"mysql_commands-create_db"},
                          {"plugin_name"=>"mysql", "plugin_type"=>"mysql_commands-create_table"},
                          {"plugin_name"=>"mysql", "plugin_type"=>"mysql_commands-insert"},
                          {"plugin_name"=>"mysql", "plugin_type"=>"mysql_commands-show_databases"}
                        ]
        @servers.each do |server|
          unless server.multicloud
  #mysql commands to generate data for collectd to return
            for ii in 1...100
  #TODO: have to select db with every call.  figure a better way to do this and get rid of fast and ugly
  # cut and past hack.
             run_query("show databases", server)
             run_query("create database test#{ii}", server)
             run_query("use test#{ii}; create table test#{ii}(test text)", server)
             run_query("use test#{ii};show tables", server)
             run_query("use test#{ii};insert into test#{ii} values ('1')", server)
             run_query("use test#{ii};update test#{ii} set test='2'", server)
             run_query("use test#{ii};select * from test#{ii}", server)
             run_query("use test#{ii};delete from test#{ii}", server)
             run_query("show variables", server)
             run_query("show status", server)
             run_query("use test#{ii};grant select on test.* to root", server)
             run_query("use test#{ii};alter table test#{ii} rename to test2#{ii}", server)
            end
            mysql_plugins.each do |plugin|
              monitor = obj_behavior(server, :get_sketchy_data, { 'start' => -60,
                                                                  'end' => -20,
                                                                  'plugin_name' => plugin['plugin_name'],
                                                                  'plugin_type' => plugin['plugin_type']})
              value = monitor['data']['value']
              raise "No #{plugin['plugin_name']}-#{plugin['plugin_type']} data" unless value.length > 0
              # Need to check for that there is at least one non 0 value returned.
              for nn in 0...value.length
                if value[nn] > 0
                  break
                end
              end
              raise "No #{plugin['plugin_name']}-#{plugin['plugin_type']} time" unless nn < value.length
              puts "Monitoring is OK for #{plugin['plugin_name']}-#{plugin['plugin_type']}"
            end
          end
        end
      end
  
      def set_variation_dnschoice(dns_choice)
	      @deployment.set_input("sys_dns/choice", "#{dns_choice}")
      end
      
      def set_variation_http_only
        @deployment.set_input("web_apache/ssl_enable", "text:false")
      end

  
    end
  end
end
