#
# DeploymentBase is the base (include) module mixin for all runners (written by test engineers)
#
module VirtualMonkey
  module RunnerCore
    module DeploymentBase
      extend VirtualMonkey::RunnerCore::CommandHooks
      include VirtualMonkey::TestCaseInterface
      attr_accessor :deployment, :servers, :server_templates
      attr_accessor :scripts_to_run
      
      # Test for instance throttling
      before_run do
        ret = false
        cloud_id = @servers.first.cloud_id.to_s
        throttling_values = ::VirtualMonkey::config[:throttling_values]
        throttling_values[cloud_id] ||= {}
        max_instances = throttling_values[cloud_id][:max_instances] || 1024
        if cloud_id.to_i <= 10 # Handle AWS API 1.0
          instance_count = Server.find_by(:state) {|s| s != "stopped"}.size
        else # Handle non-AWS API 1.5
          instance_count = McInstance.find_all(cloud_id).size
        end
        if @servers.size + instance_count > max_instances
          ret = "Maximum number of server instances exceeded for cloud #{cloud_id}"
        end
        ret
      end

      def initialize(deployment, opts = {})
        @scripts_to_run = {}
        @server_templates = []
        @st_table = []
        @deployment = Deployment.find_by_nickname_speed(deployment).first
        raise "Fatal: Could not find a deployment named #{deployment}" unless @deployment
        test_case_interface_init(opts)
        populate_settings
        self.class.extend(VirtualMonkey::RunnerCore::CommandHooks) unless self.class.respond_to?(:before_create)
        assert_integrity!
      end

      # Select a server based on the info tags attached to it
      # If a hash of tags is passed, the server needs to match all of them by value
      # If a block is passed, all info tags will be passed to the block as a hash
      def server_by_info_tags(tags = {}, &block)
        set = @servers
        if block
          set = set.select { |s| yield(s.get_info_tags["self"]) }
        else
          tags.each { |key,val|
            set = set.select { |s| s.get_info_tags(key)["self"][key] == val }
          }
        end
        set.first
      end

      # Select a server based on the tags in a namespace attached to it
      # e.g. "namespace:key=value"
      # If a hash of tags is passed, the server needs to match all of them by value
      # If a block is passed, all info tags will be passed to the block as a hash
      def server_by_namespace_tags(namespace, tags = {}, &block)
        set = @servers
        if block
          set = set.select { |s| yield(s.get_tags_by_namespace(namespace)["self"]) }
        else
          tags.each { |key,val|
            set = set.select { |s| s.get_tags_by_namespace(namespace)["self"][key] == val }
          }
        end
        set.first
      end

      # Ensures the following blacklist entries are entered for all runners
      def deployment_base_blacklist
        [
          ["/var/log/messages", ".*", "exception"],
          ["/var/log/messages", ".*", "error"],
          ["/var/log/messages", ".*", "fatal"],
          ["/var/log/messages", ".*", "fail"],
          ["/var/log/messages", ".*", "missing"],
          ["/var/log/messages", ".*", "BEGIN RSA PRIVATE KEY"]
        ]
      end

      # Ensures the following whitelist entries are entered for all runners
      def deployment_base_whitelist
        [
          ["/var/log/messages", ".*", "destination\(d_httperror\)=0"]
        ]
      end

      # Makes this exception_handle available for all runners
      def deployment_base_exception_handle(e)
        case e.message
        when /Insufficient capacity/i
          warn "Got \"Insufficient capacity\". Retrying...."
          sleep 60
          return true # Exception Handled
        when /execution expired/i # Response timed out
          warn "Got \"execution expired\". Retrying...."
          sleep 5
          return true # Exception Handled
        when /Service Unavailable|Service Temporarily Unavailable/i # 503
          warn "Got \"Service Temporarily Unavailable\". Retrying...."
          sleep 30
          return true # Exception Handled
        when /Bad Gateway/i     # 502: Rackspace sometimes forgets instances exist
          warn "Got \"Bad Gateway\". Retrying...."
          sleep 90
          return true # Exception Handled
        when /Internal error/i  # 500: For mysql deadlocks only
          warn "Got \"Internal Error\". Retrying...."
          sleep 10
          return true # Exception Handled
        when /Another launch is in progress/i # 422: Rackspace seems to have gotten two launch commands
          warn "Got \"Another launch is in progress\". Continuing...."
          continue_test
          return true # Exception Handled
        else
          case e
          when EOFError
            warn "Got #{e.class.inspect}. Retrying...."
            sleep 0.1
            return true #Exception Handled
          else
            return false # Exception Not Handled
          end
        end
      end

      # Master method that calls all methods with "lookup_scripts" in their name
      def __lookup_scripts__
        all_methods = self.methods + self.private_methods
        lookup_script_methods = all_methods.select { |m| m =~ /lookup_scripts/ and m !~ /^__/ }
        lookup_script_methods.each { |method_name| self.__send__(method_name) }
      end

      # Returns the API 1.0 integer id of the rest_connection object or href
      def resource_id(res)
        if res.is_a?(String)
          return res.split(/\//).last.to_i
        else
          return res.href.split(/\//).last.to_i
        end
      end

      # Loads a table of [friendly_name, script/recipe regex] from ref_template, attaching them to all templates in the deployment unless add_only_to_this_st is set
      def load_script_table(ref_template, table, add_only_to_this_st = nil)
        if add_only_to_this_st.is_a?(ServerInterface) or add_only_to_this_st.is_a?(Server)
          sts = [ match_st_by_server(add_only_to_this_st) ]
        elsif add_only_to_this_st.is_a?(ServerTemplate)
          sts = [ add_only_to_this_st ]
        elsif add_only_to_this_st.nil?
          sts = @server_templates
        end
        sts.each { |st|
          table.each { |a|
            st_id = resource_id(st)
            @scripts_to_run[st_id] ||= {}
            overwriting_warning_msg = "WARNING: Overwriting '#{a[0]}' for ServerTemplate #{st.nickname}"
            exec = ref_template.executables.detect do |ex|
              ex.name =~ /#{a[1]}/i or ex.recipe =~ /#{a[1]}/i
            end
            if exec
              if exec.recipe =~ /#{a[1]}/i
                # Recipes can only be run on the template they are attached to
                if resource_id(ref_template) == st_id
                  warn overwriting_warning_msg if @scripts_to_run[st_id][a[0]]
                  @scripts_to_run[st_id][a[0]] = exec
                end
              else
                # RightScripts can be run on any server
                warn overwriting_warning_msg if @scripts_to_run[st_id][a[0]]
                @scripts_to_run[st_id][a[0]] = exec
              end
            else
              raise "FATAL: Executable #{a[1]} not found for #{st.nickname}"
            end
          }
        }
      end

      # Determines which logs to run for the available server_templates, then does the message check
      def run_logger_audit(interactive = false, strict = false)
        ret_string = ""
        mc = MessageCheck.new(@log_checklists, strict)
        logs = mc.logs_to_check(@server_templates)
        logs.each do |st_href,logfile_array|
          servers_to_check = @servers.select { |s| s.server_template_href == st_href }
          logfile_array.each { |logfile| ret_string += mc.check_messages(servers_to_check, interactive, logfile) }
        end
        if ret_string =~ /ERROR/
          raise ret_string
        else
          return ret_string
        end
      end

      # Loads a single hard-coded RightScript or Recipe, attaching it to all templates in the deployment unless add_only_to_this_st is set
      def load_script(friendly_name, script, add_only_to_this_st=nil)
        if add_only_to_this_st.is_a?(ServerInterface) or add_only_to_this_st.is_a?(Server)
          sts = [ match_st_by_server(add_only_to_this_st) ]
        elsif add_only_to_this_st.is_a?(ServerTemplate)
          sts = [ add_only_to_this_st ]
        elsif add_only_to_this_st.nil?
          sts = @server_templates
        end

        if script.is_a?(RightScript) or script.is_a?(Executable)
          script_ref = script
          script_ref.reload
        elsif script.is_a?(Fixnum)
          begin
            script_ref = RightScript.find(script)
          rescue
            script_ref = Executable.find(script)
          end
        elsif script.is_a?(String)
          script_ref = RightScript.find_by(:nickname) { |n| n =~ /#{Regexp.escape(script)}/i }.first
        end
        raise "FATAL: Script '#{script}' not found" unless script_ref

        sts.each { |st|
          @scripts_to_run[resource_id(st)] ||= {}
          @scripts_to_run[resource_id(st)][friendly_name] = script_ref
        }
      end

      def s_one
        @servers[0]
      end

      def s_two
        @servers[1]
      end

      def s_three
        @servers[2]
      end

      def s_four
        @servers[3]
      end

      # Launch all servers in the deployment.
      def launch_all
        launch_set(@servers)
      end

      # sets the MASTER_DB_DNSNAME to this machine's ip address
      def set_master_db_dnsname
        the_name = get_tester_ip_addr
        @deployment.set_input("MASTER_DB_DNSNAME", the_name)
        @deployment.set_input("DB_HOST_NAME", the_name)
        @deployment.set_input("db_mysql/fqdn", the_name)
        @deployment.set_input("db/fqdn", the_name)
      end

      # Launch a set of server(s)
      def launch_set(set=@servers)
        set = select_set(set)
        set.each { |s|
          begin
            transaction {
              # NOTE: The following two lines are a workaround for a bug in Eucalyptus Cloud pre-3.0
              clouds = VirtualMonkey::Toolbox::get_available_clouds.to_h("cloud_id", "name")
              McInstance.find_all(s.cloud_id.to_i) if clouds[s.cloud_id.to_i] =~ /euca/i

              s.start
            }
          rescue Exception => e
            raise unless e.message =~ /AlreadyLaunchedError/
          end
        }
      end

      # Re-Launch all servers
      def relaunch_all(timeout=::VirtualMonkey::config[:default_timeout])
        relaunch_set(@servers, timeout)
      end

      # Re-Launch a set of servers
      def relaunch_set(set=@servers, timeout=::VirtualMonkey::config[:default_timeout])
        set = select_set(set)
        begin # This loop is to ensure that public and private ips are different (Euca bug)
          private_ip_equals_public = true
          set.each { |s|
            begin
              transaction {
                s.relaunch;
                s.params = s.class[s.href].first.params;
                s.settings
              }
            rescue Exception => e
              raise #unless e.message =~ /AlreadyLaunchedError/
            end
          }
          set.each { |s|
            transaction { wait_for_set(s, "operational", timeout) }
          }
          if set.reduce(false) { |bool,s| bool || (s.dns_name == s.private_ip) }
            warn "WARNING: Found a server with duplicate IPs in public and private"
          else
            private_ip_equals_public = false
          end
        end while private_ip_equals_public
      end

      # un-set all tags on all servers in the deployment
      def unset_all_tags
        @servers.each do |s|
          # can't unset ALL tags, so we must set a bogus one
          s.tags = [{"name"=>"removeme:now=1"}]
          transaction { s.save }
        end
      end

      # Wait for server(s) matching nickname_substr to enter state
      # * nickname_substr<~String> - regex compatible string to match
      # * state<~String> - state to wait for, eg. operational
      def wait_for_set(nickname_substr, state, timeout=::VirtualMonkey::config[:default_timeout])
        set = select_set(nickname_substr)
        state_wait(set, state, timeout)
      end

      # Helper method, waits for state on a set of servers.
      # * set<~Array> of servers to operate on
      # * state<~String> state to wait for
      def state_wait(set, state, timeout=::VirtualMonkey::config[:default_timeout])
        # do a special wait, if waiting for operational (for dns)
        if state == "operational"
          set.each { |server| transaction { server.wait_for_operational_with_dns(timeout) } }
          if set.reduce(false) { |bool,s| bool || (s.dns_name == s.private_ip) }
            warn "WARNING: Found a server with duplicate IPs in public and private. Relaunching..."
            relaunch_set(set, timeout)
          end
        else
          set.each { |server| transaction { server.wait_for_state(state, timeout) } }
        end
      end

      # Wait for all server(s) to enter state.
      # * state<~String> - state to wait for, eg. operational
      def wait_for_all(state, timeout=::VirtualMonkey::config[:default_timeout])
        state_wait(@servers, state, timeout)
      end

      def start_ebs_all(wait=true)
        @servers.each { |s| transaction { s.start_ebs } }
        wait_for_all("operational") if wait
        @servers.each { |s|
          s['dns_name'] = nil
          s.private_dns_name = nil
        }
      end

      def stop_ebs_all(wait=true)
        @servers.each { |s| transaction { s.stop_ebs } }
        wait_for_all("stopped") if wait
        @servers.each { |s|
          s['dns_name'] = nil
          s.private_dns_name = nil
        }
      end

      def stop_all(wait=true)
        @servers.each { |s| s.stop }
        wait_for_all("stopped") if wait
        @servers.each { |s|
          s['dns_name'] = nil
          s.private_dns_name = nil
        }
      end

      def reboot_set(set=@servers, serially_reboot=false)
        wait_for_reboot = true
        set = select_set(set)
        begin # This loop is to ensure that public and private ips are different (Euca bug)
          private_ip_equals_public = true
          # Do NOT thread this each statement
          set.each do |s|
            transaction { s.reboot(wait_for_reboot) }
            if serially_reboot
              transaction { s.wait_for_state("operational") }
            end
          end
          set.each do |s|
            transaction { s.wait_for_state("operational") }
          end
          if set.reduce(false) { |bool,s| bool || (s.dns_name == s.private_ip) }
            warn "WARNING: Found a server with duplicate IPs in public and private"
          else
            private_ip_equals_public = false
          end
        end while private_ip_equals_public
      end

      def reboot_all(serially_reboot=false)
        reboot_set(@servers, serially_reboot)
      end

      # Run a script on all servers in the deployment in parallel
      def run_script_on_all(friendly_name, wait = true, options = nil)
        run_script_on_set(friendly_name, @servers, wait, options)
      end

      # Run a script on a set of servers in the deployment in parallel
      # * friendly_name<~String> = the hash key name of the desired script to run
      # * set can be any way of denoting a set of servers to run on:
      # *** <~Array> will attempt to run the script on each server in set
      # *** <~String> will first attempt to find a function in the runner with that String to get
      # ***           an Array/ServerInterface to run on (e.g. app_servers, s_one). If that fails, then it
      # ***           will use the String as a regex to select a subset of servers.
      # *** <~Symbol> will attempt to run a function in the runner to get an Array/ServerInterface to run
      # ***           on (e.g. app_servers, s_one)
      # *** <~ServerInterface> will run the script only on that one server
      # * wait<~Boolean> will wait for the script to complete on all servers (true) or return
      #                  audits for each
      # * options<~Hash> will pass specific inputs to the script to run with
      def run_script_on_set(friendly_name, set = @servers, wait = true, options = nil)
        audits = Array.new()
        set = select_set(set)
        if wait
          set.each do |s|
            if wait.is_a?(Fixnum)
              transaction {
                a = launch_script(friendly_name, s, options)
                transaction { a.wait_for_completed(wait) }
              }
            else
              transaction {
                a = launch_script(friendly_name, s, options)
                transaction { a.wait_for_completed(::VirtualMonkey::config[:default_timeout]) }
              }
            end
          end
        else
          set.each do |s|
            audits << launch_script(friendly_name, s, options)
          end
          if audits.size == 1
            return audits.first
          else
            return audits
          end
        end
      end

      # Run a script on server in the deployment synchronously
      def run_script(friendly_name, server, options = nil)
        run_script_on_set(friendly_name, server, true, options)
      end

      # Run a script on server in the deployment asynchronously
      def launch_script(friendly_name, server, options = nil)
        actual_name = script_to_run?(friendly_name, server)
        transaction { server.run_executable(@scripts_to_run[resource_id(server.server_template_href)][actual_name], options) }
      end

      # Call run_script_on_set with out-of-order params passed in as a hash
      def run_script!(friendly_name, hash = {})
        hash['servers'] = @servers unless hash['servers']
        hash['wait'] = true unless hash['wait']
        run_script_on_set(friendly_name, hash['servers'], hash['wait'], hash['options'])
      end

      # If no server argument is passed, this returns an array of friendly_script names that should be called for each server. Or raises an exception
      # If a server argument is passed, this returs the correct friendly_script name that should be called for that server. Or raises an exception
      def script_to_run?(friendly_name, server = nil)
        if server.nil? #check for all
          key_arys = @server_templates.map { |st|
            raise "No scripts registered for server_template #{st.inspect}" unless @scripts_to_run[resource_id(st)]
            @scripts_to_run[resource_id(st)].keys
          }
          agreement = key_arys.unanimous? { |key_ary|
            key_ary.include?(friendly_name)
          }
          if agreement
            ret = @servers.map { |s| friendly_name }
          else
            friendly_name_ary = key_arys.map { |key_ary|
              val = key_ary.detect { |key| key =~ /#{Regexp.escape(friendly_name)}/i }
              warn "Found case-insensitive match for script friendly name. Searched for '#{friendly_name}', registered name was '#{key}'" if val
              val
            }
            friendly_name_ary.each_with_index { |name,index|
              raise "No script registered with friendly_name #{friendly_name} for server_template #{@server_templates[index].inspect}" unless name
            }
            ret = @servers.map { |s|
              friendly_name_ary[@server_templates.find_index(match_st_by_server(s))]
            }
          end
        else
          if @scripts_to_run[resource_id(server.server_template_href)]
            if @scripts_to_run[resource_id(server.server_template_href)][friendly_name]
              ret = friendly_name
            else
              ret = @scripts_to_run[resource_id(server.server_template_href)].keys.detect { |key| key =~ /#{Regexp.escape(friendly_name)}/i }
              warn "Found case-insensitive match for script friendly name. Searched for '#{friendly_name}', registered name was '#{key}'" if ret
              raise "No script registered with friendly_name #{friendly_name} for server_template #{match_st_by_server(server).inspect}" unless ret
            end
          else
            st = @server_templates.detect { |t| t.rs_id.to_s == resource_id(server.server_template_href).to_s }
            raise "No scripts registered for server_template #{st.inspect}"
          end
        end
        ret
      end

      # probe executes a shell command over ssh to a set of servers is provides the following functionality:
      def probe(set, command, &block)
        # run command on set over ssh
        result_output = ""
        result_status = true
        set_ary = select_set(set)

        set_ary.each { |s|
          result_temp = s.spot_check_command(command)
          if block
            if not yield(result_temp[:output],result_temp[:status])
              raise "FATAL: Server #{s.nickname} failed probe. Got '#{result_temp[:output]}'"
            end
          end
          result_output += result_temp[:output]
          result_status &&= (result_temp[:status] == 0)
        }
        result_status
      end

      # Detect operating system on each server and stuff the corresponding values for platform into the servers params (for temp storage only)
      def detect_os
        @servers.each do |server|
          # Distro
          probe(server, "lsb_release -is") { |result,status|
            case result
            when /ubuntu/i
              puts "setting server to ubuntu"
              server.os = "ubuntu"
              server.apache_str = "apache2"
              server.apache_check = "apache2ctl status"
              server.haproxy_check = "service haproxy status"
            when /centos/i
              puts "setting server to centos"
              server.os = "centos"
              server.apache_str = "httpd"
              server.apache_check = "service httpd status"
              server.haproxy_check = "service haproxy check"
            when /redhat/i
              puts "setting server to redhat"
              server.os = "redhat"
              server.apache_str = "httpd"
              server.apache_check = "service httpd status"
              server.haproxy_check = "service haproxy check"
            else
              warn "Unsupported OS detected: #{result}"
            end
          }

          # Arch
          probe(server, "arch") { |result,status|
            case result
            when /i[3-6]86/i then server.arch = "i386"
            when /x86_64/i then server.arch = "x64"
            else
              warn "Unsupported Architecture detected: #{result}"
            end
          }
        end
      end

      # Assumes the host machine is in the cloud, uses the toolbox functions to grab the IP address of this
      # 'tester server' eg. used for the input variation MASTER_DB_DNSNAME
      def get_tester_ip_addr
        if ::VirtualMonkey::my_api_self
          ip = ::VirtualMonkey::my_api_self.reachable_ip
        else
          ip = "127.0.0.1"
        end
        return "text:#{ip}"
      end

      # Log rotation
      def force_log_rotation(server)
        response = probe(server, 'logrotate -f /etc/logrotate.conf')
        raise "Logrotate restart failed" unless response
      end

      def log_check(server, logfile)
        response = nil
        count = 0
        until response || count > 3 do
          # test -f will only work if 1 file is returned.
          response = probe(server, "ls #{logfile}")
          break if response
          count += 1
          sleep 10
        end
        raise "Log file does not exist: #{logfile}" unless response
      end

      # Checks that monitoring is enabled on all servers in the deployment.  Will raise an error if monitoring is not enabled.
      def check_monitoring
        @servers.each do |server|
          transaction {
            server.settings
            response = nil
            count = 0
            until response || count > 20 do
              begin
                response = server.monitoring
              rescue
                response = nil
                count += 1
                sleep 10
              end
            end
            raise "Fatal: Failed to verify that monitoring is operational" unless response
  #TODO: pass in some list of plugin info to check multiple values.  For now just
  # hardcoding the cpu check
            sleep 60 # This is to allow monitoring data to accumulate
            @monitor_start, @monitor_end = -60, -20
            monitor = transaction { server.get_sketchy_data({'start' => @monitor_start,
                                                             'end' => @monitor_end,
                                                             'plugin_name' => "cpu-0",
                                                             'plugin_type' => "cpu-idle"}) }
            idle_values = monitor['data']['value']
            raise "No cpu idle data" unless idle_values.length > 0
            raise "CPU idle time is < 0: #{idle_values}" unless idle_values[0] > 0
            puts "Monitoring is OK for #{server.nickname}"
          }
        end
      end

      def check_monitoring_exception_handle(e)
        if e.message =~ /CPU idle time is|No cpu idle data/i
          warn "Got \"#{e.message}\". Adjusting monitoring window and retrying...."
          @monitor_start -= 45
          @monitor_end -= 45
          return true # Exception Handled
        elsif e.message =~ /MonitoringDataError/i
          warn "Got \"#{e.message}\". Waiting for monitoring to become active...."
          sleep 30
          return true # Exception Handled
        else
          return false # Exception Not Handled
        end
      end


  # TODO - we do not know what the RS_INSTANCE_ID available to the testing.
  # For now we are checking at a high level that the services are working
  # and then assume that the config file changes done during start are
  # correct for the new instance data.
  #
      def perform_start_stop_operations
        if deployment.nickname =~ /EBS/
          detect_os
          s = @servers.first
          # Save configuration files for comparison after starting
          save_configuration_files(s)
          # Stop the servers
          stop_ebs_all
          # Verify all stopped
          # Start the servers
          start_ebs_all(true)
  #       Do this for all? Or just the one?
  #       @servers.each { |server| server.wait_for_operational_with_dns }
          s = @servers.first
          transaction { s.wait_for_operational_with_dns(::VirtualMonkey::config[:default_timeout]) }
          # Verify operational
          run_simple_check(s)
          check_monitoring
        end
      end

  # TODO there will be other files that need compares et al.  Create a list
  # of them and abstarct the tests
      # Copy configuration files into some location for usage after start
      def save_configuration_files(server)
        puts "Saving config files"
        probe(server, 'mkdir -p /root/start_stop_backup')
        probe(server, 'cp /etc/postfix/main.cf /root/start_stop_backup/.')
        probe(server, 'cp /etc/syslog-ng/syslog-ng.conf /root/start_stop_backup/.')
      end

      # Diff the new config file with the saved one and check that the only
      # line that is different is the one that has the mydestination change
      def test_mail_config(server)
        res = probe(server, 'diff /etc/postfix/main.cf /root/start_stop_backup/main.cf')
  # This is lame - assuming if the file is modified then it's okay
          raise "ERROR: postfix main.cf configuration file did not change when restarted" unless res
      end

      def test_syslog_config(server)
        res = probe(server, 'diff /etc/syslog-ng/syslog-ng.conf /root/start_stop_backup/syslog-ng.conf')
  # This is lame - assuming if the file is modified then it's okay
        raise "ERROR: syslog-ng configuration file did not change when restarted" unless res
      end

      def run_simple_checks
        @servers.each { |s| run_simple_check(s) }
      end

      # this is where ALL the generic application server checks live, this could get rather long but for now it's a single method with a sequence of checks
      def run_simple_check(server)
        test_mail_config(server)
        test_syslog_config(server)
      end

      # parameter tag_to_set is a string
      # example pass in rs_agent_dev:package=5.7.11
      def tag_all_servers(tag_to_set)
        servers.each_index { |counter|
          servers[counter].settings
          servers[counter].reload
          puts "tag added " + tag_to_set.to_s + " " + servers[counter].to_s

          if servers[counter].multicloud
            McTag.set(servers[counter].href,["#{tag_to_set}"]) ## Tag.set expects and array input
          else
            Tag.set(servers[counter].href,["#{tag_to_set}"]) ## Tag.set expects and array input
          end

          servers[counter].tags(true)
        }
      end

      #
      def get_input_from_server(server)
        @my_inputs = {} ## initialize a hash
        if server.multicloud && server.current_instance
          server.current_instance.inputs.each { |hsh|
            @my_inputs[hsh["name"]] = hsh["value"]
          }
        elsif server.current_instance_href
          server.reload_as_current
          server.settings
          server.parameters.each { |name , input_value|
           #to_return = input_value if (input_name.to_s.match(/#{inputname}/))
            @my_inputs[name] = input_value
          }
          server.reload_as_next
        end
        return @my_inputs
      end

      def assert_integrity!
        unless self.class.respond_to?(:description)
          error "#{options[:runner]} doesn't extend VirtualMonkey::RunnerCore::CommandHooks"
        end
        [:before_destroy, :after_create, :after_destroy].each do |hook_set|
          unless self.class.respond_to?(hook_set)
            error "#{options[:runner]} doesn't extend VirtualMonkey::RunnerCore::CommandHooks"
          end
          self.class.__send__(hook_set).each { |fn|
            if not fn.is_a?(Proc)
              raise "FATAL: #{self.class} does not have an instance method named #{fn}" unless self.respond_to?(fn)
            end
          }
        end
        unless self.class.respond_to?(:assert_integrity!)
          error "#{options[:runner]} doesn't extend VirtualMonkey::RunnerCore::CommandHooks"
        end
        self.class.assert_integrity!
      end

      def is_rackspace?(*servers)
        servers = @servers if servers.empty?
        clouds = ::VirtualMonkey::Toolbox::get_available_clouds
        rackclouds = clouds.select { |c| c["name"] =~ /rackspace/i }.map { |c| c["cloud_id"] }
        servers.reduce(false) { |b,s| b || (rackclouds | [232, 1868]).include?(s.cloud_id.to_i) }
      end
    end
  end
end
